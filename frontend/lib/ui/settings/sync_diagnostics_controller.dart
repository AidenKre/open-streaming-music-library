import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/history_event.dart';
import 'package:frontend/services/history/history_diagnostics.dart';

/// Sync & storage diagnostics input (SC-26 controller; SC-21). Holds no
/// rules: the model's [HistoryDiagnosticsActions] does.
abstract interface class SyncDiagnosticsControls {
  Future<void> retryHistory();
  Future<void> keepServerVersion(HistoryServerEvent server);
}

final syncDiagnosticsControlsProvider = Provider<SyncDiagnosticsControls>(
  SyncDiagnosticsController.new,
);

class SyncDiagnosticsController implements SyncDiagnosticsControls {
  SyncDiagnosticsController(this._ref);

  final Ref _ref;

  HistoryDiagnosticsActions get _history =>
      _ref.read(historyDiagnosticsActionsProvider);

  @override
  Future<void> retryHistory() => _history.retry();

  @override
  Future<void> keepServerVersion(HistoryServerEvent server) =>
      _history.keepServerVersion(server);
}
