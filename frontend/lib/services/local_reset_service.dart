import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';

/// Coordinates a full local reset of frontend-owned state.
///
/// Keep subsystem cleanup in the subsystem itself, and add it here only as a
/// reset step. That keeps the disconnect flow from becoming a growing list of
/// implementation details spread through UI code.
class LocalResetService {
  LocalResetService(this._ref);

  final Ref _ref;

  Future<void> reset() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final downloadManager = _ref.read(downloadManagerProvider);
    final db = _ref.read(databaseProvider);
    final localCoverArtStore = _ref.read(localCoverArtStoreProvider);
    final coverArtCache = _ref.read(coverArtCacheProvider);

    await _ref.read(audioProvider.notifier).stop();
    _ref.read(offlineModeProvider.notifier).exitOffline();
    await downloadManager.resetAndDeleteFiles();
    await localCoverArtStore.clear();
    await coverArtCache.clear();
    await db.resetLocalData();
    await prefs.clear();
    ApiClient.init('');
  }
}

final localResetServiceProvider = Provider<LocalResetService>((ref) {
  return LocalResetService(ref);
});
