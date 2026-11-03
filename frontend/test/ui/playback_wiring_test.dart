import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
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
