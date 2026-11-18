import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/history_api.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/history/history_sync_service.dart';
import 'package:frontend/services/history/history_sync_triggers.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// The last listen recording failure of this scope (Phase 5 §7 "visible
/// error"), written by the ListenRecorder's error sink, shown by the
/// history diagnostics.
final listenRecordingErrorProvider = Provider<ValueNotifier<String?>>((ref) {
  final error = ValueNotifier<String?>(null);
  ref.onDispose(error.dispose);
  return error;
});

/// The scope's history store.
final Provider<HistoryRepository> historyRepositoryProvider = Provider<HistoryRepository>(
  (ref) => HistoryRepository(
    ref.read(databaseProvider),
    binding: ref.read(serverBindingRepositoryProvider),
    onLocalInsert: () {
      if (ref.mounted) ref.read(historySyncTriggersProvider).localInsert();
    },
  ),
);

/// History uploads and pulls go through the bound client: a response from
/// another server instance is never applied (SC-01 rule 6).
final historyApiProvider = Provider<HistoryApi>(
  (ref) => HistoryApi(api: ref.read(boundApiClientProvider)),
);

/// The history pass, wired to the binding gate (verified token), offline
/// mode and the `history` capability.
final historySyncServiceProvider = Provider<HistorySyncService>((ref) {
  final gate = ref.read(serverBindingGateProvider);
  return HistorySyncService(
    repository: ref.read(historyRepositoryProvider),
    api: ref.read(historyApiProvider),
    cursors: SyncCursorStore(ref.read(databaseProvider)),
    verifiedToken: () => switch (gate.state) {
      BindingVerified(:final token) => token,
      _ => null,
    },
    verifiedConnection: () => gate.verifiedConnection,
    onServerInstanceChanged: (e, connection) {
      // The gate drops the report unless that connection is still the
      // verified one.
      if (connection != null) gate.reportDifferentInstance(connection, e);
    },
    isOffline: () => ref.read(offlineModeProvider),
    supportsHistory: () async {
      try {
        // Not requiring !fromCache: the pass already needs a verified token
        // (read live from /app/info on this connection) and being online.
        return (await ref.read(historyFeatureProvider.future)
            .timeout(const Duration(seconds: 10))) != null;
      } catch (_) {
        return null;
      }
    },
    // A fresh /app/info read (the capability recheck while waiting).
    refreshCapabilities: () async {
      if (ref.mounted) ref.invalidate(appInfoProvider);
    },
  );
});

/// The history SingleFlightRunner (SC-13), quiesced with the scope.
final historyRunnerProvider = Provider<SingleFlightRunner>((ref) {
  final runner = SingleFlightRunner(
    name: 'history',
    pass: ref.read(historySyncServiceProvider).runPass,
    backoff: BackoffSchedule(),
  );
  ref.onDispose(runner.quiesce);
  return runner;
});

/// Debounce + foreground poll, following offline mode.
final historySyncTriggersProvider = Provider<HistorySyncTriggers>((ref) {
  final runner = ref.read(historyRunnerProvider);
  final triggers = HistorySyncTriggers(request: (r) => runner.request(r));
  triggers.setOnline(!ref.read(offlineModeProvider));
  ref.listen<bool>(
    offlineModeProvider,
    (_, offline) => triggers.setOnline(!offline),
  );
  ref.onDispose(triggers.dispose);
  return triggers;
});
