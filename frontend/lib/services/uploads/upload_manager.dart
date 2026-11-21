// The client upload manager (spec §7). `addFiles` filters and hashes the
// selected files, splits them into batches within the advertised limits, and
// persists each batch's intents and frozen allocation request before any
// network call. Model code (SC-26): no UI, messaging or navigation; it
// returns values a controller can show. `addFiles` sends nothing: it requests
// a pass of the manager's SingleFlightRunner, which allocates the batches.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, mapEquals, setEquals, visibleForTesting;
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/operations/gate_wait.dart';
import 'package:frontend/services/operations/submission_failure_rules.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/uploads/upload_import_sync.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';
import 'package:frontend/services/uploads/upload_other_device.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';
import 'package:frontend/services/uploads/upload_source.dart';
import 'package:frontend/services/uploads/upload_types.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/uploads/uploads_visibility.dart';
import 'package:uuid/uuid.dart';

export 'package:frontend/services/uploads/upload_loss_reporter.dart';
export 'package:frontend/services/uploads/upload_types.dart';

class UploadManager {
  UploadManager({
    required UploadsApi api,
    required DurableSubmission submissions,
    required UploadIntentStore intents,
    required ServerBindingRepository binding,
    required ServerBindingGate gate,
    required Clock clock,
    required Future<AdvertisedFeature<UploadsFeature>?> Function() feature,
    required bool Function() isOffline,
    Future<void> Function()? refreshCapabilities,
    String Function()? newUuid,
    Timer Function(Duration, void Function()) timer = Timer.new,
    BackoffSchedule? passBackoff,
    BackoffSchedule? transferBackoff,
    ValueListenable<bool>? visible,
    UploadReviewTransport? review,
    /// Opens a transfer's source (injectable for deterministic tests).
    Future<FileUploadSource> Function(String path, {String? displayName})?
        openSource,
  }) : _openSource = openSource ?? FileUploadSource.open,
       _api = api,
       _submissions = submissions,
       _intents = intents,
       _binding = binding,
       _gate = gate,
       _clock = clock,
       _feature = feature,
       _isOffline = isOffline,
       _refreshCapabilities = refreshCapabilities,
       _newUuid = newUuid ?? (() => const Uuid().v4()),
       _timer = timer,
       _review = review ?? HttpUploadReviewTransport(api),
       _transferBackoff = transferBackoff ?? BackoffSchedule() {
    _runner = SingleFlightRunner(
      name: 'uploads',
      pass: _runPass,
      backoff: passBackoff ?? BackoffSchedule(),
      timer: timer,
    );
    // Rows a previous run left committing are followed from the start.
    _followUntil = clock.nowUtcMs() + followLimit.inMilliseconds;
    _visible = visible ?? ValueNotifier<bool>(false);
    _visible.addListener(_onVisibleChanged);
    if (_visible.value) _onVisibleChanged();
  }

  final UploadReviewTransport _review;
  final Future<FileUploadSource> Function(String path, {String? displayName})
  _openSource;
  late final ValueListenable<bool> _visible;
  Timer? _pollTimer;

  /// Until when (UTC ms) a hidden Uploads page still follows this device's
  /// own commits; null when nothing is followed.
  int? _followUntil;

  bool get _following =>
      _followUntil != null && _clock.nowUtcMs() < _followUntil!;

