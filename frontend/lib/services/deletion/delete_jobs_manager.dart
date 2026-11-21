// Phase 8 spec §4 and §6 para 4-5; SC-13, SC-14, SC-15, SC-01 rule 4.
//
// The delete-jobs model. A confirmed deletion is frozen into a durable
// submission of kind `track_deletion` (one operation UUID, sent exactly as
// stored). A lost answer is recovered status-first by that same UUID, never
// by minting a new operation. Passes run on a SingleFlightRunner paced by a
// BackoffSchedule and poll accepted jobs to their end. Every apply to the
// in-memory `jobs` is fenced by the binding token, and a target that newly
// reaches deleted asks for one `/changes` sync. No UI here, and no Drift
// table: jobs live in memory (O8); only the submissions are durable.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/operations/gate_wait.dart';
import 'package:frontend/services/operations/submission_failure_rules.dart';
import 'package:frontend/services/server_binding_gate.dart';


/// Why server deletion can't be used right now.
enum DeleteJobsUnavailableReason {
  /// The server doesn't advertise `library_tools` (or advertises it
  /// malformed).
  notAdvertised,

  /// Only the cached capability is known (offline or the refresh failed).
  notConfirmedLive,

  /// The operator turned server deletion off.
  switchedOff,

  /// The app is offline.
  offline,

  /// No session binding (signed out, mid-reset).
  noSession,

  /// The connection to the server is not verified (yet), or is blocked.
  notConnected,

  /// The manager is closed (reset or scope change).
  closed,
}

class DeleteJobsUnavailable implements Exception {
  const DeleteJobsUnavailable(this.reason);
  final DeleteJobsUnavailableReason reason;

  @override
  String toString() => 'DeleteJobsUnavailable(${reason.name})';
}

/// [DeleteJobsManager.submit] of a preview that may not be confirmed, or
/// with a confirmed count that is not the preview's: nothing was written.
class DeletionNotConfirmable implements Exception {
  const DeletionNotConfirmable(this.message);
  final String message;

  @override
  String toString() => 'DeletionNotConfirmable($message)';
}

/// [DeleteJobsManager.submit] of a preview naming a track whose earlier
/// submission is still waiting for the server's answer: nothing was written.
class DeletionAwaitingAnswer implements Exception {
  const DeletionAwaitingAnswer();

  @override
  String toString() => 'DeletionAwaitingAnswer';
}

class DeleteJobsManager {
  /// The server's limit per job (spec §4).
  static const maxTargetsPerJob = 100;

  /// The submission kind (SC-14).
  static const submissionKind = 'track_deletion';


  DeleteJobsManager({
    required LibraryToolsApi api,
    required DurableSubmission submissions,
    required ServerBindingRepository binding,
    required ServerBindingGate gate,
    required Future<AdvertisedFeature<LibraryToolsFeature>?> Function()
    feature,
    required bool Function() isOffline,
    required Future<bool> Function() requestSync,
    String Function()? newUuid,
    Timer Function(Duration, void Function()) timer = Timer.new,
    BackoffSchedule? backoff,
  }) : _api = api,
       _submissions = submissions,
       _binding = binding,
       _gate = gate,
       _feature = feature,
       _isOffline = isOffline,
       _requestSync = requestSync,
       _newUuid = newUuid ?? (() => const Uuid().v4()) {
    _runner = SingleFlightRunner(
      name: 'delete-jobs',
      pass: _runPass,
      backoff: backoff ?? BackoffSchedule(),
      timer: timer,
    );
  }

  final LibraryToolsApi _api;
  final DurableSubmission _submissions;
  final ServerBindingRepository _binding;
  final ServerBindingGate _gate;
  final Future<AdvertisedFeature<LibraryToolsFeature>?> Function() _feature;
  final bool Function() _isOffline;
  final Future<bool> Function() _requestSync;
  final String Function() _newUuid;
  late final SingleFlightRunner _runner;
  final _closing = Completer<void>();

  /// The bound server is verified again after another server's 401: a
  /// runner the 401 parked runs the next request.
  void resumeAfterBoundServerBack() => _runner.resumeParked();
  final _jobs = ValueNotifier<Map<String, DeleteJob>>(const {});
  final _followed = <String>{};
  final _submitting = Expando<Future<String>>('delete-submit');

