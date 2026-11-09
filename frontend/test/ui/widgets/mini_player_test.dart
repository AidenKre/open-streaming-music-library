import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_coordinator.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/widgets/cover_art_image.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:frontend/ui/widgets/mini_player.dart';

import '../fake_player_controls.dart';

TrackUI _track({bool hasAlbumArt = false, int? coverArtId}) {
  return TrackUI(
    uuidId: 'mini-test',
    createdAt: 1,
    lastUpdated: 1,
    title: 'Mini Test',
    artist: 'Artist',
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: hasAlbumArt,
    coverArtId: coverArtId,
  );
}

AudioState _audioStateWith(
  TrackUI track, {
  PlayerStatus status = PlayerStatus.paused,
  bool? playWhenReady,
}) {
  return AudioState(
    playback: PlaybackSlice(
      currentTrack: track,
      status: status,
      // A playing status means play is desired (SC-27 desired transport).
      playWhenReady: playWhenReady ?? status == PlayerStatus.playing,
      duration: const Duration(minutes: 3),
    ),
    queue: const QueueSlice(),
  );
}

class _TestAudioCoordinator extends AudioCoordinator {
  final AudioState _state;
  _TestAudioCoordinator(this._state);

  @override
  AudioState build() => _state;
}

Future<void> _pumpMiniPlayer(
  WidgetTester tester,
  TrackUI track, {
  PlayerStatus status = PlayerStatus.paused,
  bool? playWhenReady,
  FakePlayerControls? controls,
  bool inColumn = false,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      audioProvider.overrideWith(
        () => _TestAudioCoordinator(_audioStateWith(track,
            status: status, playWhenReady: playWhenReady)),
      ),
      if (controls != null) playerControlsProvider.overrideWithValue(controls),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          // inColumn: as in the shell's bottom stack (loose height).
          body: inColumn
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [MiniPlayer()],
                )
              : const MiniPlayer(),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  group('MiniPlayer cover art', () {
    testWidgets('shows fallback music note when track has no cover art', (
      tester,
    ) async {
      await _pumpMiniPlayer(
        tester,
        _track(hasAlbumArt: false, coverArtId: null),
      );

      expect(find.byIcon(Icons.music_note), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('shows CoverArtImage when track has cover art', (tester) async {
      await _pumpMiniPlayer(tester, _track(hasAlbumArt: true, coverArtId: 7));

      expect(find.byType(CoverArtImage), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('MiniPlayer inputs go to PlayerControls (SC-27)', () {
    for (final status in [PlayerStatus.paused, PlayerStatus.playing]) {
      testWidgets('play/pause button asks the model to toggle ($status)', (
        tester,
      ) async {
        final controls = FakePlayerControls();
        await _pumpMiniPlayer(
          tester,
          _track(),
          status: status,
          controls: controls,
        );
        await tester.tap(
          find.byIcon(
            status == PlayerStatus.playing ? Icons.pause : Icons.play_arrow,
          ),
        );
        // The view never decides play vs pause.
        expect(controls.calls, ['toggle']);
      });
    }

    testWidgets('while loading with play desired the control shows pause', (
      tester,
    ) async {
      final controls = FakePlayerControls();
      await _pumpMiniPlayer(tester, _track(),
          status: PlayerStatus.loading, playWhenReady: true, controls: controls);
      await tester.tap(find.byIcon(Icons.pause));
      expect(controls.calls, ['toggle']);
    });

    testWidgets('shuffle, previous, next and repeat buttons', (tester) async {
      final controls = FakePlayerControls();
      await _pumpMiniPlayer(tester, _track(), controls: controls);
      await tester.tap(find.byIcon(Icons.shuffle));
      await tester.tap(find.byIcon(Icons.skip_previous));
      await tester.tap(find.byIcon(Icons.skip_next));
      await tester.tap(find.byIcon(Icons.repeat));
      expect(controls.calls, ['shuffle', 'previous', 'next', 'repeat']);
    });
  });

  // 4A live C03 (narrow window, text scale 2): the mini player grows with
  // the text instead of overflowing a fixed 64-pt height.
  group('MiniPlayer text scale', () {
    for (final scale in [1.0, 2.0]) {
      testWidgets('360 pt wide at text scale $scale: no overflow', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _pumpMiniPlayer(tester, _track(), inColumn: true);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final height = tester.getSize(find.byType(MiniPlayer)).height;
        if (scale == 1.0) {
          expect(height, 64, reason: 'unchanged at the standard scale');
        } else {
          expect(height, greaterThan(64));
        }
      });
    }
  });
}
