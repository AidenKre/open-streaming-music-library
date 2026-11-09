import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/playback_wiring.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_coordinator_test.dart' show FakePlaybackEngine;

class _HeldVolumePlayer extends FakePlaybackEngine {
  final volumeStarted = Completer<void>();
  final releaseVolume = Completer<void>();

  @override
  Future<void> setVolume(double volume) async {
    volumeStarted.complete();
    await releaseVolume.future;
  }
}

void main() {
  testWidgets(
    'disposing early OS playback wiring during volume restore is safe',
    (tester) async {
      SharedPreferences.setMockInitialValues({'audioVolume': 0.4});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      initCoverArtCache(CoverArtCacheManager.noop());
      final player = _HeldVolumePlayer();
      final bridge = AudioServiceBridge();
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWith((ref) async => prefs),
          streamQualityProvider.overrideWithValue('original'),
          playbackEngineProvider.overrideWithValue(player),
          audioServiceProvider.overrideWithValue(bridge),
        ],
      );
      final errors = <Object>[];
      // Binding before session activation is new in 4A.0b. An early OS
      // command constructs the player, whose startup work can still be
      // pending when the provider scope is replaced.
      runZonedGuarded(() {
        c.listen(playbackWiringProvider, (_, _) {});
        unawaited(bridge.play());
      }, (error, _) => errors.add(error));
      await tester.pump();
      expect(player.volumeStarted.isCompleted, isTrue);
      expect(c.read(audioProvider).queue.sessionId, isNull);
      c.dispose();
      player.releaseVolume.complete();
      await tester.pump();
      expect(bridge.onPlay, isNull);
      expect(
        errors,
        isEmpty,
        reason: 'startup must not publish after disposal',
      );
    },
  );
}