  /// The binding token each preview was produced under: only previews this
  /// manager answered can be submitted, and only under that binding.
  final _producedUnder = Expando<String>('delete-preview-binding');
  bool _closed = false;

  /// Serializes [_submitNew]: the unresolved read and `prepare` of one submit
  /// finish before the next begins, so two previews sharing a track cannot
  /// both pass the awaiting-answer check.
  Future<void> _submitChain = Future.value();
  bool _syncNeeded = false;
  int _requestsInFlight = 0;

  /// A pass's wait for the server check; [quiesce] ends it.
  late final _gateWait = GateWait(gate: _gate, closing: _closing.future);

  /// The jobs this scope knows, by operation UUID.
  ValueListenable<Map<String, DeleteJob>> get jobs => _jobs;


  /// Asks the server what deleting [candidates] would do. Throws
  /// [DeleteJobsUnavailable] (nothing sent) without a live `library_tools`
  /// block with `server_delete`, offline, or without a session; an
  /// [ArgumentError] for an empty, oversized or repeated selection.
  Future<DeletionPreview> preview(List<DeletionCandidate> candidates) async {
    if (_closed) {
      throw const DeleteJobsUnavailable(DeleteJobsUnavailableReason.closed);
    }
    if (candidates.isEmpty ||
        candidates.length > maxTargetsPerJob ||
        {for (final c in candidates) c.uuid}.length != candidates.length) {
      throw ArgumentError.value(
        candidates.length,
        'candidates',
        '1-$maxTargetsPerJob distinct tracks required',
      );
    }
    final token = await _requireAvailable();
    // A person's own preview waits out a server check already in flight (an
    // app resume re-checks), up to ServerBindingGate.tokenWaitBound.
    await _gate.verdictSettled();
    if (_closed) {
      throw const DeleteJobsUnavailable(DeleteJobsUnavailableReason.closed);
    }
    if (_gate.state is! BindingVerified) {
      throw const DeleteJobsUnavailable(
        DeleteJobsUnavailableReason.notConnected,
      );
    }
    // DEV-8B1b-01: an unknown revision (null) goes out as 0, only because
    // the server requires an integer. The verdict for it is always
    // revisionUnknown, and a job body never carries it.
    final answer = await _api.preview([
      for (final c in candidates)
        DeletionTargetDto(uuidId: c.uuid, baseRevision: c.baseRevision ?? 0),
    ], abortTrigger: _closing.future);
    final result = DeletionPreview.fromServer(candidates, answer);
    _producedUnder[result] = token;
    return result;
  }

  /// Freezes and submits the deletion of [preview]'s targets; returns the
  /// operation UUID. One operation per preview: a second call with the
  /// same preview returns the same operation and sends nothing new.
  Future<String> submit(
    DeletionPreview preview, {
    required int confirmedCount,
  }) async {
    if (_closed) {
      throw const DeleteJobsUnavailable(DeleteJobsUnavailableReason.closed);
    }
    if (!preview.confirmable) {
      throw const DeletionNotConfirmable('the preview is not confirmable');
    }
    if (confirmedCount != preview.count) {
      throw DeletionNotConfirmable(
        'confirmed $confirmedCount of ${preview.count} tracks',
      );
    }
    if (_producedUnder[preview] == null) {
      throw const DeletionNotConfirmable(
        'the preview was not produced by this manager',
      );
    }
    final existing = _submitting[preview];
    if (existing != null) return existing;
    final future = _submitNew(preview, confirmedCount);
    _submitting[preview] = future;
    try {
      return await future;
    } catch (_) {
      // A refused submit wrote nothing: the preview may be tried again.
      if (identical(_submitting[preview], future)) _submitting[preview] = null;
      rethrow;
    }
  }


  /// Whether any of [uuids] is in a job still being sent or whose answer was
  /// lost (submitting / unconfirmed).
  bool awaitingAnswer(Iterable<String> uuids) {
    final wanted = uuids.toSet();
    return _jobs.value.values.any(
      (j) =>
          (j.phase == DeleteJobPhase.submitting ||
              j.phase == DeleteJobPhase.unconfirmed) &&
          j.targets.any((t) => wanted.contains(t.uuidId)),
    );
  }

  /// Tracks a job known from the receipt list until it is finished. A job
  /// already known is read once more, so a finished one shows what the
  /// server says now (its storage clean-up may have finished since).
  void follow(String operationUuid) {
    if (_closed) return;
    _followed.add(operationUuid);
    request('follow', bypassBackoff: true);
  }

