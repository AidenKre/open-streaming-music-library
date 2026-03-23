import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_coordinator.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/ui/widgets/full_player.dart';

void main() {
  testWidgets('seek slider only commits one seek on release', (tester) async {
    final container = ProviderContainer(
      overrides: [audioProvider.overrideWith(TestSeekAudioCoordinator.new)],
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

    final notifier =
        container.read(audioProvider.notifier) as TestSeekAudioCoordinator;
    final sliderFinder = find.byKey(const Key('now_playing_seek_slider'));
    final sliderBox = tester.renderObject<RenderBox>(sliderFinder);
    final start = sliderBox.localToGlobal(
      Offset(sliderBox.size.width / 6, sliderBox.size.height / 2),
    );
    final target = sliderBox.localToGlobal(
      Offset(sliderBox.size.width / 2, sliderBox.size.height / 2),
    );

    final gesture = await tester.startGesture(start);
    await tester.pump();
    await gesture.moveTo(target);
    await tester.pump();

    final slider = tester.widget<Slider>(sliderFinder);
    final elapsed = tester.widget<Text>(
      find.byKey(const Key('now_playing_elapsed')),
    );

    expect(notifier.seekCalls, isEmpty);
    expect(slider.value, closeTo(90000, 10000));
    expect(elapsed.data, isNot('0:30'));

    await gesture.up();
    await tester.pump();

    expect(notifier.seekCalls, hasLength(1));
    expect(
      notifier.seekCalls.single.inMilliseconds,
      closeTo(slider.value, 10000),
    );
  });
}

class TestSeekAudioCoordinator extends AudioCoordinator {
  final List<Duration> seekCalls = [];

  static const _track = TrackUI(
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

  @override
  AudioState build() {
    return const AudioState(
      playback: PlaybackSlice(
        currentTrack: _track,
        status: PlayerStatus.playing,
        position: Duration(seconds: 30),
        duration: Duration(minutes: 3),
      ),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    state = state.copyWith(
      playback: state.playback.copyWith(position: position),
    );
  }
}
