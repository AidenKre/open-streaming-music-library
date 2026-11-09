import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/providers/providers.dart';

/// One blocked conflict: this device's payload and the server's (Phase 5
/// §4 "Keep server version" shows both).
typedef HistoryConflictPair = ({
  HistoryEventPayload local,
  HistoryServerEvent server,
});

/// What the history diagnostics row and page show (SC-21). Model state.
@immutable
class HistoryDiagnostics {
  const HistoryDiagnostics({
    this.pending = 0,
    this.quarantined = 0,
    this.lastError,
    this.waitingForServerSupport = false,
    this.serverRegressed = false,
    this.conflicts = const [],
    this.frozenListens = 0,
    this.listenError,
  });

  /// Unsent events still eligible for upload.
  final int pending;

  /// Unsent events held back by a failure record (conflict, rejected,
  /// oversized).
  final int quarantined;
  final String? lastError;
  final bool waitingForServerSupport;
  final bool serverRegressed;
  final List<HistoryConflictPair> conflicts;

  /// Listens whose finalization failed, kept with their final payload and
  /// retried (Phase 5 §7).
  final int frozenListens;

  /// The last listen recording failure this run (§7 "visible error").
  final String? listenError;
}

/// The live history diagnostics: the store's counts plus the sync status,
/// with each blocked conflict paired with this device's payload. Emits
/// whenever either changes.
final historyDiagnosticsProvider = StreamProvider<HistoryDiagnostics>((ref) {
  final repository = ref.read(historyRepositoryProvider);
  final status = ref.read(historySyncServiceProvider).status;
  final listenError = ref.read(listenRecordingErrorProvider);
  var frozenListens = 0;
  final controller = StreamController<HistoryDiagnostics>();
  HistorySyncCounts? counts;
  var closed = false;
  var publishSequence = 0;

  Future<void> publish() async {
    final sequence = ++publishSequence;
    final c = counts;
    if (c == null) return;
    final s = status.value;
    final conflicts = <HistoryConflictPair>[];
    for (final server in s.blockedConflicts) {
      final local = await repository.localPayload(server.payload.eventUuid);
      if (local != null) conflicts.add((local: local, server: server));
    }
    if (closed || sequence != publishSequence) return;
    controller.add(
      HistoryDiagnostics(
        pending: c.pending,
        quarantined: c.quarantined,
        lastError: s.lastError,
        waitingForServerSupport: s.waitingForServerSupport,
        serverRegressed: s.serverRegressed,
        conflicts: conflicts,
        frozenListens: frozenListens,
        listenError: listenError.value,
      ),
    );
  }

  void onStatus() => unawaited(publish());
  status.addListener(onStatus);
  listenError.addListener(onStatus);
  final frozenSub = repository.watchFrozenListenCount().listen((n) {
    frozenListens = n;
    unawaited(publish());
  }, onError: controller.addError);
  final countsSub = repository.watchCounts().listen((c) {
    counts = c;
    unawaited(publish());
  }, onError: controller.addError);
  ref.onDispose(() {
    closed = true;
    status.removeListener(onStatus);
    listenError.removeListener(onStatus);
    unawaited(frozenSub.cancel());
    unawaited(countsSub.cancel());
    unawaited(controller.close());
  });
  return controller.stream;
});

/// The history diagnostics actions (the rules).
class HistoryDiagnosticsActions {
  HistoryDiagnosticsActions(this._ref);

  final Ref _ref;

  /// The current binding token, captured when a user action starts (like
  /// the edit outbox's user writes); null without a binding row (no
  /// session, or a reset started), and then the action does nothing. The
  /// requested pass itself still waits for a verified connection.
  Future<String?> _token() async =>
      (await _ref.read(serverBindingRepositoryProvider).current())
          ?.localBindingId;

  /// Retry now: clears the rejected/oversized quarantine (conflicts stay —
  /// only "Keep server version" resolves them) and requests a pass that
  /// bypasses the backoff.
  Future<void> retry() async {
    final token = await _token();
    if (token == null) return;
    await _ref.read(historyRepositoryProvider).clearRetryableFailures(token);
    _ref.read(historyRunnerProvider).request('retry', bypassBackoff: true);
  }

  /// Resolve one conflict with the server's payload, then sync on.
  Future<void> keepServerVersion(HistoryServerEvent server) async {
    final token = await _token();
    if (token == null) return;
    await _ref.read(historyRepositoryProvider).keepServerVersion(token, server);
    _ref
        .read(historyRunnerProvider)
        .request('keepServerVersion', bypassBackoff: true);
  }
}

final historyDiagnosticsActionsProvider = Provider<HistoryDiagnosticsActions>(
  HistoryDiagnosticsActions.new,
);
