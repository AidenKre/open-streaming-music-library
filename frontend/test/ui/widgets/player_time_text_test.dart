// Section 6 #9 (U20-FE-QUEUE-A-12): the mini and full player show track
// times as the track list does: "1:30:00" from one hour, "m:ss" below.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/ui/widgets/full_player.dart';
import 'package:frontend/ui/widgets/mini_player.dart';

const _track = TrackUI(
  uuidId: 'long',
  createdAt: 1,
  lastUpdated: 1,
  title: 'Long Track',
  artist: 'Artist',
  duration: 5400,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

class _StateQueuePlayer extends QueuePlayer {
  _StateQueuePlayer(this._state);
  final AudioState _state;
  @override
  AudioState build() => _state;
}

AudioState _state(Duration position, Duration duration) => AudioState(
      playback: PlaybackSlice(
        currentTrack: _track,
        status: PlayerStatus.paused,
        position: position,
        catalogDuration: duration,
      ),
      queue: const QueueSlice(currentItemId: 1, totalCount: 1),
    );

Future<void> _pump(WidgetTester tester, Widget child, AudioState state) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(overrides: [
    databaseProvider.overrideWithValue(db),
    coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
    queuePlayerProvider.overrideWith(() => _StateQueuePlayer(state)),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
        home: Scaffold(body: SizedBox(height: 700, child: child))),
  ));
  await tester.pump();
}

void main() {
  const longPosition = Duration(hours: 1, minutes: 1, seconds: 5);
  const longDuration = Duration(minutes: 90);

  testWidgets('the mini player shows a position past an hour as h:mm:ss',
      (tester) async {
    await _pump(tester, const MiniPlayer(), _state(longPosition, longDuration));
    expect(find.text('1:01:05'), findsOneWidget);
    expect(find.text('61:05'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the full player shows elapsed and length past an hour as '
      'h:mm:ss', (tester) async {
    await _pump(tester, const FullPlayer(), _state(longPosition, longDuration));
    expect(
        tester.widget<Text>(find.byKey(const Key('now_playing_elapsed'))).data,
        '1:01:05');
    expect(
        tester.widget<Text>(find.byKey(const Key('now_playing_duration'))).data,
        '1:30:00');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('under an hour both players keep m:ss', (tester) async {
    const position = Duration(minutes: 5, seconds: 7, milliseconds: 900);
    const duration = Duration(minutes: 59, seconds: 59);
    await _pump(tester, const MiniPlayer(), _state(position, duration));
    expect(find.text('5:07'), findsOneWidget);
    await _pump(tester, const FullPlayer(), _state(position, duration));
    expect(
        tester.widget<Text>(find.byKey(const Key('now_playing_elapsed'))).data,
        '5:07');
    expect(
        tester.widget<Text>(find.byKey(const Key('now_playing_duration'))).data,
        '59:59');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
