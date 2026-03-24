import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/concatenating_player_controller.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';

final concatenatingPlayerProvider =
    Provider<ConcatenatingPlayerController>((ref) {
  final controller = ConcatenatingPlayerController.create();
  ref.onDispose(controller.dispose);
  return controller;
});

final audioServiceProvider = Provider<AudioServiceBridge>((ref) {
  throw UnimplementedError('audioServiceProvider must be overridden');
});

final coverArtCacheProvider = Provider<CoverArtCacheManager>((ref) {
  return coverArtCache;
});