  void _onVisibleChanged() {
    _publishOtherDeviceSending();
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_closing.isCompleted) return;
    if (!_visible.value) {
      if (_following) _armPoll();
      return;
    }
    _armPoll();
    _adoptPending = true; // list the server's work once per page entry
    _entry++;
    // Entering the page re-reads even while a capability wait is pending.
    _runner.request('entered', bypassBackoff: true);
    _runner.request('poll');
  }

  /// Set on page entry, cleared when the server listing finished (7-R1-22).
  bool _adoptPending = false;

  /// Counts page entries: a listing that began before a later entry does not
  /// clear that entry's pending listing.
  int _entry = 0;

  void _armPoll() {
    if (_closing.isCompleted) return; // a pass ending after quiesce
    _pollTimer = _timer(pollInterval, () {
      if (_closing.isCompleted) return;
      // Time alone ends "being sent", also while no pass runs.
      _publishOtherDeviceSending();
      if (!_visible.value && (!_following || _isOffline())) return;
      if (!_isOffline()) _runner.request('poll');
      _armPoll();
    });
  }

  final UploadsApi _api;
  final DurableSubmission _submissions;
  final UploadIntentStore _intents;
  final ServerBindingRepository _binding;
  final ServerBindingGate _gate;
  final Clock _clock;
  final Future<AdvertisedFeature<UploadsFeature>?> Function() _feature;
  final bool Function() _isOffline;
  final Future<void> Function()? _refreshCapabilities;
  final String Function() _newUuid;
  final BackoffSchedule _transferBackoff;
  final Timer Function(Duration, void Function()) _timer;

  /// Items whose running PUT the watchdog aborted.
  final _stalled = <String>{};
  late final SingleFlightRunner _runner;

  /// Hashes the sources, leaves out the ones the server would refuse, and
  /// persists the rest as `allocating` intents plus a prepared allocation
  /// submission per batch. Throws [UploadsUnavailable] (and writes nothing)
  /// when uploads aren't advertised or the binding is gone.
  Future<AddFilesResult> addFiles(List<FileUploadSource> sources) async {
    if (isClosed) throw const UploadsUnavailable();
    final advertised = await _feature();
    if (advertised == null) throw const UploadsUnavailable();
    final token = (await _binding.current())?.localBindingId;
    if (token == null) throw const UploadsUnavailable();
    final limits = advertised.block.limits;

    final leftOut = <LeftOutFile>[];
    final accepted = <(FileUploadSource, UploadSourceDescriptor)>[];
    for (final source in sources) {
      final LeftOutReason? reason;
      if (source.length == 0) {
        reason = LeftOutReason.empty;
      } else if (limits.maxFileBytes != null &&
          source.length > limits.maxFileBytes!) {
        reason = LeftOutReason.tooLarge;
      } else {
        reason = null;
      }
      if (reason != null) {
        leftOut.add(LeftOutFile(source.displayName, reason));
        continue;
      }
      try {
        accepted.add((source, await UploadSourceDescriptor.of(source)));
      } on UploadSourceUnavailable {
        leftOut.add(LeftOutFile(source.displayName, LeftOutReason.unreadable));
      } on UploadSourceChanged {
        leftOut.add(
          LeftOutFile(source.displayName, LeftOutReason.changedWhileReading),
        );
      }
    }

    final batches = <List<(FileUploadSource, UploadSourceDescriptor)>>[];
    var bytes = 0;
    for (final file in accepted) {
      final length = file.$2.length;
      final full =
          batches.isNotEmpty &&
          ((limits.maxFilesPerBatch != null &&
                  batches.last.length >= limits.maxFilesPerBatch!) ||
              (limits.maxBatchBytes != null &&
                  bytes + length > limits.maxBatchBytes!));
      if (batches.isEmpty || full) {
        batches.add([]);
        bytes = 0;
      }
      batches.last.add(file);
      bytes += length;
    }

    final batchUuids = <String>[];
    for (final batch in batches) {
      final batchUuid = _newUuid();
      final itemUuids = [for (final _ in batch) _newUuid()];
      final request = AllocationRequest(
        batchUuid: batchUuid,
        items: [
          for (var i = 0; i < batch.length; i++)
            AllocationItem(
              itemUuid: itemUuids[i],
              filename: batch[i].$1.displayName,
              byteLength: batch[i].$2.length,
              sha256: batch[i].$2.sha256,
            ),
        ],
      );
      await _intents.insertAll(token, [
        for (var i = 0; i < batch.length; i++)
          NewUploadIntent(
            itemUuid: itemUuids[i],
            batchUuid: batchUuid,
            selectionIndex: i,
            displayName: batch[i].$1.displayName,
            descriptor: batch[i].$2,
          ),
      ], state: UploadIntentState.allocating);
      await _submissions.prepare(
        kind: 'upload_allocation',
        operationUuid: batchUuid,
        frozenBodyJson: request.toFrozenJson(),
        bindingToken: token,
      );
      batchUuids.add(batchUuid);
    }
    _runner.request('addFiles');
    return AddFilesResult(batchUuids: batchUuids, leftOut: leftOut);
  }

  /// Bytes sent so far per transferring item.
  ValueListenable<Map<String, int>> get progress => _progress;

  /// The server's per-item `retryable` flag for failed items (SC-22), from
  /// the last listing that held the item. In memory only; absent = unknown.
  ValueListenable<Map<String, bool>> get retryable => _retryable;

  /// The batches another device is sending (sign-off s7-app-texts), from
  /// this device's own reads and clock ([UploadArrivals]). In memory only.
  ValueListenable<Set<String>> get otherDeviceSending => _otherDeviceSending;
  final _otherDeviceSending = ValueNotifier<Set<String>>(const {});
  UploadArrivals _arrivals = UploadArrivals.empty;

  void _publishOtherDeviceSending() {
    final next = _arrivals.sendingBatches(_clock.nowUtcMs());
    if (!setEquals(next, _otherDeviceSending.value)) {
      _otherDeviceSending.value = next;
    }
  }

  final _retryable = ValueNotifier<Map<String, bool>>(const {});

  void _noteRetryable(Iterable<UploadItem> items) {
    final next = <String, bool>{..._retryable.value};
    for (final item in items) {
      // The server also flags `allocated` items after a dead transfer; only
      // a failed item offers Retry.
      final flag = item.rawState == ServerItemState.failed
          ? item.error?.retryable
          : null;
      flag == null ? next.remove(item.itemUuid) : next[item.itemUuid] = flag;
    }
    if (!mapEquals(next, _retryable.value)) _retryable.value = next;
  }

  final _progress = ValueNotifier<Map<String, int>>(const {});
  /// Running transfers: item UUID → that transfer's own abort.
  final _running = <String, Completer<void>>{};

  /// Items the user cancelled in this scope; their transfer writes nothing.
  final _cancelRequested = <String>{};

  /// A 401 answered a transfer: nothing more is sent until the scope ends or
  /// [resumeAfterBoundServerBack] (another server had sent the 401).
  bool _authParked = false;

  /// Another server answered: every running PUT was stopped and leaves its
  /// row untouched. Cleared when a pass gets a verified token again.
  bool _instanceChanged = false;

  void _onInstanceChanged() {
    _instanceChanged = true;
    _followUntil = null;
    for (final abort in _running.values) {
      if (!abort.isCompleted) abort.complete();
    }
  }

  /// The running transfer futures, awaited by [quiesce].
  final _transfers = <String, Future<void>>{};

  /// No transfer starts before this time (UTC ms), after a busy or failed
  /// send; null when there is no wait.
  int? _notBefore;

  /// Cancels one file. A rejected item (the server never had it) is just
  /// marked cancelled; any other unfinished item becomes `cancelling`, its
  /// running transfer is aborted, and the runner sends the DELETE.
  /// An item this device holds no intent for throws [UploadIntentMissing].
  Future<void> cancel(String itemUuid) async {
    if (isClosed) return;
    final token = (await _binding.current())?.localBindingId;
    if (token == null) return;
    final intent = await _intents.find(token, itemUuid);
    if (intent == null) throw const UploadIntentMissing();
    if (endedStates.contains(intent.lastState)) return;
    if (intent.lastState == UploadIntentState.rejected) {
      await _setItems(token, [intent], ServerItemState.cancelled, null);
      return;
    }
    _cancelRequested.add(itemUuid);
    await _setItems(token, [intent], UploadIntentState.cancelling, null);
    final abort = _running[itemUuid];
    if (abort != null && !abort.isCompleted) abort.complete();
    _runner.request('cancel', bypassBackoff: true);
  }


  /// Offers a file for an item whose source was lost (`needs_reselect`) or
  /// changed (`source_changed`). Only the identical bytes are accepted; the
  /// item is then sent again under a fresh transfer operation id.
  Future<ReselectOutcome> reselect(
    String itemUuid,
    FileUploadSource source,
  ) async {
    if (isClosed) return ReselectOutcome.notNeeded;
    final token = (await _binding.current())?.localBindingId;
    if (token == null) return ReselectOutcome.notNeeded;
    final intent = await _intents.find(token, itemUuid);
    if (intent == null ||
        (intent.lastState != UploadIntentState.needsReselect &&
            intent.lastState != UploadIntentState.sourceChanged)) {
      return ReselectOutcome.notNeeded;
    }
    final UploadSourceDescriptor descriptor;
    try {
      descriptor = await UploadSourceDescriptor.of(source);
    } on UploadSourceUnavailable {
      return ReselectOutcome.unreadable;
    } on UploadSourceChanged {
      return ReselectOutcome.unreadable;
    }
    if (descriptor.length != intent.expectedLength ||
        descriptor.sha256.toLowerCase() !=
            intent.expectedSha256?.toLowerCase()) {
      return ReselectOutcome.differentFile;
    }
    // A deliberate re-send: a new operation id (SC-14).
    await _intents.update(
      token,
      [itemUuid],
      sourceDescriptorJson: Value(descriptor.locationJson()),
      lastState: const Value(UploadIntentState.allocated),
      lastErrorCode: const Value(null),
      transferOperationUuid: Value(_newUuid()),
    );
    _runner.request('reselect', bypassBackoff: true);
    return ReselectOutcome.accepted;
  }

  /// A PUT whose progress has not moved for this long is aborted (the
  /// `putStream` call has no timeout of its own).
  /// How often a visible Uploads page, or a hidden one following its own
  /// commits, asks for the items' server states.
  static const pollInterval = Duration(seconds: 5);

  /// While Uploads is hidden, the poll follows this device's own commits for
  /// at most this long after the last one was sent (or the manager started):
  /// at most followLimit / pollInterval reads of each own batch's item pages
  /// per window (a wall-clock window, so it also ends across a suspend).
  /// It stops at a terminal state, the window's end, offline, a 401, an
  /// instance change and quiesce.
  static const followLimit = Duration(minutes: 10);

  static const stallTimeout = Duration(seconds: 60);
  /// How often a running PUT is checked for a stall.
  static const stallCheckInterval = Duration(seconds: 5);

  /// The submission helper this manager sends through.
  @visibleForTesting
  DurableSubmission get submissions => _submissions;

  /// [quiesce] has begun: nothing is sent any more.
  bool get isClosed => _closing.isCompleted;

  /// Asks the server to retry a failed or duplicate-conflict item, once, at
  /// the review version it reports now. An item back at `allocated` gets a
  /// fresh transfer operation id (a deliberate new send, SC-14). Any other
  /// error, including a changed server, is rethrown with nothing written.
  /// An item this device holds no intent for throws [UploadIntentMissing].
  Future<RetryOutcome> retry(String itemUuid) async {
    if (isClosed || _isOffline()) throw const UploadsUnavailable();
    if (featureForNetwork(await _feature()) == null) {
      throw const UploadsUnavailable();
    }
    final token = (await _binding.current())?.localBindingId;
    if (token == null) throw const UploadsUnavailable();
    final intent = await _intents.find(token, itemUuid);
    if (intent == null) throw const UploadIntentMissing();

    Future<void> store(UploadItem item, {bool fresh = false}) =>
        _intents.update(
          token,
          [itemUuid],
          lastState: Value(item.rawState),
          lastErrorCode: Value(item.error?.code),
          transferOperationUuid:
              fresh && item.rawState == ServerItemState.allocated
              ? Value(_newUuid())
              : const Value.absent(),
        );

    final current = await _api.getItem(itemUuid, abortTrigger: _closing.future);
    try {
      final item = await _api.retry(
        itemUuid,
        expectedReviewVersion: current.reviewVersion,
        abortTrigger: _closing.future,
      );
      await store(item, fresh: true);
      if (item.rawState == ServerItemState.allocated) {
        _runner.request('retry', bypassBackoff: true);
      }
      return RetryOutcome.accepted;
    } on ApiException catch (e) {
      final outcome = e.statusCode != 409
          ? null
          : switch (e.errorCode) {
              'upload_item_not_retryable' => RetryOutcome.notRetryable,
              'upload_review_version_conflict' => RetryOutcome.changed,
              _ => null,
            };
      if (outcome == null) rethrow;
      await store(
        await _api.getItem(itemUuid, abortTrigger: _closing.future),
      );
      return outcome;
    }
  }

  /// Freezes a review action (commit or resolve-duplicate) under one
  /// operation id per review version and asks the runner to send it. The
  /// same version reuses its id; a new version mints a new one (SC-14).
  /// A [SubmissionConflict] (same id, different body) goes to the caller.
  /// An item this device holds no intent for throws [UploadIntentMissing].
  Future<void> submitReviewAction(
    String itemUuid,
    ReviewActionKind kind, {
    required int reviewVersion,
    required Map<String, dynamic> body,
  }) async {
    if (isClosed) throw const UploadsUnavailable();
    final token = (await _binding.current())?.localBindingId;
    if (token == null) throw const UploadsUnavailable();
    final intent = await _intents.find(token, itemUuid);
    if (intent == null) throw const UploadIntentMissing();
    final state = intent.operationUuid == null
        ? null
        : (await _submissions.find(intent.operationUuid!))?.state;
    final reuse =
        intent.operationUuid != null &&
        intent.reviewGeneration == reviewVersion &&
        (state == null || _unresolved.contains(state));
    final operation = reuse ? intent.operationUuid! : _newUuid();
    if (!reuse) {
      await _intents.update(
        token,
        [itemUuid],
        operationUuid: Value(operation),
        reviewGeneration: Value(reviewVersion),
      );
    }
    await _submissions.prepare(
      kind: _reviewKinds[kind]!,
      operationUuid: operation,
      frozenBodyJson: jsonEncode({...body, 'operation_uuid': operation}),
      bindingToken: token,
    );
    await _intents.update(
      token,
      [itemUuid],
      lastState: const Value(UploadIntentState.reviewSubmitted),
      lastErrorCode: const Value(null),
      onlyIfStateIn: reviewableStates,
    );
    _runner.request('review', bypassBackoff: true);
  }

  /// A submission still waiting for an answer; a settled one is never reused.
  static const _unresolved = {
    SubmissionState.prepared,
    SubmissionState.sent,
    SubmissionState.ambiguous,
  };

  static const _reviewKinds = {
    ReviewActionKind.commit: 'upload_commit',
    ReviewActionKind.resolveDuplicate: 'upload_resolve_duplicate',
  };

  /// Requests a pass (e.g. at scope start, to resume unfinished intents).
  void start() => _runner.request('start');

  /// Requests a pass for [reason] (recovery edges bypass a pending backoff).
  void request(String reason, {bool bypassBackoff = false}) =>
      _runner.request(reason, bypassBackoff: bypassBackoff);

  /// Completes when no pass is running, or the running one waits for the
  /// binding gate to verify (a wait only the gate or [quiesce] ends).
  Future<void> idle() => _gateWait.waiting
      ? Future.value()
      : Future.any([_runner.whenIdle(), _gateWait.nextWaitBegins]);

  Future<void> quiesce() async {
    if (!_closing.isCompleted) _closing.complete();
    for (final abort in _running.values) {
      if (!abort.isCompleted) abort.complete(); // ends the PUT and its watchdog
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    _visible.removeListener(_onVisibleChanged);
    await _runner.quiesce();
    await Future.wait(_transfers.values.toList());
  }

  final _closing = Completer<void>();

  /// A pass's wait for the server check; [quiesce] ends it.
  late final _gateWait = GateWait(gate: _gate, closing: _closing.future);

  /// One pass: allocates every batch that still has `allocating` intents.
  Future<PassOutcome> _runPass(Set<String> reasons) async {
    if (_authParked) return _parked();
    if (_isOffline()) return const PassFailed(BackoffReason.offline);
    var feature = featureForNetwork(await _feature());
    if (feature == null && _refreshCapabilities != null) {
      // Online with no live block (a failed /app/info read leaves it cached or
      // absent): re-read once and decide on the fresh answer (7-R1-02).
      try {
        await _refreshCapabilities();
      } catch (_) {}
      feature = featureForNetwork(await _feature());
    }
    if (feature == null) {
      return const PassFailed(BackoffReason.capabilityMissing);
    }
    try {
      final token = await _gateWait.token();
      if (token == null) return const PassDone();
      _instanceChanged = false;
      final batches = <String, List<UploadIntentRecord>>{};
      for (final intent in await _intents.forBinding(token)) {
        (batches[intent.batchUuid] ??= []).add(intent);
      }
      var transient = false;
      for (final MapEntry(key: batchUuid, value: items) in batches.entries) {
        if (!await _needsAllocation(items)) continue;
        final outcome = await _allocate(token, batchUuid, items);
        switch (outcome) {
          case SubmissionAccepted():
            await _setItems(
              token,
              _allocating(items),
              UploadIntentState.allocated,
              null,
              onlyIfStateIn: const {UploadIntentState.allocating},
            );
          case SubmissionRejected(:final code):
            await _setItems(
              token,
              _allocating(items),
              UploadIntentState.rejected,
              code,
              onlyIfStateIn: const {UploadIntentState.allocating},
            );
            await _setItems(
              token,
              _cancelling(items),
              ServerItemState.cancelled,
              null,
              onlyIfStateIn: const {UploadIntentState.cancelling},
            );
          case SubmissionAmbiguous(:final cause):
            if (isUnauthorized(cause)) {
              return _parked();
            }
            transient = true;
          case SubmissionFenced():
            return const PassDone();
        }
        if (transient) break;
      }
      // User actions first, then the status poll; none waits for a transfer.
      final steps = [
        () => _sendCancels(token),
        () => _sendReviewActions(token),
        if (_adoptPending && _visible.value) () => _adoptServerWork(token),
        if (reasons.contains('poll') && _visible.value)
          () => _pollStatuses(token),
        () => _followOwnCommits(
          token,
          poll: reasons.contains('poll') && !_visible.value,
        ),
      ];
      for (final step in steps) {
        switch (await step()) {
          case _StepDone():
            break;
          case _StepRetry():
            transient = true;
          case _StepParked():
            return _parked();
        }
      }
      final wait = _transferWait();
      if (wait == null) await _dispatchTransfers(token, feature.limits);
      return transient || wait != null
          ? PassFailed(BackoffReason.transient, retryAfter: wait)
          : const PassDone();
    } on BindingFencedException {
      return const PassDone();
    } on BindingGateClosedException {
      return const PassDone();
    } on ServerInstanceChangedException {
      _onInstanceChanged();
      return const PassFailed(BackoffReason.offline);
    } on UploadTransferAborted {
      return const PassDone(); // quiesce ended a query
    }
  }

  /// The bound server is verified again after another server's 401: the
  /// 401 park ends, this device's own commits still in flight are followed
  /// again (as from the start), and the next request runs a pass.
  void resumeAfterBoundServerBack() {
    _authParked = false;
    _followUntil = _clock.nowUtcMs() + followLimit.inMilliseconds;
    _runner.resumeParked();
  }

  /// A wait for auth: nothing is followed until a new pass gets through.
  PassOutcome _parked() {
    _followUntil = null;
    return const PassParked();
  }

  static List<UploadIntentRecord> _allocating(List<UploadIntentRecord> items) =>
      [for (final i in items) if (i.lastState == UploadIntentState.allocating) i];

  static List<UploadIntentRecord> _cancelling(List<UploadIntentRecord> items) =>
      [for (final i in items) if (i.lastState == UploadIntentState.cancelling) i];

  /// Sends the frozen review actions that are not settled yet, each through
  /// its submission: a lost answer is resolved by the item's status first.
  Future<_StepResult> _sendReviewActions(String token) async {
    final intents = await _intents.forBinding(token);
    var result = const _StepDone() as _StepResult;
    for (final MapEntry(key: kind, value: name) in _reviewKinds.entries) {
      for (final row in await _submissions.unresolved(
        bindingToken: token,
        kind: name,
      )) {
        final intent = intents
            .where((i) => i.operationUuid == row.operationUuid)
            .firstOrNull;
        if (intent == null) continue; // superseded by a newer review version
        final SubmissionOutcome outcome;
        try {
          outcome = await _submissions.submit(
          row.operationUuid,
          send: (r) async => await _review.send(
            kind,
            intent.itemUuid,
            r.frozenBodyJson!,
            abortTrigger: Future.any([r.abortSignal, _closing.future]),
          ),
          status: (_) async {
            final UploadItem item;
            try {
              item = await _api.getItem(
                intent.itemUuid,
                abortTrigger: _closing.future,
              );
            } catch (e) {
              throw StatusQueryFailed(e);
            }
            final state = item.rawState;
            // A resolve-duplicate is acted on only by `duplicate`: an item
            // still in `duplicate_conflict` was not resolved.
            final resolve = kind == ReviewActionKind.resolveDuplicate;
            final accepted = resolve
                ? const {ServerItemState.duplicate}
                : reviewAcceptedStates;
            if (accepted.contains(state)) {
              return StatusAccepted(item.toJson());
            }
            final pending = resolve
                ? reviewableStates
                : const {ServerItemState.reviewReady};
            return pending.contains(state) &&
                    item.reviewVersion == intent.reviewGeneration
                ? const StatusAbsent()
                : const StatusRejected('review_stale');
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
            // A refused review answer is final whatever `retryable` says.
            _ => _commonFailure(e) ?? refusalIsFinal(e),
          },
        );
        } on StatusQueryFailed catch (e) {
          throw e.cause;
        }
        switch (outcome) {
          case SubmissionAccepted(:final receipt):
            await _intents.update(
              token,
              [intent.itemUuid],
              lastState: Value(receipt['state'] as String),
            );
            if (receipt['state'] == ServerItemState.committing) {
              _followUntil = _clock.nowUtcMs() + followLimit.inMilliseconds;
            }
          case SubmissionRejected(:final code):
            // The item was reviewable before the send: it is again, whatever
            // the follow-up read says.
            await _intents.update(
              token,
              [intent.itemUuid],
              lastState: const Value(ServerItemState.reviewReady),
              lastErrorCode: Value(code),
              onlyIfStateIn: const {UploadIntentState.reviewSubmitted},
            );
            try {
              final item = await _api.getItem(
                intent.itemUuid,
                abortTrigger: _closing.future,
              );
              await _intents.update(
                token,
                [intent.itemUuid],
                lastState: Value(item.rawState),
                lastErrorCode: Value(
                  code == 'review_stale' ? item.error?.code ?? code : code,
                ),
              );
            } on ServerInstanceChangedException {
              rethrow;
            } catch (e) {
              final failure = _stepFailure(e);
              if (failure == null) rethrow;
              if (failure is _StepParked) return failure;
              result = failure;
            }
          case SubmissionAmbiguous(:final cause):
            if (isUnauthorized(
              cause is StatusQueryFailed ? cause.cause : cause,
            )) {
              return const _StepParked();
            }
            result = const _StepRetry();
          case SubmissionFenced():
            break;
        }
      }
    }
    return result;
  }

  /// What a failed request means for a pass step: a 401 is a wait for auth,
  /// a transport or API error a retry. Null for anything else (the caller
  /// rethrows it).
  static _StepResult? _stepFailure(Object e) => switch (e) {
    ApiException(statusCode: 401) => const _StepParked(),
    // A withheld request (the server is not verified; nothing was sent) is
    // retried like a transport failure (sign-off OPEN-M-11).
    ApiException() ||
    NetworkException() ||
    TimeoutException() ||
    TokenWithheldException() => const _StepRetry(),
    _ => null,
  };

  /// The failure hook cases every submission shares: another server answered,
  /// or the manager is closing. The rows stay as they were.
  static SubmissionFailureDisposition? _commonFailure(Object e) => switch (e) {
    // TokenWithheldException: nothing was sent, the rows stay as they were
    // (sign-off OPEN-M-11).
    ServerInstanceChangedException() ||
    UploadTransferAborted() ||
    TokenWithheldException() => const LeaveSubmissionUntouched(),
    _ => null,
  };

  /// Lists the user's batches and items on the server and adopts the ones
  /// this device has no intent for (no source: never transferred from here);
  /// a known ready row takes an ended state. Clears [_adoptPending] on success.
  Future<_StepResult> _adoptServerWork(String token) async {
    final entry = _entry;
    try {
      String? batchCursor;
      // A repeated cursor would loop forever.
      final seenBatchCursors = <String>{};
      final listed = <String>{};
      do {
        final batches = await _api.listBatches(
          after: batchCursor,
          abortTrigger: _closing.future,
        );
        for (final batch in batches.batches) {
          listed.add(batch.batchUuid);
          String? cursor;
          final seenCursors = <String>{};
          do {
            final page = await _api.listItems(
              batch.batchUuid,
              after: cursor,
              abortTrigger: _closing.future,
            );
            _noteRetryable(page.items);
            _arrivals = _arrivals.observe(page.items, _clock.nowUtcMs());
            await _intents.adoptListedItems(token, page.items);
            await _intents.mirrorReviewStates(token, page.items);
            cursor = page.nextAfter;
          } while (cursor != null && seenCursors.add(cursor));
        }
        batchCursor = batches.nextAfter;
      } while (batchCursor != null && seenBatchCursors.add(batchCursor));
      // A failed row of a batch the listing left out: the server may have
      // forgotten that batch (retention). Read it once to tell. An unpacked
      // archive is finished on the server and stays as it is.
      const failed = ServerItemState.failed;
      final unlisted = <String, List<String>>{};
      for (final i in await _intents.forBinding(token)) {
        if (i.lastState == failed && !listed.contains(i.batchUuid)) {
          (unlisted[i.batchUuid] ??= []).add(i.itemUuid);
        }
      }
      for (final MapEntry(key: batch, value: rows) in unlisted.entries) {
        try {
          await _api.getBatch(batch, abortTrigger: _closing.future);
        } catch (e) {
          if (await _endIfBatchForgotten(
            token,
            e,
            rows,
            onlyIfStateIn: const {failed},
          )) {
            continue;
          }
          final failure = _stepFailure(e);
          if (e is ServerInstanceChangedException ||
              e is UploadTransferAborted ||
              failure == null ||
              failure is _StepParked) {
            rethrow;
          }
          // Any other failure leaves this batch's rows as they are; the next
          // page entry reads it again.
        }
      }
    } catch (e) {
      final failure = _stepFailure(e);
      if (failure == null) rethrow;
      return failure;
    } finally {
      _publishOtherDeviceSending();
    }
    if (entry == _entry) _adoptPending = false;
    return const _StepDone();
  }

  /// Reads the item pages of the batches that hold an item in a state the
  /// server changes on its own, and stores each such item's new state. Also
  /// reads the batches of rows waiting for another device (their stored
  /// state is left to the mirror rule), to tell whether it is sending them.
  Future<_StepResult> _pollStatuses(String token, {Set<String>? only}) async {
    try {
      return await _readStatuses(token, only: only);
    } finally {
      // Also after a failed read: time alone ends "being sent".
      _publishOtherDeviceSending();
    }
  }

  Future<_StepResult> _readStatuses(String token, {Set<String>? only}) async {
    final all = await _intents.forBinding(token);
    final local = {
      for (final i in all)
        if (serverDrivenStates.contains(i.lastState)) i.itemUuid: i,
    };
    final waiting = {
      for (final i in all)
        if (i.lastState == UploadIntentState.onOtherDevice) i.itemUuid: i,
    };
    final batches = {
      for (final i in [...local.values, ...waiting.values])
        if (only == null || only.contains(i.batchUuid)) i.batchUuid,
    };
    _StepResult? retry;
    for (final batch in batches) {
      try {
        String? cursor;
        // A repeated cursor would loop forever.
        final seenCursors = <String>{};
        do {
          final page = await _api.listItems(
            batch,
            after: cursor,
            abortTrigger: _closing.future,
          );
          _noteRetryable(page.items);
          _arrivals = _arrivals.observe(page.items, _clock.nowUtcMs());
          await _intents.adoptListedChildren(token, page.items);
          // A waiting row whose file arrived takes the server's state.
          await _intents.mirrorReviewStates(token, [
            for (final item in page.items)
              if (waiting.containsKey(item.itemUuid)) item,
          ]);
          for (final item in page.items) {
            final intent = local[item.itemUuid];
            if (intent == null ||
                (intent.lastState == item.rawState &&
                    intent.lastErrorCode == item.error?.code)) {
              continue;
            }
            await _intents.update(
              token,
              [item.itemUuid],
              lastState: Value(item.rawState),
              lastErrorCode: Value(item.error?.code),
              onlyIfStateIn: serverDrivenStates,
            );
          }
          cursor = page.nextAfter;
        } while (cursor != null && seenCursors.add(cursor));
      } catch (e) {
        if (await _endIfBatchForgotten(
          token,
          e,
          [
            for (final i in [...local.values, ...waiting.values])
              if (i.batchUuid == batch) i.itemUuid,
          ],
          onlyIfStateIn: {
            ...serverDrivenStates,
            UploadIntentState.onOtherDevice,
          },
        )) {
          continue;
        }
        final failure = _stepFailure(e);
        if (failure == null) rethrow;
        if (failure is _StepParked) return failure;
        retry = failure;
      }
    }
    return retry ?? const _StepDone();
  }

  /// When [e] says the batch ended and the server forgot it, its rows
  /// [itemUuids] in [onlyIfStateIn] end here as expired; returns whether it
  /// did.
  Future<bool> _endIfBatchForgotten(
    String token,
    Object e,
    List<String> itemUuids, {
    required Set<String> onlyIfStateIn,
  }) async {
    if (!isBatchForgotten(e)) return false;
    await _intents.update(
      token,
      itemUuids,
      lastState: const Value(ServerItemState.expired),
      lastErrorCode: const Value('upload_batch_not_found'),
      onlyIfStateIn: onlyIfStateIn,
    );
    return true;
  }

  /// While Uploads is hidden: keeps reading the batches that hold this
  /// device's own committing rows (an import ends on the server seconds after
  /// the commit is answered) until they end or the follow window does.
  Future<_StepResult> _followOwnCommits(
    String token, {
    required bool poll,
  }) async {
    if (_followUntil == null) return const _StepDone();
    Future<Set<String>> own() async => {
      for (final i in await _intents.forBinding(token))
        if (i.lastState == ServerItemState.committing &&
            i.operationUuid != null)
          i.batchUuid,
    };
    var batches = await own();
    _StepResult result = const _StepDone();
    if (poll && batches.isNotEmpty && _following) {
      result = await _pollStatuses(token, only: batches);
      if (result is _StepParked) {
        _followUntil = null;
        return result;
      }
      batches = await own();
    }
    if (batches.isEmpty || !_following) {
      _followUntil = null;
    } else if (!_visible.value && _pollTimer?.isActive != true) {
      _armPoll();
    }
    return result;
  }

  /// Whether the batch's allocation is still to be sent: an item is
  /// `allocating`, or one was cancelled before the server accepted the
  /// batch (the frozen body includes it).
  Future<bool> _needsAllocation(List<UploadIntentRecord> items) async {
    if (items.any((i) => i.lastState == UploadIntentState.allocating)) {
      return true;
    }
    if (_cancelling(items).isEmpty) return false;
    // Adopted work (no row was picked on this device) is never allocated here.
    if (items.every((i) => i.expectedSha256 == null)) return false;
    final state = (await _submissions.find(items.first.batchUuid))?.state;
    return state == null ||
        state == SubmissionState.prepared ||
        state == SubmissionState.sent ||
        state == SubmissionState.ambiguous;
  }

  /// Sends the pending cancels, never delayed by a transfer wait. A batch
  /// whose allocation is still pending waits for it: the frozen body
  /// includes the item.
  Future<_StepResult> _sendCancels(String token) async {
    final all = await _intents.forBinding(token);
    final byBatch = <String, List<UploadIntentRecord>>{};
    for (final i in all) {
      (byBatch[i.batchUuid] ??= []).add(i);
    }
    final pendingBatches = {
      for (final MapEntry(:key, :value) in byBatch.entries)
        if (await _needsAllocation(value)) key,
    };
    var result = const _StepDone() as _StepResult;
    for (final intent in _cancelling(all)) {
      if (pendingBatches.contains(intent.batchUuid)) continue;
      try {
        UploadItem item;
        try {
          item = await _api.cancelItem(
            intent.itemUuid,
            abortTrigger: _closing.future,
          );
        } on ApiException catch (e) {
          if (e.statusCode == 404) {
            await _setItems(token, [intent], ServerItemState.cancelled, null);
            continue;
          }
          if (e.statusCode != 409 ||
              e.errorCode != 'upload_item_not_cancellable') {
            rethrow;
          }
          item = await _api.getItem(
            intent.itemUuid,
            abortTrigger: _closing.future,
          );
        }
        // A server that still holds the file as sendable did not act on the
        // cancel: the user's `cancelling` stays and is never undone.
        if (awaitingOrReceivingBytesStates.contains(item.rawState)) continue;
        await _intents.update(
          token,
          [intent.itemUuid],
          lastState: Value(item.rawState),
          lastErrorCode: Value(item.error?.code),
          onlyIfStateIn: const {UploadIntentState.cancelling},
        );
      } catch (e) {
        final failure = _stepFailure(e);
        if (failure == null) rethrow;
        if (failure is _StepParked) return failure;
        result = failure;
      }
    }
    return result;
  }

  /// The time left before transfers may start again, or null.
  Duration? _transferWait() {
    final until = _notBefore;
    if (until == null) return null;
    final remaining = until - _clock.nowUtcMs();
    if (remaining <= 0) {
      _notBefore = null;
      return null;
    }
    return Duration(milliseconds: remaining);
  }

  /// Starts transfers for `allocated` and `transferring` intents (the latter
  /// were interrupted; their submission resolves status-first) while a slot
  /// is free. A missing `receives_per_user` means one at a time (DEV-7-02).
  Future<void> _dispatchTransfers(String token, UploadLimits limits) async {
    if (isClosed) return;
    // Unknown is one at a time (DEV-7-02); a known 0 is no transfer now.
    final slots = min(2, limits.receivesPerUser ?? 1);
    for (final intent in await _intents.forBinding(token)) {
      if (isClosed) break;
      if (_cancelRequested.contains(intent.itemUuid)) continue;
      if (intent.parentItemUuid != null) continue; // a ZIP child is never PUT
      final needsBytes = UploadIntentState.awaitingBytes.contains(
        intent.lastState,
      );
      if (needsBytes &&
          !intent.bytesOnThisDevice &&
          !_running.containsKey(intent.itemUuid)) {
        // Not picked on this device (adopted): never transferred from here.
        await _intents.update(
          token,
          [intent.itemUuid],
          lastState: const Value(UploadIntentState.onOtherDevice),
          onlyIfStateIn: UploadIntentState.awaitingBytes,
        );
        continue;
      }
      // Not a break: later adopted rows still convert to on_other_device.
      if (_running.length >= slots) continue;
      if (!needsBytes || _running.containsKey(intent.itemUuid)) continue;
      _running[intent.itemUuid] = Completer<void>();
      _transfers[intent.itemUuid] = _runTransfer(token, intent);
    }
  }

  /// Runs detached: whatever happens, the slot is released and a new pass
  /// requested.
  Future<void> _runTransfer(String token, UploadIntentRecord intent) async {
    try {
      await _transfer(token, intent);
    } catch (e, st) {
      if (e is ServerInstanceChangedException) {
        _onInstanceChanged();
      } else if (!isClosed &&
          e is! UploadTransferAborted &&
          e is! BindingFencedException &&
          e is! BindingGateClosedException) {
        // Unclassified: wait out the backoff before the next attempt.
        _notBefore =
            _clock.nowUtcMs() +
            _transferBackoff
                .nextDelay(reason: BackoffReason.transient)
                .inMilliseconds;
      }
      developer.log(
        'upload transfer failed',
        name: 'UploadManager',
        error: e,
        stackTrace: st,
      );
    } finally {
      _running.remove(intent.itemUuid);
      _transfers.remove(intent.itemUuid);
      _stalled.remove(intent.itemUuid);
      _setProgress(intent.itemUuid, null);
      _runner.request('transferEnded');
    }
  }

  void _setProgress(String itemUuid, int? bytes) {
    final next = <String, int>{..._progress.value};
    bytes == null ? next.remove(itemUuid) : next[itemUuid] = bytes;
    _progress.value = next;
  }

  /// What the server says about the item, as a submission status.
  (SubmissionStatus, UploadItem) _statusOf(UploadItem item) {
    final state = item.rawState;
    final SubmissionStatus status = state == ServerItemState.allocated
        ? const StatusAbsent()
        : state == ServerItemState.receiving
        ? const StatusPending()
        : failedForGoodStates.contains(state)
        ? StatusRejected(item.error?.code ?? state)
        : StatusAccepted(item.toJson());
    return (status, item);
  }

  Future<void> _transfer(String token, UploadIntentRecord intent) async {
    bool cancelled() => _cancelRequested.contains(intent.itemUuid);
    if (cancelled()) return;
    const startable = UploadIntentState.awaitingBytes;
    final operation = intent.transferOperationUuid ?? _newUuid();
    FileUploadSource? opened; // the fresh-item check's source, reused by send
    if (intent.transferOperationUuid == null) {
      // No operation id yet: nothing was ever sent, so there is no lost
      // answer to settle by status and a lost source needs no request.
      Future<void> stop(String state) => _intents.update(
        token,
        [intent.itemUuid],
        lastState: Value(state),
        onlyIfStateIn: startable,
      );
      try {
        opened = await _openChecked(intent);
      } on UploadSourceUnavailable {
        return stop(UploadIntentState.needsReselect);
      } on UploadSourceChanged {
        return stop(UploadIntentState.sourceChanged);
      }
      // Persist-before-send needs the id; nothing else changes yet.
      await _intents.update(
        token,
        [intent.itemUuid],
        transferOperationUuid: Value(operation),
        onlyIfStateIn: startable,
      );
    }
    await _submissions.prepare(
      kind: 'upload_content',
      operationUuid: operation,
      frozenBodyJson: null,
      bindingToken: token,
    );

    UploadItem? fetched;
    SubmissionStatus? asked; // the status query's answer, for `send` to reuse
    Future<SubmissionStatus> status() async {
      final (answer, item) = _statusOf(
        await _api.getItem(intent.itemUuid, abortTrigger: _closing.future),
      );
      fetched = item;
      return answer;
    }

    final outcome = await _submissions.submit(
      operation,
      status: (_) async => asked = await status(),
      send: (request) async {
        final answer = asked ?? await status();
        asked = null;
        switch (answer) {
          case StatusAbsent():
            fetched = null; // the PUT's answer makes this stale
            // The source is opened only now: a file the server already
            // holds settles by status even when the local file is gone.
            // Opened first: _openChecked throws UploadSourceUnavailable for a
            // descriptor that cannot be read, so it is non-null after it.
            final source = opened ?? await _openChecked(intent);
            final descriptor = intent.descriptor!;
            await _intents.update(
              token,
              [intent.itemUuid],
              lastState: const Value(UploadIntentState.transferring),
              lastErrorCode: const Value(null),
              onlyIfStateIn: startable,
            );
            final abort = _running[intent.itemUuid]!;
            var lastProgressMs = _clock.nowUtcMs();
            Timer? watchdog;
            void arm() {
              watchdog = _timer(stallCheckInterval, () {
                if (_clock.nowUtcMs() - lastProgressMs <
                    stallTimeout.inMilliseconds) {
                  return arm();
                }
                _stalled.add(intent.itemUuid);
                if (!abort.isCompleted) abort.complete();
              });
            }

            arm();
            try {
              final item = await _api.putContent(
                intent.itemUuid,
                source,
                expectedLength: descriptor.length,
                expectedSha256: descriptor.sha256,
                onProgress: (n) {
                  lastProgressMs = _clock.nowUtcMs();
                  _setProgress(intent.itemUuid, n);
                },
                abortTrigger: Future.any([request.abortSignal, abort.future]),
              );
              return item.toJson();
            } finally {
              watchdog?.cancel();
            }
          case StatusAccepted(:final receipt):
            return receipt;
          case StatusRejected(:final code):
            throw _TransferStop(SubmissionTerminal(code));
          case StatusPending():
            throw const _TransferStop(
              SubmissionAmbiguousAs('upload_transfer_in_progress'),
            );
        }
      },
      onFailure: (e) => switch (e) {
        _TransferStop(:final disposition) => disposition,
        ServerInstanceChangedException() => _instanceChangedDuringTransfer(),
        UploadTransferAborted() when _instanceChanged =>
          const LeaveSubmissionUntouched(),
        UploadTransferAborted() when !isClosed => SubmissionAmbiguousAs(
          _stalled.contains(intent.itemUuid) ? 'stalled' : 'aborted',
        ),
        UploadSourceChanged() => const SubmissionTerminal('source_changed'),
        UploadSourceUnavailable() => const SubmissionTerminal(
          'source_unavailable',
        ),
        _ => _commonFailure(e),
      },
    );
    // A cancelled item's row belongs to the cancel; an aborted send is no
    // failure to pace.
    if (cancelled()) return;
    switch (outcome) {
      case SubmissionAccepted(:final receipt):
        await _intents.update(
          token,
          [intent.itemUuid],
          lastState: Value(receipt['state'] as String),
          lastErrorCode: const Value(null),
          onlyIfStateIn: startable,
        );
        _transferBackoff.reset();
      case SubmissionRejected(code: 'source_changed' || 'source_unavailable'):
        // Local and final for this operation; only a reselect resends.
        final changed = outcome.code == 'source_changed';
        await _intents.update(
          token,
          [intent.itemUuid],
          lastState: Value(
            changed
                ? UploadIntentState.sourceChanged
                : UploadIntentState.needsReselect,
          ),
          lastErrorCode: Value(outcome.code),
          onlyIfStateIn: startable,
        );
      case SubmissionRejected(:final code):
        UploadItem? item = fetched;
        if (item == null) {
          try {
            item = await _api.getItem(
              intent.itemUuid,
              abortTrigger: _closing.future,
            );
          } on ApiException {
            item = null; // a failed lookup still ends the item: no loop
          } on NetworkException {
            item = null;
          } on TimeoutException {
            item = null;
          }
        }
        // A refusal that leaves the item dispatchable ends in a local
        // failure; the same item is never sent again.
        final dispatchable =
            item == null ||
            awaitingOrReceivingBytesStates.contains(item.rawState);
        await _intents.update(
          token,
          [intent.itemUuid],
          lastState: Value(
            dispatchable ? ServerItemState.failed : item.rawState,
          ),
          lastErrorCode: Value(item?.error?.code ?? code),
          onlyIfStateIn: startable,
        );
      case SubmissionAmbiguous(:final cause):
        if (isUnauthorized(cause)) {
          _authParked = true; // a wait for auth, never a failure
          return;
        }
        // The server leaves the item `allocated` after these answers.
        if (cause is ApiException &&
            cause.errorCode != 'upload_transfer_in_progress' &&
            (cause.retryable == true ||
                cause.statusCode >= 500 ||
                cause.statusCode == 408)) {
          await _intents.update(
            token,
            [intent.itemUuid],
            lastState: const Value(UploadIntentState.allocated),
            lastErrorCode: Value(cause.errorCode),
            onlyIfStateIn: startable,
          );
        } else if (cause is NetworkException ||
            (cause is UploadTransferAborted &&
                _stalled.contains(intent.itemUuid))) {
          // A cut or stalled send: no byte moves while the backoff runs, so
          // a row that was sending says it was interrupted (the next send
          // asks the status first, under the same operation id).
          await _intents.update(
            token,
            [intent.itemUuid],
            lastState: const Value(UploadIntentState.allocated),
            lastErrorCode: const Value('upload_interrupted'),
            onlyIfStateIn: const {UploadIntentState.transferring},
          );
        }
        final delay = _transferBackoff.nextDelay(
          reason: BackoffReason.transient,
          retryAfter: cause is ApiException ? cause.retryAfter : null,
        );
        _notBefore = _clock.nowUtcMs() + delay.inMilliseconds;
      case SubmissionFenced():
        break;
    }
  }

  /// Opens the item's source and checks its length. Throws
  /// [UploadSourceUnavailable] (also for a lost descriptor) or
  /// [UploadSourceChanged].
  Future<FileUploadSource> _openChecked(UploadIntentRecord intent) async {
    final descriptor = intent.descriptor;
    if (descriptor == null) throw const UploadSourceUnavailable();
    final source = await _openSource(
      descriptor.path,
      displayName: intent.displayName,
    );
    if (source.length != descriptor.length) {
      throw const UploadSourceChanged(SourceChange.length);
    }
    return source;
  }

  SubmissionFailureDisposition _instanceChangedDuringTransfer() {
    _onInstanceChanged();
    return const LeaveSubmissionUntouched();
  }

  Future<SubmissionOutcome> _allocate(
    String token,
    String batchUuid,
    List<UploadIntentRecord> items,
  ) async {
    final sorted = [...items]
      ..sort((a, b) => a.selectionIndex.compareTo(b.selectionIndex));
    final request = AllocationRequest(
      batchUuid: batchUuid,
      items: [
        for (final i in sorted)
          AllocationItem(
            itemUuid: i.itemUuid,
            filename: i.displayName,
            byteLength: i.descriptor!.length,
            sha256: i.descriptor!.sha256,
          ),
      ],
    );
    // Idempotent for the same body: covers a kill between the intent insert
    // and the prepare.
    await _submissions.prepare(
      kind: 'upload_allocation',
      operationUuid: batchUuid,
      frozenBodyJson: request.toFrozenJson(),
      bindingToken: token,
    );
    return _submissions.submit(
      batchUuid,
      send: (r) async {
        final result = await _api.allocate(
          r.frozenBodyJson!,
          abortTrigger: Future.any([r.abortSignal, _closing.future]),
        );
        return {'batch_uuid': result.batch.batchUuid};
      },
      status: (_) async {
        try {
          final batch = await _api.getBatch(
            batchUuid,
            abortTrigger: _closing.future,
          );
          return StatusAccepted({'batch_uuid': batch.batchUuid});
        } on ApiException catch (e) {
          if (e.statusCode == 404) return const StatusAbsent();
          rethrow;
        }
      },
      // The rows stay as they were when the server instance changed.
      onFailure: _commonFailure,
    );
  }

  Future<void> _setItems(
    String token,
    List<UploadIntentRecord> items,
    String state,
    String? errorCode, {
    Set<String>? onlyIfStateIn,
  }) => _intents.update(
    token,
    [for (final i in items) i.itemUuid],
    lastState: Value(state),
    lastErrorCode: Value(errorCode),
    onlyIfStateIn: onlyIfStateIn,
  );
}

