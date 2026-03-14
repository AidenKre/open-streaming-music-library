import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/audio/audio_player_controller.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/queue_resolver.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/providers/providers.dart';

final audioPlayerProvider = Provider<AudioPlayerController>((ref) {
  final controller = SingleAudioPlayerController.create();
  ref.onDispose(controller.dispose);
  return controller;
});

final trackCacheProvider = Provider<TrackCacheManager>((ref) {
  throw UnimplementedError('trackCacheProvider must be overridden');
});

final audioQueueLookupProvider = Provider<AudioQueueLookup>((ref) {
  return QueueResolver(ref.read(databaseProvider));
});

final audioServiceProvider = Provider<AudioServiceBridge>((ref) {
  throw UnimplementedError('audioServiceProvider must be overridden');
});
