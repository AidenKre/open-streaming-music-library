import 'package:flutter/foundation.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/history_api.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/sync_service.dart'
    show ServerRegressedException;

/// What the history diagnostics row shows (SC-21), owned by the model.
@immutable
class HistorySyncStatus {
  const HistorySyncStatus({
    this.lastError,
    this.waitingForServerSupport = false,
    this.blockedConflicts = const [],
    this.serverRegressed = false,
  });

  /// The last failure's message, cleared by a successful pass.
  final String? lastError;

  /// The server doesn't advertise history sync yet (capture continues).
  final bool waitingForServerSupport;

  /// Server events whose payload differs from this device's: the pull is
  /// blocked until the user keeps the server version.
  final List<HistoryServerEvent> blockedConflicts;

  /// The server's history is behind this device's cursor (a restored
  /// backup, SC-01 rule 5).
  final bool serverRegressed;
}

/// One server-scoped history pass: upload, then pull (Phase 5 §5). The body
/// of the history [SingleFlightRunner].
///
/// Never blocks on the binding gate (it would hold a quiesce): without a
/// verified connection the pass fails with the offline wait and the next
/// connection edge requests it again. Upload failures don't stop the pull;
/// a 409 or 413/422 quarantines the affected events (retained, never
/// rewritten) and the healthy ones continue. A fenced write (a reset) ends
/// the pass quietly.
class HistorySyncService {
  HistorySyncService({
    required HistoryRepository repository,
    required HistoryApi api,
    required SyncCursorStore cursors,
    required String? Function() verifiedToken,
    required bool Function() isOffline,
    required Future<bool?> Function() supportsHistory,
    this.maxBatchesPerPass = 10,
    this.maxPagesPerPass = 10,
    this.pageSize = 200,
  }) : _repository = repository,
       _api = api,
       _cursors = cursors,
       _verifiedToken = verifiedToken,
       _isOffline = isOffline,
       _supportsHistory = supportsHistory;

  final HistoryRepository _repository;
  final HistoryApi _api;
  final SyncCursorStore _cursors;
  final String? Function() _verifiedToken;
  final bool Function() _isOffline;
  final Future<bool?> Function() _supportsHistory;

  final int maxBatchesPerPass;
  final int maxPagesPerPass;
  final int pageSize;

  final _status = ValueNotifier(const HistorySyncStatus());

  ValueListenable<HistorySyncStatus> get status => _status;

  void _update({
    Object? lastError = _keep,
    bool? waitingForServerSupport,
    List<HistoryServerEvent>? blockedConflicts,
    bool? serverRegressed,
  }) {
    final s = _status.value;
    _status.value = HistorySyncStatus(
      lastError: identical(lastError, _keep)
          ? s.lastError
          : lastError as String?,
      waitingForServerSupport:
          waitingForServerSupport ?? s.waitingForServerSupport,
      blockedConflicts: blockedConflicts ?? s.blockedConflicts,
      serverRegressed: serverRegressed ?? s.serverRegressed,
    );
  }

  static const _keep = Object();

  /// This pass quarantined events (a 409 or 413/422): not a clean pass.
  bool _quarantinedThisPass = false;

  Future<PassOutcome> runPass(Set<String> reasons) async {
    if (_isOffline()) return const PassFailed(BackoffReason.offline);
    final token = _verifiedToken();
    if (token == null) return const PassFailed(BackoffReason.offline);
    final supported = await _supportsHistory();
    if (!_canRequest(token)) return const PassFailed(BackoffReason.offline);
    if (supported == null) {
      _update(waitingForServerSupport: false);
      return const PassFailed(BackoffReason.transient);
    }
    if (!supported) return _capabilityMissing();
    if (_status.value.waitingForServerSupport) {
      _update(waitingForServerSupport: false);
    }

    _quarantinedThisPass = false;
    try {
      final upload = await _upload(token);
      if (upload is PassFailed &&
          upload.reason == BackoffReason.capabilityMissing) {
        return upload;
      }
      final pull = await _pull(token);
      if (pull is PassFailed) return pull;
      if (_status.value.blockedConflicts.isNotEmpty ||
          _status.value.serverRegressed) {
        return const PassDone();
      }
      if (upload is PassFailed) return upload;
      // Clean: clear the last error, unless this pass quarantined events
      // (they stay visible in diagnostics until resolved).
      if (!_quarantinedThisPass) _update(lastError: null);
      if (upload is PassMoreWork || pull is PassMoreWork) {
        return const PassMoreWork();
      }
      return const PassDone();
    } on BindingFencedException {
      // A reset fenced this session's store: nothing left to sync.
      return const PassDone();
    }
  }

