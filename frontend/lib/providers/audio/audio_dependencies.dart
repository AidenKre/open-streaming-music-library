import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/concatenating_player_controller.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/providers/audio/playback_target_resolver.dart';
import 'package:frontend/providers/audio/queue_window.dart';

final playbackTargetResolverProvider = Provider<PlaybackTargetResolver>((ref) =>
    PlaybackTargetResolver(ref.read(queueRepositoryProvider)));

/// The playback core's window proposer. Shared with and disposed by
/// `AudioCoordinator`; its lifetime is the coordinator's provider scope.
final queueWindowProvider = Provider<QueueWindow>((ref) =>
    QueueWindow(ref.read(queueRepositoryProvider)));

final concatenatingPlayerProvider =
    Provider<ConcatenatingPlayerController>((ref) {
  final controller = ConcatenatingPlayerController.create(
    isOfflineFn: () => ref.read(offlineModeProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

final audioServiceProvider = Provider<AudioServiceBridge>((ref) {
  throw UnimplementedError('audioServiceProvider must be overridden');
});

final coverArtCacheProvider = Provider<CoverArtCacheManager>((ref) {
  return coverArtCache;
});