  /// Statuses of a job the server has finished (`GET /tracks/deletions`).
  static const _finishedStatuses = {'succeeded', 'partial', 'failed'};

  /// Reads the server's whole job list and loads every job not finished
  /// there (pending, running, or a status this app does not know) that
  /// [jobs] does not hold yet: a deletion accepted before a relaunch, or
  /// started on another device. The server lists a track until its deletion
  /// runs, so only this list says it is on its way out. True when the list
  /// and each such job were read; a read the binding does not allow now
  /// fails at once (false). Sends nothing that changes the server.
  Future<bool> loadUnfinished() async {
    if (_closed) return false;
    final token = (await _binding.current())?.localBindingId;
    if (token == null) return false;
    try {
      final unfinished = <String>[];
      final seen = <String>{};
      String? after;
      do {
        final page = await _api.listJobs(
          after: after,
          limit: 100, // the server's largest page
          abortTrigger: _closing.future,
          waitForBinding: false,
        );
        for (final j in page.jobs) {
          if (!_finishedStatuses.contains(j.status)) {
            unfinished.add(j.operationUuid);
          }
        }
        after = page.nextAfter;
        if (after != null && !seen.add(after)) return false;
      } while (after != null);
      for (final op in unfinished) {
        if (_jobs.value.containsKey(op)) continue;
        final dto = await _api.getJob(op, abortTrigger: _closing.future);
        await _applyServerJob(token, dto, [
          for (final i in dto.items)
            DeletionTargetDto(uuidId: i.uuidId, baseRevision: i.baseRevision),
        ]);
      }
      // Polled to their end like this app's own jobs.
      if (_closed) return false;
      if (unfinished.isNotEmpty) request('unfinished');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Requests a pass for [reason] (recovery edges bypass a pending backoff).
  void request(String reason, {bool bypassBackoff = false}) =>
      _runner.request(reason, bypassBackoff: bypassBackoff);

  /// Completes when no pass is running, or the running one waits for the
  /// binding gate.
  ///
  /// While a request waits for the server's answer, [idle] yields one event
  /// turn instead: a slow answer must not hold its callers.
  Future<void> idle() => _gateWait.waiting
      ? Future.value()
      : _requestsInFlight > 0
      ? Future<void>.delayed(Duration.zero)
      : Future.any([_runner.whenIdle(), _gateWait.nextWaitBegins]);

  bool get isClosed => _closed;

  /// SC-15: no new pass or send; aborts gate waits; waits out the pass in
  /// flight. Idempotent.
  Future<void> quiesce() async {
    _closed = true;
    if (!_closing.isCompleted) _closing.complete();
    await _runner.quiesce();
  }

  // ── The pass and its helpers ─────────────────────────────────────────

  /// The availability checks `preview` and `submit` share, in the order the
  /// tests pin: offline, the live `library_tools` block with `server_delete`,
  /// then the session. Returns the binding token; nothing is sent.
  Future<String> _requireAvailable() async {
    if (_isOffline()) {
      throw const DeleteJobsUnavailable(DeleteJobsUnavailableReason.offline);
    }
    final advertised = await _feature();
    if (advertised == null) {
      throw const DeleteJobsUnavailable(
        DeleteJobsUnavailableReason.notAdvertised,
      );
    }
    if (featureForNetwork(advertised) == null) {
      throw const DeleteJobsUnavailable(
        DeleteJobsUnavailableReason.notConfirmedLive,
      );
    }
    if (!advertised.block.serverDelete) {
      throw const DeleteJobsUnavailable(
        DeleteJobsUnavailableReason.switchedOff,
      );
    }
    final token = (await _binding.current())?.localBindingId;
    if (token == null) {
      throw const DeleteJobsUnavailable(DeleteJobsUnavailableReason.noSession);
    }
    return token;
  }

  Future<String> _submitNew(DeletionPreview preview, int confirmedCount) {
    final run = _submitChain.then((_) => _submitNewSerial(preview, confirmedCount));
    _submitChain = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<String> _submitNewSerial(
    DeletionPreview preview,
    int confirmedCount,
  ) async {
    final token = await _requireAvailable();
    if (_producedUnder[preview] != token) {
      throw const DeletionNotConfirmable(
        'the preview was produced under another session',
      );
    }
    if (preview.targets.any((t) => t.baseRevision == null)) {
      throw const DeletionNotConfirmable('a target has no known revision');
    }
    if (_closed) {
      throw const DeleteJobsUnavailable(DeleteJobsUnavailableReason.closed);
    }
    // Durable rows, not just memory: this holds after a relaunch before any
    // pass ran. A lost answer is resolved status-first, never by resending.
    final pending = {
      for (final row in await _submissions.unresolved(
        bindingToken: token,
        kind: submissionKind,
      ))
        for (final t in _targetsOf(row.frozenBodyJson)) t.uuidId,
    };
    if (preview.targets.any((t) => pending.contains(t.uuid))) {
      throw const DeletionAwaitingAnswer();
    }
    final targets = [
      for (final t in preview.targets)
        DeletionTargetDto(uuidId: t.uuid, baseRevision: t.baseRevision!),
    ];
    final op = _newUuid();
    final body = DeletionJobRequestDto(
      operationUuid: op,
      targets: targets,
      confirmedCount: confirmedCount,
    ).toFrozenJson();
    final stored = await _submissions.prepare(
      kind: submissionKind,
      operationUuid: op,
      frozenBodyJson: body,
      bindingToken: token,
    );
    _putJob(
      DeleteJob(
        operationUuid: op,
        phase: DeleteJobPhase.submitting,
        targets: targets,
        submittedAtMs: stored.createdAtMs,
      ),
    );
    request('submit', bypassBackoff: true);
    return op;
  }

  Future<PassOutcome> _runPass(Set<String> reasons) async {
    if (_closed) return const PassDone();
    if (_isOffline()) return const PassFailed(BackoffReason.offline);
    // serverDelete off does not stop a pass: an accepted job stays readable.
    if (featureForNetwork(await _feature()) == null) {
      return const PassFailed(BackoffReason.capabilityMissing);
    }
    try {
      final token = await _gateWait.token();
      if (token == null) return const PassDone();
      var retry = false;
      final handled = <String>{};
      for (final row in await _submissions.unresolved(
        bindingToken: token,
        kind: submissionKind,
      )) {
        final op = row.operationUuid;
        if (!_jobs.value.containsKey(op)) {
          await _apply(
            token,
            () => _putJob(
              DeleteJob(
                operationUuid: op,
                phase: row.state == SubmissionState.ambiguous
                    ? DeleteJobPhase.unconfirmed
                    : DeleteJobPhase.submitting,
                targets: _knownTargetsOf(row.frozenBodyJson),
                submittedAtMs: row.createdAtMs,
              ),
            ),
          );
        }
        final SubmissionOutcome outcome;
        try {
          outcome = await _sendOne(op);
        } on StatusQueryFailed catch (e) {
          throw e.cause;
        }
        switch (outcome) {
          case SubmissionAccepted(:final receipt):
            final targets =
                _jobs.value[op]?.targets ?? _knownTargetsOf(row.frozenBodyJson);
            final DeletionJobDto dto;
            try {
              dto = DeletionJobDto.fromJson(receipt);
            } on FormatException {
              // Accepted with an unreadable receipt: known targets, no items;
              // not handled, so _poll reads it by uuid in this pass.
              await _apply(
                token,
                () => _putJob(
                  DeleteJob(
                    operationUuid: op,
                    phase: DeleteJobPhase.accepted,
                    targets: targets,
                    submittedAtMs: row.createdAtMs,
                  ),
                ),
              );
              continue;
            }
            await _applyServerJob(token, dto, targets);
            handled.add(op);
          case SubmissionRejected(:final code):
            await _apply(
              token,
              () => _putJob(
                DeleteJob(
                  operationUuid: op,
                  phase: DeleteJobPhase.rejected,
                  targets:
                      _jobs.value[op]?.targets ??
                      _knownTargetsOf(row.frozenBodyJson),
                  rejectionCode: code,
                  submittedAtMs: row.createdAtMs,
                ),
              ),
            );
          case SubmissionAmbiguous(:final cause):
            final parked = isUnauthorized(
              cause is StatusQueryFailed ? cause.cause : cause,
            );
            await _apply(token, () {
              final j = _jobs.value[op];
              if (j != null && j.phase == DeleteJobPhase.submitting) {
                _putJob(
                  DeleteJob(
                    operationUuid: op,
                    phase: DeleteJobPhase.unconfirmed,
                    targets: j.targets,
                    submittedAtMs: j.submittedAtMs,
                  ),
                );
              }
            });
            if (parked) return const PassParked();
            retry = true;
          case SubmissionFenced():
            return const PassDone();
        }
      }
      final pollOutcome = await _poll(token, skip: handled);
      if (pollOutcome == _PollOutcome.parked) return const PassParked();
      if (_syncNeeded && !_closed) {
        _syncNeeded = false;
        try {
          if (!await _requestSync()) _syncNeeded = true;
        } catch (_) {
          // A failed sync request never fails the pass, but the sync stays
          // owed until one runs.
          _syncNeeded = true;
        }
      }
      // A sync still owed (it did not run) is retried under the backoff.
      return retry || pollOutcome == _PollOutcome.more || _syncNeeded
          ? const PassFailed(BackoffReason.transient)
          : const PassDone();
    } on BindingFencedException {
      return const PassDone();
    } on BindingGateClosedException {
      return const PassDone();
    } on LibraryToolsRequestAborted {
      return const PassDone();
    } on SubmissionClosed {
      return const PassDone();
    } on ServerInstanceChangedException {
      return const PassFailed(BackoffReason.offline);
    }
  }

  /// Applies the server's [dto] inside the fence; a target that newly
  /// reached deleted/already_deleted asks for one `/changes` sync.
  Future<void> _applyServerJob(
    String token,
    DeletionJobDto dto,
    List<DeletionTargetDto> targets,
  ) => _apply(token, () {
    final job = _jobFromServer(dto, targets);
    final before = {
      for (final i in _jobs.value[dto.operationUuid]?.items ?? const []) i.uuid: i.isGone,
    };
    if (job.items.any((i) => i.isGone && before[i.uuid] != true)) {
      _syncNeeded = true;
    }
    _putJob(job);
  });

  /// Polls every accepted or running job, except those the submission step
  /// just answered, and reads every followed one once.
  Future<_PollOutcome> _poll(String token, {required Set<String> skip}) async {
    final ops = <String>[
      for (final j in _jobs.value.values)
        if (j.phase == DeleteJobPhase.accepted ||
            j.phase == DeleteJobPhase.running)
          if (!skip.contains(j.operationUuid)) j.operationUuid,
    ];
    for (final op in _followed) {
      if (!ops.contains(op)) ops.add(op);
    }
    var failed = false;
    for (final op in ops) {
      final DeletionJobDto dto;
      _requestsInFlight++;
      try {
        dto = await _api.getJob(op, abortTrigger: _closing.future);
      } on ApiException catch (e) {
        if (e.statusCode == 401) return _PollOutcome.parked;
        if (e.statusCode == 404 && e.errorCode == 'deletion_job_not_found') {
          // A followed job is read once, found or not.
          _followed.remove(op);
          final known = _jobs.value[op];
          if (known == null) continue;
          if (known.phase == DeleteJobPhase.accepted ||
              known.phase == DeleteJobPhase.running) {
            // The server no longer knows a job it accepted (a restored
            // database): its outcome is unknown and asking again cannot
            // help. The last outcomes read are dropped as stale.
            await _apply(
              token,
              () => _putJob(
                DeleteJob(
                  operationUuid: op,
                  phase: DeleteJobPhase.unknown,
                  targets: known.targets,
                  createdAt: known.createdAt,
                  submittedAtMs: known.submittedAtMs,
                ),
              ),
            );
            continue;
          }
        }
        failed = true;
        continue;
      } on NetworkException {
        failed = true;
        continue;
      } on TokenWithheldException {
        // Nothing was sent (the server is not verified): this job is skipped
        // for this pass, the others are still polled (sign-off OPEN-M-11).
        failed = true;
        continue;
      } on TimeoutException {
        failed = true;
        continue;
      } on FormatException {
        failed = true; // an unreadable answer: this job keeps its state
        continue;
      } finally {
        _requestsInFlight--;
      }
      await _applyServerJob(
        token,
        dto,
        _jobs.value[op]?.targets ?? [
          for (final i in dto.items)
            DeletionTargetDto(uuidId: i.uuidId, baseRevision: i.baseRevision),
        ],
      );
      _followed.remove(op);
    }
    final open = _jobs.value.values.any(
      (j) =>
          j.phase == DeleteJobPhase.accepted ||
          j.phase == DeleteJobPhase.running,
    );
    return failed || open ? _PollOutcome.more : _PollOutcome.done;
  }

  Future<SubmissionOutcome> _sendOne(String op) async {
    _requestsInFlight++;
    try {
      return await _sendOneUntracked(op);
    } finally {
      _requestsInFlight--;
    }
  }

  Future<SubmissionOutcome> _sendOneUntracked(String op) => _submissions.submit(
    op,
    send: (r) async {
      try {
        return (await _api.createJob(
          r.frozenBodyJson!,
          abortTrigger: Future.any([r.abortSignal, _closing.future]),
        )).toJson();
      } on DeletionReceiptUnreadable {
        // The server holds the job; only its receipt is unknown. An empty
        // receipt records the submission accepted, so it is never resent.
        return <String, dynamic>{};
      }
    },
    status: (op) async {
      try {
        final job = await _api.getJob(op, abortTrigger: _closing.future);
        return StatusAccepted(job.toJson());
      } on ApiException catch (e) {
        if (e.statusCode == 404 && e.errorCode == 'deletion_job_not_found') {
          return const StatusAbsent();
        }
        throw StatusQueryFailed(e);
      } catch (e) {
        if (e is ServerInstanceChangedException ||
            e is LibraryToolsRequestAborted) {
          rethrow;
        }
        throw StatusQueryFailed(e);
      }
    },
    onFailure: (e) => switch (e) {
      // A failed status query never settles the operation as refused.
      StatusQueryFailed(:final cause) =>
        _commonFailure(cause) ??
            SubmissionAmbiguousAs(
              cause is ApiException && cause.statusCode == 401
                  ? cause.errorCode ?? 'http_401'
                  : 'status_unavailable',
            ),
      // A refused deletion is final whatever `retryable` says.
      _ => _commonFailure(e) ?? refusalIsFinal(e),
    },
  );

  void _putJob(DeleteJob job) {
    if (_closed) return;
    _jobs.value = Map.unmodifiable({..._jobs.value, job.operationUuid: job});
  }

  /// A write to [jobs] from a pass: a no-op once the binding changed. The
  /// binding is checked in its fence (a transaction) and the write follows
  /// it: a listener of [jobs] that reads the database (Manage library reads
  /// the titles) must not run inside a transaction that closes under it.
  Future<void> _apply(String token, void Function() write) async {
    await _binding.runFenced(token, () async {});
    if (!_closed) write();
  }

  /// The targets of a stored request; a [FormatException] when the stored
  /// text cannot be read (a submit then sends nothing new).
  static List<DeletionTargetDto> _targetsOf(String? frozenBodyJson) =>
      frozenBodyJson == null
      ? const []
      : DeletionJobRequestDto.targetsOfFrozenJson(frozenBodyJson);

  /// [_targetsOf] for a pass: a stored request that cannot be read has no
  /// known targets. The pass still sends it as stored (the server's answer
  /// settles it) and goes on with the other rows.
  static List<DeletionTargetDto> _knownTargetsOf(String? frozenBodyJson) {
    try {
      return _targetsOf(frozenBodyJson);
    } on FormatException {
      return const [];
    }
  }

  static DeleteJobPhase _phaseOf(String status) => switch (status) {
    'pending' => DeleteJobPhase.accepted,
    'running' => DeleteJobPhase.running,
    'succeeded' => DeleteJobPhase.completed,
    'partial' => DeleteJobPhase.partial,
    'failed' => DeleteJobPhase.failed,
    _ => DeleteJobPhase.running,
  };

  static DeleteJob _jobFromServer(
    DeletionJobDto dto,
    List<DeletionTargetDto> targets,
  ) => DeleteJob(
    operationUuid: dto.operationUuid,
    phase: _phaseOf(dto.status),
    targets: targets,
    items: List.unmodifiable([
      for (final i in dto.items) DeleteJobItem.fromDto(i),
    ]),
    createdAt: dto.createdAt,
  );

  static SubmissionFailureDisposition? _commonFailure(Object e) => switch (e) {
    // TokenWithheldException: nothing was sent, the row stays as it was and
    // the pass's retry sends it later (sign-off OPEN-M-11).
    ServerInstanceChangedException() ||
    LibraryToolsRequestAborted() ||
    TokenWithheldException() => const LeaveSubmissionUntouched(),
    _ => null,
  };
}

enum _PollOutcome { done, more, parked }
