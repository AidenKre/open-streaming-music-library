import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/now_playing_publisher.dart';
import 'package:frontend/playback/queue_warm_listener.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/services/history/listen_recorder.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/ui/playback_wiring.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_player_controls.dart';

/// OS media-session input (SC-27): the audio_service bridge's callbacks are
/// bound by playbackWiringProvider to PlayerControls, not by the playback
/// model; before binding they are no-ops.
void main() {
  late AudioServiceBridge bridge;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiClient.init('http://localhost:8080');
    initCoverArtCache(CoverArtCacheManager.noop());
    bridge = AudioServiceBridge();
  });

  ProviderContainer scope(FakePlayerControls controls) {
    final c = ProviderContainer(
      overrides: [
        audioServiceProvider.overrideWithValue(bridge),
        playerControlsProvider.overrideWithValue(controls),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pressEverything() async {
    await bridge.play();
    await bridge.pause();
    await bridge.skipToNext();
    await bridge.skipToPrevious();
    await bridge.seek(const Duration(seconds: 5));
    await bridge.stop();
    await bridge.click(MediaButton.media);
    await bridge.click(MediaButton.next);
  }

  test('callbacks before the wiring binds are no-ops', () async {
    final controls = FakePlayerControls();
    scope(controls);
    await pressEverything();
    expect(controls.calls, isEmpty);
  });

  test('bound callbacks reach PlayerControls, clicks included', () async {
    final controls = FakePlayerControls();
    scope(controls).listen(playbackWiringProvider, (_, _) {});
    await pressEverything();
    expect(controls.calls, [
      'play', 'pause', 'next', 'previous', 'seek 5000', 'stop',
      'click media', 'click next',
    ]);
  });

  test('observers are kept alive from the session-ready signal on', () async {
    var publishers = 0;
    var warmers = 0;
    final readiness = SessionReadiness();
    final c = ProviderContainer(overrides: [
      audioServiceProvider.overrideWithValue(bridge),
      playerControlsProvider.overrideWithValue(FakePlayerControls()),
      sessionReadinessProvider.overrideWithValue(readiness),
      nowPlayingPublisherProvider.overrideWith((ref) {
        publishers++;
        return NowPlayingPublisher(bridge, CoverArtCacheManager.noop());
      }),
      queueWarmListenerProvider.overrideWith((ref) {
        warmers++;
        return _NoWarm();
      }),
      listenRecorderProvider.overrideWith((ref) => _FakeRecorder()),
    ]);
    addTearDown(c.dispose);
    c.listen(playbackWiringProvider, (_, _) {});
    await pumpEventQueue();
    expect((publishers, warmers), (0, 0),
        reason: 'nothing builds the playback model before the session');
    readiness.markReady();
    await pumpEventQueue();
    expect((publishers, warmers), (1, 1));
  });

  test('the listen recorder is built and started once the session is ready',
      () async {
    final recorder = _FakeRecorder();
    var builds = 0;
    final readiness = SessionReadiness();
    final c = ProviderContainer(overrides: [
      audioServiceProvider.overrideWithValue(bridge),
      playerControlsProvider.overrideWithValue(FakePlayerControls()),
      sessionReadinessProvider.overrideWithValue(readiness),
      nowPlayingPublisherProvider.overrideWith(
          (ref) => NowPlayingPublisher(bridge, CoverArtCacheManager.noop())),
      queueWarmListenerProvider.overrideWith((ref) => _NoWarm()),
      listenRecorderProvider.overrideWith((ref) {
        builds++;
        return recorder;
      }),
    ]);
    addTearDown(c.dispose);
    c.listen(playbackWiringProvider, (_, _) {});
    await pumpEventQueue();
    expect((builds, recorder.starts), (0, 0));
    readiness.markReady();
    await pumpEventQueue();
    expect((builds, recorder.starts), (1, 1));
    expect(c.exists(listenRecorderProvider), isTrue, reason: 'kept alive');
  });

  test('a disposed scope unbinds; a newer scope keeps its binding', () async {
    final old = FakePlayerControls();
    final fresh = FakePlayerControls();
    final oldScope = ProviderContainer(
      overrides: [
        audioServiceProvider.overrideWithValue(bridge),
        playerControlsProvider.overrideWithValue(old),
      ],
    )..listen(playbackWiringProvider, (_, _) {});
    scope(fresh).listen(playbackWiringProvider, (_, _) {});
    oldScope.dispose(); // a reset rebuilt the scope; the old one goes away
    await bridge.play();
    expect(old.calls, isEmpty);
    expect(fresh.calls, ['play']);
  });
}

class _NoWarm implements QueueWarmListener {
  @override
  void update(AudioState state, String quality) {}
}

class _FakeRecorder implements ListenRecorder {
  int starts = 0;
  int checkpoints = 0;
  int quiesces = 0;
  @override
  Future<void> start() async => starts++;
  @override
  Future<void> checkpoint() async => checkpoints++;
  @override
  Future<void> appLifecycleChanged(AppLifecycleState state) async {}
  @override
  Future<void> quiesce() async => quiesces++;
  @override
  Future<void> get idle async {}
}
