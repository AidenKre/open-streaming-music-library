import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/ui/widgets/full_player.dart';

void main() {
  // Drags the slider from a sixth to the middle and releases it (~90 s).
  Future<void> dragToMiddle(WidgetTester tester) async {
    final sliderFinder = find.byKey(const Key('now_playing_seek_slider'));
    final sliderBox = tester.renderObject<RenderBox>(sliderFinder);
    final gesture = await tester.startGesture(sliderBox.localToGlobal(
        Offset(sliderBox.size.width / 6, sliderBox.size.height / 2)));
    await tester.pump();
    await gesture.moveTo(sliderBox.localToGlobal(
        Offset(sliderBox.size.width / 2, sliderBox.size.height / 2)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  Future<ProviderContainer> pumpPlayer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [queuePlayerProvider.overrideWith(TestSeekQueuePlayer.new)],
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
    return container;
  }

  double sliderValue(WidgetTester tester) => tester
      .widget<Slider>(find.byKey(const Key('now_playing_seek_slider')))
      .value;

  testWidgets('U20-FE-QUEUE-A-11: a failed seek releases the slider to the '
      'real position', (tester) async {
    final container = await pumpPlayer(tester);
    final notifier =
        container.read(queuePlayerProvider.notifier) as TestSeekQueuePlayer;
    notifier.seekError = StateError('seek refused');

    await dragToMiddle(tester);
    await tester.pump();
    expect(notifier.seekCalls, hasLength(1));
    // Playback goes on from where it was.
    notifier.tick(const Duration(seconds: 31));
    await tester.pump();
    await tester.pump();

    expect(sliderValue(tester), 31000,
        reason: 'the slider follows playback again, not the refused target');
  });

  testWidgets('U20-FE-QUEUE-A-11: a new current track releases a pending '
      'seek', (tester) async {
    final container = await pumpPlayer(tester);
    final notifier =
        container.read(queuePlayerProvider.notifier) as TestSeekQueuePlayer;
    notifier.applySeek = false; // the seek never lands

    await dragToMiddle(tester);
    notifier.nextTrack(); // the track ends; the next one starts at 0:05
    await tester.pump();
    await tester.pump();

    expect(sliderValue(tester), 5000,
        reason: 'the old track\'s target is not shown on the new track');
  });

  testWidgets('seek slider only commits one seek on release', (tester) async {
    final container = ProviderContainer(
      overrides: [queuePlayerProvider.overrideWith(TestSeekQueuePlayer.new)],
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
        container.read(queuePlayerProvider.notifier) as TestSeekQueuePlayer;
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

class TestSeekQueuePlayer extends QueuePlayer {
  final List<Duration> seekCalls = [];
  Object? seekError;
  bool applySeek = true;

  void tick(Duration position) {
    state = state.copyWith(
      playback: state.playback.copyWith(position: position),
    );
  }

  void nextTrack() {
    state = state.copyWith(
      playback: state.playback.copyWith(
        currentTrack: _track2,
        position: const Duration(seconds: 5),
      ),
      queue: state.queue.copyWith(currentItemId: 2, currentPlayPosition: 1),
    );
  }

  static const _track2 = TrackUI(
    uuidId: 'track-2',
    createdAt: 1,
    lastUpdated: 1,
    title: 'Track 2',
    artist: 'Artist',
    album: 'Album',
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );

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
        catalogDuration: Duration(minutes: 3),
      ),
      queue: QueueSlice(currentItemId: 1, totalCount: 2),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls.add(position);
    final error = seekError;
    if (error != null) throw error;
    if (!applySeek) return;
    state = state.copyWith(
      playback: state.playback.copyWith(position: position),
    );
  }
}
