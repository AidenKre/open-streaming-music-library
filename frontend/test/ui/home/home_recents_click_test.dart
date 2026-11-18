// Phase 6 §3 "Recent track tap" (6-R03 unit half): a recent track tap
// starts a new single-track queue, records exactly one track click through
// the single `PlaybackRequests.submit` emit site, and that click bumps the
// track to the front of the live rail. Real `HomeController`,
// `LibraryActions`, `PlaybackRequests`, `ClickRecorder` and
// `RecentlyPlayedRepository` over in-memory Drift; only the audio player is
// faked.
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/ui/home/home_controller.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/server_binding.dart';
import '../../repositories/catalog_seed.dart';
import '../../helpers/library_seed.dart' show SeedTrack, seedLibrary;
import '../../helpers/test_offline.dart';

/// The audio player, faked: every activation succeeds.
class _Player extends QueuePlayer {
  final activated = <int>[];

  @override
  AudioState build() => const AudioState();

  @override
  Future<ActivationResult> activatePreparedSession(
    int sessionId,
    PlaybackTarget target, {
    required bool autoPlay,
    required int requestRevision,
  }) async {
    activated.add(sessionId);
    return ActivationResult.accepted;
  }

  @override
  Future<void> reportIssues(Iterable<Object?> issues,
      {bool publish = true}) async {}
}

String _describe(HomeRecentsState s) => switch (s) {
  HomeRecentsReady(:final entities) =>
    'ready ${entities.map((e) => (e.key as ValueKey<String>).value).join(',')}',
  _ => s.runtimeType.toString(),
};

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _Player player;
  late FakeClock clock;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(uuid: 'a', title: 'A', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'One'),
      SeedTrack(uuid: 'b', title: 'B', artistId: 1, artist: 'Ann',
          albumId: 1, album: 'One', trackNumber: 2),
    ]);
    await seedTestBinding(db, instanceId: 'srv-1', reconciled: true);
    // An older click: the fake clock's "now" is far later.
    await CatalogSeed(db).click('track', 'b', at: 1000);
    player = _Player();
    clock = FakeClock();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      queuePlayerProvider.overrideWith(() => player),
      offlineModeProvider.overrideWith(() => TestOffline(false)),
      clockProvider.overrideWithValue(clock),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  HomeControls controls() {
    container.listen(homeControlsProvider, (_, _) {});
    return container.read(homeControlsProvider);
  }

  Future<void> until(HomeControls c, String want) {
    final done = Completer<void>();
    void check() {
      if (!done.isCompleted && _describe(c.recents) == want) done.complete();
    }

    c.addListener(check);
    check();
    return done.future
        .timeout(const Duration(seconds: 5),
            onTimeout: () => fail('never "$want"; last: ${_describe(c.recents)}'))
        .whenComplete(() => c.removeListener(check));
  }

  Future<List<(String, String)>> clicks() async {
    await pumpEventQueue();
    final rows = await (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked'))
          ..orderBy([(e) => OrderingTerm(expression: e.localId)]))
        .get();
    return [for (final r in rows) (r.entityType, r.entityRef)];
  }

  Future<TrackUI> track(String uuid) async =>
      (await container.read(browseRepositoryProvider).getTracksByUuids([uuid]))
          .single;

  /// The items of the session the player activated, in queue order.
  Future<List<String>> activatedQueue() async {
    final rows = await (db.select(db.queueSessionItems)
          ..where((i) => i.sessionId.equals(player.activated.single))
          ..orderBy([(i) => OrderingTerm(expression: i.position)]))
        .get();
    return [for (final r in rows) r.uuidId];
  }

  test('a track tap plays a single-track queue, records one click and '
      'bumps the track to the front', () async {
    final c = controls();
    await until(c, 'ready track:b');

    expect(await c.playTrack(await track('a')), isA<Accepted>());
    expect(await clicks(), [('track', 'b'), ('track', 'a')]);
    expect(await activatedQueue(), ['a']);
    await until(c, 'ready track:a,track:b');
  });

  test('tapping a track already in the rail moves it to the front with one '
      'new click', () async {
    final c = controls();
    await c.playTrack(await track('a'));
    await until(c, 'ready track:a,track:b');

    clock.advance(const Duration(seconds: 1));
    expect(await c.playTrack(await track('b')), isA<Accepted>());
    expect(await clicks(), [('track', 'b'), ('track', 'a'), ('track', 'b')]);
    await until(c, 'ready track:b,track:a');
  });
}