/// A status-first answer that settles the transfer without sending bytes;
/// the failure hook turns it into [disposition].
class _TransferStop implements Exception {
  const _TransferStop(this.disposition);
  final SubmissionFailureDisposition disposition;
}

sealed class _StepResult {
  const _StepResult();
}

final class _StepDone extends _StepResult {
  const _StepDone();
}

/// A step failed transiently: the pass ends in a retry.
final class _StepRetry extends _StepResult {
  const _StepRetry();
}

final class _StepParked extends _StepResult {
  const _StepParked();
}

/// One manager per scope, on the scope's [DurableSubmission]; quiesced when
/// the scope is disposed and by a reset (SC-15).
final uploadManagerProvider = Provider<UploadManager>((ref) {
  final manager = UploadManager(
    api: ref.read(uploadsApiProvider),
    submissions: ref.read(durableSubmissionProvider),
    intents: ref.read(uploadIntentStoreProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    gate: ref.read(serverBindingGateProvider),
    clock: ref.read(clockProvider),
    feature: () async {
      try {
        return await ref
            .read(uploadsFeatureProvider.future)
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        return null;
      }
    },
    isOffline: () => ref.read(offlineModeProvider),
    refreshCapabilities: () async {
      if (ref.mounted) ref.invalidate(appInfoProvider);
    },
    visible: ref.read(uploadsVisibilityProvider).visible,
    review: ref.read(uploadReviewTransportProvider),
  );
  ref.onDispose(manager.quiesce);
  // The import-triggered library sync lives as long as the manager.
  ref.listen(uploadImportSyncProvider, (_, _) {});
  return manager;
});

/// The scope's upload intent store.
final uploadIntentStoreProvider = Provider<UploadIntentStore>(
  (ref) => UploadIntentStore(
    db: ref.read(databaseProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    clock: ref.read(clockProvider),
  ),
);

/// The current binding's upload intents, live (what the Uploads page shows);
/// empty without a binding.
final uploadIntentsProvider = StreamProvider<List<UploadIntentRecord>>((
  ref,
) {
  // Read while building: the stream body runs later, possibly after the
  // scope was disposed, and must not use ref then.
  final store = ref.read(uploadIntentStoreProvider);
  final binding = ref.read(serverBindingRepositoryProvider);
  return () async* {
    final token = (await binding.current())?.localBindingId;
    if (token == null) {
      yield const <UploadIntentRecord>[];
      return;
    }
    yield* store.watch(token);
  }();
});
