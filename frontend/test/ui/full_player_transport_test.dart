import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_coordinator.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:frontend/ui/widgets/full_player.dart';

import 'fake_player_controls.dart';

const _track = TrackUI(
  uuidId: 'track-1',
  createdAt: 1,
  lastUpdated: 1,
  title: 'Track 1',
  artist: 'Artist',
  album: 'Album',
  duration: 180,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

class _StateOnly extends AudioCoordinator {
  _StateOnly(this._initial);
  final AudioState _initial;
  @override
  AudioState build() => _initial;
}

Future<FakePlayerControls> _pump(
  WidgetTester tester, {
  PlayerStatus status = PlayerStatus.playing,
  bool? playWhenReady,
  Duration duration = const Duration(minutes: 3),
}) async {
  final controls = FakePlayerControls();
  final container = ProviderContainer(
    overrides: [
      audioProvider.overrideWith(
        () => _StateOnly(
          AudioState(
            playback: PlaybackSlice(
              currentTrack: _track,
              status: status,
              // A playing status means play is desired (SC-27).
              playWhenReady: playWhenReady ?? status == PlayerStatus.playing,
              position: const Duration(seconds: 30),
              duration: duration,
            ),
          ),
        ),
      ),
      playerControlsProvider.overrideWithValue(controls),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(height: 700, child: FullPlayer())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controls;
}

void main() {
  for (final status in [PlayerStatus.playing, PlayerStatus.paused]) {
    testWidgets('play/pause asks the model to toggle ($status)', (t) async {
      final controls = await _pump(t, status: status);
      await t.tap(find.byIcon(
        status == PlayerStatus.playing
            ? Icons.pause_circle_filled
            : Icons.play_circle_filled,
      ));
      expect(controls.calls, ['toggle']);
    });
  }

  testWidgets('while loading with play desired the control shows pause',
      (t) async {
    final controls =
        await _pump(t, status: PlayerStatus.loading, playWhenReady: true);
    await t.tap(find.byIcon(Icons.pause_circle_filled));
    expect(controls.calls, ['toggle']);
  });

  testWidgets('transport buttons and volume go to PlayerControls', (t) async {
    final controls = await _pump(t);
    await t.tap(find.byIcon(Icons.shuffle));
    await t.tap(find.byIcon(Icons.skip_previous));
    await t.tap(find.byIcon(Icons.skip_next));
    await t.tap(find.byIcon(Icons.repeat));
    final volume = find.byType(Slider).last;
    await t.ensureVisible(volume);
    await t.pumpAndSettle();
    await t.drag(volume, const Offset(-40, 0));
    expect(controls.calls.take(4), ['shuffle', 'previous', 'next', 'repeat']);
    expect(controls.calls.last, startsWith('volume'));
  });

  testWidgets('releasing the scrubber sends one seek to the controller',
      (t) async {
    final controls = await _pump(t);
    final slider = find.byKey(const Key('now_playing_seek_slider'));
    await t.tapAt(t.getCenter(slider));
    await t.pump();
    expect(controls.calls.where((c) => c.startsWith('seek')), hasLength(1));
  });

  testWidgets('unknown (zero) duration: elapsed shows the real position',
      (t) async {
    await _pump(t, duration: Duration.zero);
    final elapsed = t.widget<Text>(find.byKey(const Key('now_playing_elapsed')));
    expect(elapsed.data, '0:30');
  });
}
