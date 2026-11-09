import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/history_api.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/history/history_sync_service.dart';
import 'package:frontend/services/history/history_sync_triggers.dart';
import 'package:frontend/services/server_binding_gate.dart';

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

final historyApiProvider = Provider<HistoryApi>((ref) => HistoryApi());

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
    isOffline: () => ref.read(offlineModeProvider),
    supportsHistory: () async {
      try {
        return (await ref.read(appInfoProvider.future)
            .timeout(const Duration(seconds: 10))).supportsHistory;
      } catch (_) {
        return null;
      }
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