  PassFailed _capabilityMissing() {
    _update(waitingForServerSupport: true);
    return const PassFailed(BackoffReason.capabilityMissing);
  }

  bool _canRequest(String token) =>
      !_isOffline() && _verifiedToken() == token;

  /// Up to [maxBatchesPerPass] batches. [PassDone] when nothing is left,
  /// [PassMoreWork] when the budget ran out, [PassFailed] when uploading
  /// stopped (the pull still runs, except for a missing endpoint).
  Future<PassOutcome> _upload(String token) async {
    for (var i = 0; i < maxBatchesPerPass; i++) {
      final batch = await _repository.nextUploadBatch(token);
      if (batch == null) return const PassDone();
      if (!_canRequest(token)) return const PassFailed(BackoffReason.offline);
      try {
        final ack = await _api.post(batch);
        await _repository.applyAck(token, batch.eventUuids, ack);
        if (ack is List && ack.length < batch.events.length) {
          // Unacknowledged events stay pending; don't resend them in a loop.
          _update(
            lastError:
                'The server acknowledged ${ack.length} of '
                '${batch.events.length} history events',
          );
          return const PassFailed(BackoffReason.transient);
        }
      } on ApiException catch (e) {
        _update(lastError: e.detailMessage ?? e.toString());
        switch (e.statusCode) {
          case 409:
            final conflicting = e.details?['conflicting_event_uuids'];
            final ids = conflicting is List
                ? batch.eventUuids.where(conflicting.contains).toList()
                : <String>[];
            if (ids.isEmpty) {
              _update(lastError: 'Invalid history conflict response: no submitted UUIDs');
              return const PassFailed(BackoffReason.transient);
            }
            await _quarantine(token, ids, 'conflict', e.detailMessage);
          case 413:
            await _quarantine(token, batch.eventUuids, 'rejected', e.detailMessage);
          case 422:
            final indices = <int>{};
            for (final error in e.validationErrors ?? const []) {
              final loc = error is Map ? error['loc'] : null;
              if (loc is List && loc.length >= 3 &&
                  loc[0] == 'body' && loc[1] == 'events' &&
                  loc[2] is int && loc[2] >= 0 && loc[2] < batch.events.length) {
                indices.add(loc[2] as int);
              }
            }
            final ids = indices.isEmpty ? batch.eventUuids : [
              for (final index in indices) batch.events[index].eventUuid,
            ];
            await _quarantine(token, ids, 'rejected', e.detailMessage);
          case 404:
            return _capabilityMissing();
          default:
            return const PassFailed(BackoffReason.transient);
        }
      } on HistoryProtocolException catch (e) {
        _update(lastError: e.message);
        return const PassFailed(BackoffReason.transient);
      } on NetworkException catch (e) {
        _update(lastError: e.toString());
        return const PassFailed(BackoffReason.transient);
      }
    }
    return const PassMoreWork();
  }

  Future<void> _quarantine(
    String token,
    List<String> uuids,
    String reason,
    String? detail,
  ) async {
    _quarantinedThisPass = true;
    for (final uuid in uuids) {
      await _repository.recordFailure(
        token,
        uuid,
        reason: reason,
        detail: detail,
      );
    }
  }

  /// Up to [maxPagesPerPass] pages from the `history` cursor.
  Future<PassOutcome> _pull(String token) async {
    try {
      for (var i = 0; i < maxPagesPerPass; i++) {
        final after = await _cursors.read(SyncStream.history);
        if (!_canRequest(token)) return const PassFailed(BackoffReason.offline);
        final page = await _api.changes(after: after, limit: pageSize);
        await _repository.applyPage(token, requestedAfter: after, page: page);
        if (page.nextCursor == null) {
          _update(blockedConflicts: const [], serverRegressed: false);
          return const PassDone();
        }
      }
      return const PassMoreWork();
    } on HistoryPayloadConflict catch (e) {
      _update(lastError: e.toString(), blockedConflicts: e.events);
      return const PassDone();
    } on ServerRegressedException catch (e) {
      _update(lastError: e.toString(), serverRegressed: true);
      return const PassDone();
    } on FormatException catch (e) {
      _update(lastError: e.message);
      return const PassFailed(BackoffReason.transient);
    } on HistoryProtocolException catch (e) {
      _update(lastError: e.message);
      return const PassFailed(BackoffReason.transient);
    } on ApiException catch (e) {
      _update(lastError: e.detailMessage ?? e.toString());
      return const PassFailed(BackoffReason.transient);
    } on NetworkException catch (e) {
      _update(lastError: e.toString());
      return const PassFailed(BackoffReason.transient);
    }
  }
}
