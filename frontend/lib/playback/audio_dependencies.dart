import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/playback/audio_session_port.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/playback/queue_window.dart';

final playbackTargetResolverProvider = Provider<PlaybackTargetResolver>((ref) =>
    PlaybackTargetResolver(ref.read(queueRepositoryProvider)));

/// The playback core's window proposer, used by `QueuePlayer`. Like the
/// engine, it is owned and disposed by this provider's scope.
final queueWindowProvider = Provider<QueueWindow>((ref) {
  final window = QueueWindow(ref.read(queueRepositoryProvider));
  ref.onDispose(window.dispose);
  return window;
});

final audioSessionPortProvider =
    Provider<AudioSessionPort>((ref) => AudioSessionAdapter());

final audioFocusProvider = Provider<AudioFocus>((ref) {
  final focus = AudioFocus(ref.read(audioSessionPortProvider));
  ref.onDispose(focus.dispose);
  return focus;
});

final playbackEngineProvider = Provider<PlaybackEngine>((ref) {
  final engine = JustAudioEngine.create(
    isOfflineFn: () => ref.read(offlineModeProvider),
    beforePlay: () => ref.read(audioFocusProvider).beforePlay(AudioOutput.queue),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

final audioServiceProvider = Provider<AudioServiceBridge>((ref) {
  throw UnimplementedError('audioServiceProvider must be overridden');
});

final coverArtCacheProvider = Provider<CoverArtCacheManager>((ref) {
  return coverArtCache;
});
