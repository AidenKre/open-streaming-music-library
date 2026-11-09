import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/now_playing_publisher.dart';
import 'package:frontend/playback/queue_warm_listener.dart';
import 'package:frontend/services/history/listen_recorder.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/ui/player_controller.dart';

/// Composition-root wiring for playback (SC-27): binds the OS media
/// session's input (audio_service bridge callbacks, including generic media
/// button clicks) to [PlayerControls] with an owner token, and unbinds on
/// disposal. Kept alive for the whole provider scope by `ref.listenManual`
/// in `_FrontendState.initState`, so a reset (new keyed scope) binds a fresh
/// one and the old scope's disposal can't clear it.
///
/// Lives under `ui/` because it binds to a controller; the playback model
/// never imports `ui/` (D14). Binding never builds the playback model; the
/// first OS command does, and queue restore waits for the session (B8).
/// The playback observers (OS now-playing, queue warm, listen recording)
/// are kept alive from
/// the session-ready signal on, which is also when they first build the
/// model (SC-27 principle 13).
class PlaybackWiring {
  PlaybackWiring._();
}

final playbackWiringProvider = Provider<PlaybackWiring>((ref) {
  final bridge = ref.read(audioServiceProvider);
  final wiring = PlaybackWiring._();
  PlayerControls controls() => ref.read(playerControlsProvider);
  bridge.bindCallbacks(
    owner: wiring,
    onPlay: () => controls().play(),
    onPause: () => controls().pause(),
    onSkipToNext: () => controls().skipNext(),
    onSkipToPrevious: () => controls().skipPrevious(),
    onSeek: (position) => controls().seek(position),
    onStop: () => controls().stop(),
    onClick: (button) => controls().click(button),
  );
  ref.onDispose(() => bridge.clearCallbacks(wiring));
  unawaited(ref.read(sessionReadinessProvider).ready.then((_) {
    if (!ref.mounted) return;
    ref.listen(nowPlayingPublisherProvider, (_, _) {});
    ref.listen(queueWarmListenerProvider, (_, _) {});
    // Listen accounting starts behind its startup barrier (5B.3).
    ref.listen(listenRecorderProvider, (_, _) {});
    unawaited(ref.read(listenRecorderProvider).start());
  }));
  return wiring;
});
