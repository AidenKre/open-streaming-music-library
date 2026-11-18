import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Constant, OrderingTerm, Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/local_resettable.dart';

/// SC-14 submission states: `prepared → sent → accepted | rejected |
/// ambiguous`.
enum SubmissionState { prepared, sent, accepted, rejected, ambiguous }

/// One persisted submission (a `durable_submissions` row).
class SubmissionRecord {
  const SubmissionRecord({
    required this.operationUuid,
    required this.kind,
    required this.localBindingId,
    required this.frozenBodyJson,
    required this.state,
    required this.receiptJson,
    required this.errorCode,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String operationUuid;
  final String kind;
  final String localBindingId;
  final String? frozenBodyJson;
  final SubmissionState state;
  final String? receiptJson;
  final String? errorCode;
  final int createdAtMs;
  final int updatedAtMs;
}

/// [DurableSubmission.prepare] was called again for a stored operation with
/// a different kind or body. The stored (frozen) body is never replaced.
class SubmissionConflict implements Exception {
  SubmissionConflict(this.operationUuid);
  final String operationUuid;

  @override
  String toString() => 'SubmissionConflict($operationUuid)';
}

/// [DurableSubmission.submit] after [DurableSubmission.quiesce].
class SubmissionClosed implements Exception {
  @override
  String toString() => 'SubmissionClosed';
}

/// What the server knows about an operation (the status GET).
sealed class SubmissionStatus {
  const SubmissionStatus();
}

/// The server holds a receipt: the operation was accepted.
final class StatusAccepted extends SubmissionStatus {
  const StatusAccepted(this.receipt);
  final Map<String, dynamic> receipt;
}

/// The server rejected the operation for good.
final class StatusRejected extends SubmissionStatus {
  const StatusRejected(this.code);
  final String code;
}

/// The server has no record of the operation: it never arrived, so the
/// same frozen request may be sent again. Callers return this only for a
/// definite "never saw it" answer, never for a failed lookup.
final class StatusAbsent extends SubmissionStatus {
  const StatusAbsent();
}

/// The server has the operation but it has not settled yet (still receiving
/// or committing): neither resend nor resolve; the operation stays ambiguous.
final class StatusPending extends SubmissionStatus {
  const StatusPending();
}

/// The result of [DurableSubmission.submit].
sealed class SubmissionOutcome {
  const SubmissionOutcome();
}

final class SubmissionAccepted extends SubmissionOutcome {
  const SubmissionAccepted(this.receipt);
  final Map<String, dynamic> receipt;
}

final class SubmissionRejected extends SubmissionOutcome {
  const SubmissionRejected(this.code);
  final String code;
}

/// The request may or may not have reached the server; the next submit
/// asks for its status before sending again.
final class SubmissionAmbiguous extends SubmissionOutcome {
  const SubmissionAmbiguous(this.cause);
  final Object cause;
}

/// The binding the operation was created under is gone (reset, logout,
/// user switch, another server): nothing was sent or recorded.
final class SubmissionFenced extends SubmissionOutcome {
  const SubmissionFenced();
}

/// What a send callback gets: the frozen body exactly as stored, and a
/// signal that completes when the helper is quiesced (abort the request).
class SubmissionRequest {
  const SubmissionRequest({
    required this.operationUuid,
    required this.frozenBodyJson,
    required this.abortSignal,
  });

  final String operationUuid;
  final String? frozenBodyJson;
  final Future<void> abortSignal;
}

/// What a caller's [SubmissionFailureHook] wants done with a failed send or
/// status query.
sealed class SubmissionFailureDisposition {
  const SubmissionFailureDisposition();
}

/// The row ends exactly as it was before the `submit` call, and the original
/// error is rethrown.
final class LeaveSubmissionUntouched extends SubmissionFailureDisposition {
  const LeaveSubmissionUntouched();
}

/// The row becomes `rejected` with [code]; the outcome is
/// [SubmissionRejected].
final class SubmissionTerminal extends SubmissionFailureDisposition {
  const SubmissionTerminal(this.code);
  final String code;
}

/// The row becomes `ambiguous` with [code]; the outcome is
/// [SubmissionAmbiguous].
final class SubmissionAmbiguousAs extends SubmissionFailureDisposition {
  const SubmissionAmbiguousAs(this.code);
  final String code;
}

/// Asked first about every failure of a send or status query. Null falls
/// through to the built-in classification.
typedef SubmissionFailureHook =
    SubmissionFailureDisposition? Function(Object error);

typedef SubmissionSend =
    Future<Map<String, dynamic>> Function(SubmissionRequest request);

/// Asks the server what it knows about an operation. The caller maps "the
/// server never saw this operation" (e.g. a 404 receipt lookup) to
/// [StatusAbsent]; a thrown error keeps the operation ambiguous and unsent.
typedef SubmissionStatusQuery =
    Future<SubmissionStatus> Function(String operationUuid);

class DurableSubmission implements Quiescable {
  DurableSubmission({
    required AppDatabase db,
    required ServerBindingRepository binding,
    required Clock clock,
  }) : _db = db,
       _binding = binding,
       _clock = clock;

  final AppDatabase _db;
  final ServerBindingRepository _binding;
  final Clock _clock;

  static SubmissionRecord _toRecord(DurableSubmissionRow r) => SubmissionRecord(
    operationUuid: r.operationUuid,
    kind: r.kind,
    localBindingId: r.localBindingId,
    frozenBodyJson: r.frozenBodyJson,
    state: SubmissionState.values.byName(r.state),
    receiptJson: r.receiptJson,
    errorCode: r.errorCode,
    createdAtMs: r.createdAt,
    updatedAtMs: r.updatedAt,
  );

  Future<DurableSubmissionRow?> _row(String operationUuid) => (_db.select(
    _db.durableSubmissions,
  )..where((t) => t.operationUuid.equals(operationUuid))).getSingleOrNull();

  /// Persists a `prepared` row before anything is sent. Idempotent for the
  /// same kind and body; a different kind or body throws
  /// [SubmissionConflict] and never replaces the stored row.
  Future<SubmissionRecord> prepare({
    required String kind,
    required String operationUuid,
    required String? frozenBodyJson,
    required String bindingToken,
  }) {
    if (_closed) return Future.error(SubmissionClosed());
    return _binding.runFenced(bindingToken, () async {
      final existing = await _row(operationUuid);
      if (existing != null) {
        if (existing.localBindingId == bindingToken &&
            existing.kind == kind &&
            existing.frozenBodyJson == frozenBodyJson) {
          return _toRecord(existing);
        }
        throw SubmissionConflict(operationUuid);
      }
      final now = _clock.nowUtcMs();
      await _db
          .into(_db.durableSubmissions)
          .insert(
            DurableSubmissionsCompanion.insert(
              operationUuid: operationUuid,
              kind: kind,
              localBindingId: bindingToken,
              frozenBodyJson: Value(frozenBodyJson),
              state: SubmissionState.prepared.name,
              createdAt: now,
              updatedAt: now,
            ),
          );
      return _toRecord((await _row(operationUuid))!);
    });
  }

  Future<SubmissionRecord?> find(String operationUuid) async {
    final row = await _row(operationUuid);
    return row == null ? null : _toRecord(row);
  }

  final Map<String, Future<SubmissionOutcome>> _inFlight = {};
  final Completer<void> _abort = Completer<void>();
  bool _closed = false;

  /// Sends the stored frozen request, recovering status-first when an earlier
  /// attempt may have reached the server (`sent` or `ambiguous`).
  ///
  /// A submit of an operation already in flight returns that same future (no
  /// second send or status query). A binding change (SC-01 fence) before or
  /// during the call yields [SubmissionFenced] and leaves the row untouched.
  Future<SubmissionOutcome> submit(
    String operationUuid, {
    required SubmissionSend send,
    required SubmissionStatusQuery status,
    SubmissionFailureHook? onFailure,
  }) {
    if (_closed) return Future.error(SubmissionClosed());
    final running = _inFlight[operationUuid];
    if (running != null) return running;
    final future = _submitFenced(
      operationUuid,
      send: send,
      status: status,
      onFailure: onFailure,
    );
    _inFlight[operationUuid] = future;
    // Block bodies: `remove` returns the (possibly failed) future itself,
    // which the derived future would adopt as an unhandled error.
    future.then<void>(
      (_) {
        _inFlight.remove(operationUuid);
      },
      onError: (Object _) {
        _inFlight.remove(operationUuid);
      },
    );
    return future;
  }

  Future<SubmissionOutcome> _submitFenced(
    String operationUuid, {
    required SubmissionSend send,
    required SubmissionStatusQuery status,
    SubmissionFailureHook? onFailure,
  }) async {
    try {
      return await _submit(
        operationUuid,
        send: send,
        status: status,
        onFailure: onFailure,
      );
    } on BindingFencedException {
      return const SubmissionFenced();
    }
  }

  Future<SubmissionOutcome> _submit(
    String operationUuid, {
    required SubmissionSend send,
    required SubmissionStatusQuery status,
    SubmissionFailureHook? onFailure,
  }) async {
    final row = await _row(operationUuid);
    if (row == null) throw StateError('No submission $operationUuid');
    final state = SubmissionState.values.byName(row.state);

    switch (state) {
      case SubmissionState.accepted:
        return SubmissionAccepted(
          jsonDecode(row.receiptJson!) as Map<String, dynamic>,
        );
      case SubmissionState.rejected:
        return SubmissionRejected(row.errorCode ?? 'rejected');
      case SubmissionState.sent || SubmissionState.ambiguous:
        final resolved = await _resolveByStatus(row, status, onFailure);
        if (resolved != null) return resolved;
      case SubmissionState.prepared:
        break;
    }

    // Quiesce may have started while this submit was reading or querying:
    // only new sends are refused; the row stays as it is.
    if (_closed) throw SubmissionClosed();
    await _write(row, state: SubmissionState.sent);
    Map<String, dynamic>? receipt;
    Object? failure;
    StackTrace? failureTrace;
    try {
      receipt = await send(
        SubmissionRequest(
          operationUuid: operationUuid,
          frozenBodyJson: row.frozenBodyJson,
          abortSignal: _abort.future,
        ),
      );
    } catch (e, st) {
      failure = e;
      failureTrace = st;
    }
    if (failure != null) {
      return _settleFailure(
        row,
        failure,
        failureTrace!,
        onFailure,
        canReject: true,
        restoreRow: true,
      );
    }
    await _write(row, state: SubmissionState.accepted, receipt: receipt);
    return SubmissionAccepted(receipt!);
  }

  /// Asks the server what it knows. Returns the final outcome, or null when
  /// the server never saw the operation (the caller sends it again).
  Future<SubmissionOutcome?> _resolveByStatus(
    DurableSubmissionRow row,
    SubmissionStatusQuery status,
    SubmissionFailureHook? onFailure,
  ) async {
    // The status GET would go out under the current session: check the
    // row's binding first (throws BindingFencedException when it is gone).
    await _binding.runFenced(row.localBindingId, () async {});
    SubmissionStatus? answer;
    Object? failure;
    StackTrace? failureTrace;
    try {
      answer = await status(row.operationUuid);
    } catch (e, st) {
      failure = e;
      failureTrace = st;
    }
    if (failure != null) {
      // A failed status query never proves a rejection.
      return _settleFailure(
        row,
        failure,
        failureTrace!,
        onFailure,
        canReject: false,
      );
    }
    switch (answer!) {
      case StatusAccepted(:final receipt):
        await _write(row, state: SubmissionState.accepted, receipt: receipt);
        return SubmissionAccepted(receipt);
      case StatusRejected(:final code):
        await _write(row, state: SubmissionState.rejected, errorCode: code);
        return SubmissionRejected(code);
      case StatusAbsent():
        return null;
      case StatusPending():
        return const SubmissionAmbiguous(StatusPending());
    }
  }

  /// Records a failed send or status query. The caller's [onFailure] hook is
  /// asked first; otherwise an unclassified error is written as ambiguous
  /// 'unexpected' and rethrown. [restoreRow] is true when the send path had
  /// already written `sent`, which [LeaveSubmissionUntouched] puts back.
  Future<SubmissionOutcome> _settleFailure(
    DurableSubmissionRow row,
    Object error,
    StackTrace trace,
    SubmissionFailureHook? onFailure, {
    required bool canReject,
    bool restoreRow = false,
  }) async {
    switch (onFailure?.call(error)) {
      case LeaveSubmissionUntouched():
        if (restoreRow) {
          await _binding.runFenced(row.localBindingId, () async {
            await (_db.update(_db.durableSubmissions)
                  ..where((t) => t.operationUuid.equals(row.operationUuid)))
                .write(
                  DurableSubmissionsCompanion(
                    state: Value(row.state),
                    errorCode: Value(row.errorCode),
                    receiptJson: Value(row.receiptJson),
                    updatedAt: Value(row.updatedAt),
                  ),
                );
          });
        }
        Error.throwWithStackTrace(error, trace);
      case SubmissionTerminal(:final code):
        await _write(row, state: SubmissionState.rejected, errorCode: code);
        return SubmissionRejected(code);
      case SubmissionAmbiguousAs(:final code):
        await _write(row, state: SubmissionState.ambiguous, errorCode: code);
        return SubmissionAmbiguous(error);
      case null:
        break;
    }
    final classified = _classify(error);
    if (classified == null) {
      await _write(
        row,
        state: SubmissionState.ambiguous,
        errorCode: 'unexpected',
      );
      Error.throwWithStackTrace(error, trace);
    }
    final (state, code) = classified;
    if (state == SubmissionState.rejected && canReject) {
      await _write(row, state: state, errorCode: code);
      return SubmissionRejected(code);
    }
    await _write(row, state: SubmissionState.ambiguous, errorCode: code);
    return SubmissionAmbiguous(error);
  }

  /// `(rejected | ambiguous, code)` for transport and API errors; null for
  /// anything else. Only the code is kept, never the exception message.
  static (SubmissionState, String)? _classify(Object error) {
    if (error is ApiException) {
      final code = error.errorCode ?? 'http_${error.statusCode}';
      return (
        error.isDefinitiveRefusal
            ? SubmissionState.rejected
            : SubmissionState.ambiguous,
        code,
      );
    }
    if (error is NetworkException || error is TimeoutException) {
      return (SubmissionState.ambiguous, 'network');
    }
    return null;
  }

  /// One fenced transition. Receipt and error code are replaced, so an
  /// accepted row ends with a NULL error code.
  Future<void> _write(
    DurableSubmissionRow row, {
    required SubmissionState state,
    Map<String, dynamic>? receipt,
    String? errorCode,
  }) => _binding.runFenced(row.localBindingId, () async {
    await (_db.update(
      _db.durableSubmissions,
    )..where((t) => t.operationUuid.equals(row.operationUuid))).write(
      DurableSubmissionsCompanion(
        state: Value(state.name),
        receiptJson: receipt == null
            ? const Value.absent()
            : Value(jsonEncode(receipt)),
        errorCode: Value(errorCode),
        updatedAt: Value(_clock.nowUtcMs()),
      ),
    );
  });

  /// Rows of [bindingToken] that are not yet accepted or rejected, oldest
  /// first. Read-only.
  Future<List<SubmissionRecord>> unresolved({
    required String bindingToken,
    String? kind,
  }) async {
    final query = _db.select(_db.durableSubmissions)
      ..where(
        (t) =>
            t.localBindingId.equals(bindingToken) &
            t.state.isIn([
              SubmissionState.prepared.name,
              SubmissionState.sent.name,
              SubmissionState.ambiguous.name,
            ]) &
            (kind == null ? const Constant(true) : t.kind.equals(kind)),
      )
      ..orderBy([
        (t) => OrderingTerm.asc(t.createdAt),
        (t) => OrderingTerm.asc(t.operationUuid),
      ]);
    return [for (final r in await query.get()) _toRecord(r)];
  }

  /// Unanswered rows of every binding, for counting what a log-out kept.
  /// Read-only.
  Future<List<SubmissionRecord>> unresolvedAll({String? kind}) async {
    final query = _db.select(_db.durableSubmissions)
      ..where(
        (t) =>
            t.state.isIn([
              SubmissionState.prepared.name,
              SubmissionState.sent.name,
              SubmissionState.ambiguous.name,
            ]) &
            (kind == null ? const Constant(true) : t.kind.equals(kind)),
      );
    return [for (final r in await query.get()) _toRecord(r)];
  }

  @override
  String get quiesceName => 'submissions';

  /// SC-15: closes admission, aborts every send in flight and waits for the
  /// submits to settle. Idempotent.
  @override
  Future<void> quiesce() async {
    _closed = true;
    if (!_abort.isCompleted) _abort.complete();
    for (final running in _inFlight.values.toList()) {
      try {
        await running;
      } catch (_) {}
    }
  }
}

/// The submission helper for this scope. Quiesced when the scope is
/// disposed and by a reset (SC-15).
final durableSubmissionProvider = Provider<DurableSubmission>((ref) {
  final submission = DurableSubmission(
    db: ref.read(databaseProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    clock: ref.read(clockProvider),
  );
  ref.onDispose(submission.quiesce);
  return submission;
});
