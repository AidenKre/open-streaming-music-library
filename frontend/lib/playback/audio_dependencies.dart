import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/playback/audio_session_port.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/playback/queue_order_manager.dart';
import 'package:frontend/playback/queue_window.dart';

final queueOrderManagerProvider = Provider<QueueOrderManager>((ref) =>
    QueueOrderManager(
        ref.read(queueRepositoryProvider), ref.read(queueRandomProvider)));

final playbackTargetResolverProvider = Provider<PlaybackTargetResolver>((ref) =>
    PlaybackTargetResolver(ref.read(queueRepositoryProvider),
        localSources: ref.read(localSourcePolicyProvider)));

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
  final gate = ref.read(serverBindingGateProvider);
  final engine = JustAudioEngine.create(
    streamBaseUrl: ref.read(apiClientProvider).baseUrl,
    streamMediaToken: ref.read(credentialsProvider)?.mediaToken,
    mediaTokenPermit: gate,
    // An advance onto a stream while the server check failed is handled like
    // offline: the queue player's unavailable-advance rescue (sign-off
    // OPEN-M-11 step D).
    isOfflineFn: ref.read(streamsUnavailableProvider),
    beforePlay: () => ref.read(audioFocusProvider).beforePlay(AudioOutput.queue),
    localSources: ref.read(localSourcePolicyProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

final audioServiceProvider = Provider<AudioServiceBridge>((ref) {
  throw UnimplementedError('audioServiceProvider must be overridden');
});

final coverArtCacheProvider = Provider<CoverArtCacheManager>((ref) {
  final api = ref.read(apiClientProvider);
  return CoverArtCacheManager(
    api: api,
    cache: ref.read(coverArtDiskCacheProvider),
    localStore: ref.read(localCoverArtStoreProvider),
    authHeaders: switch (ref.read(credentialsProvider)) {
      final c? => bearerAuthHeader(c.token),
      null => null,
    },
    mayAttachToken: () =>
        ref.read(serverBindingGateProvider).whenMaySendTokenTo(api.baseUrl),
  );
});
