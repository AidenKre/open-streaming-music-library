// Phase 6A.1a (SC-06, 6-U05 queue actions, 6-I04 unit half): a collection
// Play next / Add to queue, as every Search, browse and card menu submits it
// through `LibraryActions`, records exactly one album/artist click under
// SC-04 readiness and none before. Real `PlaybackRequests` and real
// `ClickRecorder` over in-memory Drift; only the audio player is faked.
import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/ui/library_actions.dart';

import '../helpers/fake_clock.dart';
import '../helpers/server_binding.dart';
import 'browse_harness.dart';

/// The audio player, faked: an optional current session that accepts
/// enqueues, and an activation that always succeeds.
class _Player extends QueuePlayer {
  _Player(this.sessionId);
  final int? sessionId;
  final enqueued = <List<String>>[];
  final activated = <int>[];
  final issues = <Object?>[];

  @override
  AudioState build() => AudioState(queue: QueueSlice(sessionId: sessionId));

  @override
  Future<EnqueueResult> enqueue(List<String> uuids, EnqueuePosition position,
      {required int expectedSessionId,
      MonotonicStopwatch? sinceSubmitted}) async {
    enqueued.add(uuids);
    return EnqueueResult.applied;
  }

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
      {bool publish = true}) async {
    if (publish) this.issues.addAll(issues);
    await issuesGate?.future;
  }

  /// When set, reporting issues (the missing-download reconcile) waits for it.
  Completer<void>? issuesGate;

  /// What Stop does to admission and the queue: a newer revision, no session.
  void simulateStop() {
    admitReplacement();
    state = const AudioState(queue: QueueSlice());
  }

  /// What a sync removal of every queued track does: the queue is gone, but
  /// no request was admitted.
  void simulateQueueEmptied() {
    state = const AudioState(queue: QueueSlice());
  }
}

/// A membership read that fails (6-R2-07).
class _FailingBrowse extends BrowseRepository {
  _FailingBrowse(super.db);
  @override
  Future<List<TrackUI>> getTracksForScope(LibraryScope scope,
          {required bool offline}) =>
      Future.error(StateError('membership read failed'));
}

/// A server binding read that fails (6-R2-07).
class _FailingBinding extends ServerBindingRepository {
  _FailingBinding(super.db);
  @override
  Future<ServerBindingRecord?> current() =>
      Future.error(StateError('binding read failed'));
}

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late _Player player;

  // Artist 1 owns album 2 (tracks n1, n2) and album 1 (a1).
  const seed = [
    SeedTrack(uuid: 'a1', title: 'a1', artistId: 1, artist: 'Ann',
        albumId: 1, album: 'Old', albumYear: 2001),
    SeedTrack(uuid: 'n2', title: 'n2', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'New', albumYear: 2010, trackNumber: 2),
    SeedTrack(uuid: 'n1', title: 'n1', artistId: 1, artist: 'Ann',
        albumId: 2, album: 'New', albumYear: 2010, trackNumber: 1),
  ];

  /// Files that exist on disk, as the resolver's stat sees them.
  late Set<String> existingFiles;

  /// When set, every file stat waits for it.
  Completer<void>? statGate;

  Future<void> start({
    required bool reconciled,
    String? instanceId = 'srv-1',
    int? sessionId = 7,
    bool offline = false,
    CodecSupport codecs = const CodecSupport.unknown(),
    bool failingMembership = false,
    bool failingBinding = false,
  }) async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, seed);
    await seedTestBinding(db, instanceId: instanceId, reconciled: reconciled);
    player = _Player(sessionId);
    existingFiles = {};
    statGate = null;
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      queuePlayerProvider.overrideWith(() => player),
      offlineModeProvider.overrideWith(() => TestOffline(offline)),
      clockProvider.overrideWithValue(FakeClock()),
      codecSupportProvider.overrideWithValue(codecs),
      playbackTargetResolverProvider.overrideWith((ref) =>
          PlaybackTargetResolver(ref.read(queueRepositoryProvider),
              fileExists: (path) async {
                await statGate?.future;
                return existingFiles.contains(path);
              },
              localSources: ref.read(localSourcePolicyProvider))),
      if (failingMembership)
        browseRepositoryProvider.overrideWith((ref) => _FailingBrowse(db)),
      if (failingBinding)
        serverBindingRepositoryProvider
            .overrideWith((ref) => _FailingBinding(db)),
    ]);
  }

  /// Records a usable download of [uuid] in [codec], present on disk unless
  /// [onDisk] is false.
  Future<void> download(String uuid,
      {String codec = 'flac', bool onDisk = true}) async {
    final path = '/downloads/$uuid.$codec';
    await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
      TracksCompanion(
        filePath: Value(path),
        downloadedAtRevision: const Value(1),
        downloadedCodec: Value(codec),
      ),
    );
    if (onDisk) existingFiles.add(path);
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<List<(String, String)>> clicks() async {
    await pumpEventQueue();
    final rows = await (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked'))
          ..orderBy([(e) => OrderingTerm(expression: e.localId)]))
        .get();
    return [for (final r in rows) (r.entityType, r.entityRef)];
  }

  LibraryActionControls actions() => container.read(libraryActionsProvider);

  const album = AlbumScope(artistId: 1, albumId: 2);
  const artist = ArtistScope(artistId: 1);

  for (final hasSession in [true, false]) {
    final label = hasSession ? 'into the current queue' : 'with no queue';

    group('readiness present, $label', () {
      setUp(() => start(reconciled: true, sessionId: hasSession ? 7 : null));

      test('Play next on an album records exactly one album click',
          () async {
        expect(await actions().playNext(album), isA<Accepted>());
        expect(await clicks(), [('album', 'srv-1:2')]);
      });

      test('Add to queue on an album records exactly one album click',
          () async {
        expect(await actions().addToQueue(album), isA<Accepted>());
        expect(await clicks(), [('album', 'srv-1:2')]);
      });

      test('Play next / Add to queue on an artist record one artist click',
          () async {
        expect(await actions().playNext(artist), isA<Accepted>());
        expect(await actions().addToQueue(artist), isA<Accepted>());
        expect(await clicks(), [('artist', 'srv-1:1'), ('artist', 'srv-1:1')]);
      });

      test('the whole membership is queued, and no member track is clicked',
          () async {
        await actions().addToQueue(album);
        if (hasSession) {
          expect(player.enqueued, [
            ['n1', 'n2'],
          ]);
        } else {
          expect(player.activated, hasLength(1),
              reason: 'the no-session fallback started a queue');
        }
        final refs = (await clicks()).map((c) => c.$2);
        expect(refs, isNot(contains('n1')));
        expect(refs, isNot(contains('n2')));
      });
    });

    group('readiness absent, $label', () {
      setUp(() => start(reconciled: false, sessionId: hasSession ? 7 : null));

      test('collection queue actions work but record no click', () async {
        expect(await actions().playNext(album), isA<Accepted>());
        expect(await actions().addToQueue(artist), isA<Accepted>());
        expect(await clicks(), isEmpty);
      });
    });
  }

  group('a reconciled binding without an instance id', () {
    setUp(() => start(reconciled: true, instanceId: null));

    test('records no collection click', () async {
      expect(await actions().playNext(album), isA<Accepted>());
      expect(await clicks(), isEmpty);
    });
  });

  test('an empty collection submits nothing and records nothing', () async {
    await start(reconciled: true);
    expect(await actions().addToQueue(const AlbumScope(artistId: 1, albumId: 99)),
        isA<RejectedEmpty>());
    expect(await clicks(), isEmpty);
    expect(player.enqueued, isEmpty);
  });
  // 6-R2-07: a failure before the submit (membership or binding read) is
  // the Failed outcome, for the menus and the detail page alike.
  group('6-R2-07: a failing read before the submit', () {
    for (final (label, membership, binding) in [
      ('membership', true, false),
      ('server binding', false, true),
    ]) {
      test('the $label read fails: every action ends Failed, nothing queued, '
          'no click', () async {
        await start(
            reconciled: true,
            failingMembership: membership,
            failingBinding: binding);
        for (final action in [
          actions().playNext,
          actions().addToQueue,
          actions().play,
          actions().shuffle,
        ]) {
          expect(await action(album), isA<Failed>());
        }
        expect(player.enqueued, isEmpty);
        expect(player.activated, isEmpty);
        expect(await clicks(), isEmpty);
      });
    }
  });

  group('6A.2: detail Play and Shuffle', () {
    for (final hasSession in [true, false]) {
      final label = hasSession ? 'replacing the current queue' : 'with no queue';

      test('an accepted album Play records exactly one album click, $label',
          () async {
        await start(reconciled: true, sessionId: hasSession ? 7 : null);
        expect(await actions().play(album), isA<Accepted>());
        expect(player.activated, hasLength(1));
        expect(await clicks(), [('album', 'srv-1:2')]);
      });

      test('an accepted artist Shuffle records exactly one artist click, '
          '$label', () async {
        await start(reconciled: true, sessionId: hasSession ? 7 : null);
        expect(await actions().shuffle(artist), isA<Accepted>());
        expect(player.activated, hasLength(1));
        expect(await clicks(), [('artist', 'srv-1:1')]);
      });
    }

    test('Play and Shuffle before readiness play but record no click',
        () async {
      await start(reconciled: false);
      expect(await actions().play(album), isA<Accepted>());
      expect(await actions().shuffle(artist), isA<Accepted>());
      expect(player.activated, hasLength(2));
      expect(await clicks(), isEmpty);
    });

    test('an empty collection plays nothing and records nothing', () async {
      await start(reconciled: true);
      expect(await actions().play(const AlbumScope(artistId: 1, albumId: 99)),
          isA<RejectedEmpty>());
      expect(await actions().shuffle(const ArtistScope(artistId: 42)),
          isA<RejectedEmpty>());
      expect(player.activated, isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('offline, a collection whose downloads are all undecodable is '
        'rejected: no queue, no click (O2)', () async {
      await start(
          reconciled: true,
          offline: true,
          codecs: const CodecSupport({AudioCodecFamily.mp3}));
      await download('n1');
      expect(await actions().play(album), isA<RejectedUnplayableOffline>());
      expect(player.activated, isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('offline, a partly downloaded album plays its downloads with one '
        'album click', () async {
      await start(reconciled: true, offline: true);
      await download('n2');
      expect(await actions().play(album), isA<Accepted>());
      expect(player.activated, hasLength(1));
      expect(await clicks(), [('album', 'srv-1:2')]);
    });
  });
  // R1-1 (amends DEV-6-02): offline, with a queue already active, Play next /
  // Add to queue on a collection queue only the members this device can play
  // (the resolver's local-playability rule); none playable ends
  // RejectedUnplayableOffline with nothing queued and no click.
  group('6A.2: offline enqueue into an active queue', () {
    const mp3Only = CodecSupport({AudioCodecFamily.mp3});

    test('a partly undecodable album queues only the playable members, '
        'with one album click', () async {
      await start(reconciled: true, offline: true, codecs: mp3Only);
      await download('n1', codec: 'flac'); // undecodable here
      await download('n2', codec: 'mp3');
      expect(await actions().playNext(album), isA<Accepted>());
      expect(player.enqueued, [
        ['n2'],
      ]);
      expect(await clicks(), [('album', 'srv-1:2')]);
    });

    test('an artist keeps its order across the playable members', () async {
      await start(reconciled: true, offline: true, codecs: mp3Only);
      await download('n1', codec: 'mp3');
      await download('n2', codec: 'flac');
      await download('a1', codec: 'mp3');
      expect(await actions().addToQueue(artist), isA<Accepted>());
      expect(player.enqueued, [
        ['n1', 'a1'],
      ]);
      expect(await clicks(), [('artist', 'srv-1:1')]);
    });

    test('all downloads undecodable: RejectedUnplayableOffline, nothing '
        'queued, no click', () async {
      await start(reconciled: true, offline: true, codecs: mp3Only);
      await download('n1', codec: 'flac');
      await download('n2', codec: 'flac');
      expect(await actions().playNext(album),
          isA<RejectedUnplayableOffline>());
      expect(await actions().addToQueue(album),
          isA<RejectedUnplayableOffline>());
      expect(player.enqueued, isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('downloads missing on disk: RejectedUnplayableOffline, the missing '
        'files reported, no click', () async {
      await start(reconciled: true, offline: true);
      await download('n1', onDisk: false);
      await download('n2', onDisk: false);
      expect(await actions().addToQueue(album),
          isA<RejectedUnplayableOffline>());
      expect(player.enqueued, isEmpty);
      expect(await clicks(), isEmpty);
      expect(player.issues.whereType<LocalFileMissing>().map((i) => i.trackUuid),
          unorderedEquals(['n1', 'n2']));
    });

    test('a single undecodable track is rejected the same way', () async {
      await start(reconciled: true, offline: true, codecs: mp3Only);
      await download('n1', codec: 'flac');
      final track = (await container
              .read(browseRepositoryProvider)
              .getTracksForScope(album, offline: true))
          .single;
      expect(await actions().playNext(TrackScope(track)),
          isA<RejectedUnplayableOffline>());
      expect(player.enqueued, isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('online, the whole membership is queued as before', () async {
      await start(reconciled: true, codecs: mp3Only);
      await download('n1', codec: 'flac', onDisk: false);
      expect(await actions().playNext(album), isA<Accepted>());
      expect(player.enqueued, [
        ['n1', 'n2'],
      ]);
      expect(await clicks(), [('album', 'srv-1:2')]);
    });

    test('a replacement submitted while the files are checked supersedes '
        'the enqueue: nothing queued, no collection click', () async {
      await start(reconciled: true, offline: true);
      await download('n1');
      await download('n2');
      statGate = Completer<void>();
      final enqueue = actions().addToQueue(album);
      await pumpEventQueue();
      final play = container.read(playbackRequestsProvider).submit(
          PlayList(['a1'], 0, const ListSource('search')));
      statGate!.complete();
      await download('a1');
      expect(await enqueue, isA<Superseded>());
      await play;
      expect(player.enqueued, isEmpty);
      expect((await clicks()).where((c) => c.$1 == 'album'), isEmpty);
    });
  });
  // 6-R1-03 (amends DEV-6-02): the offline filter covers the no-session
  // fallback too, so every Play next / Add to queue offline queues only what
  // this device can play.
  group('6-R1-03: offline enqueue with no queue', () {
    const mp3Only = CodecSupport({AudioCodecFamily.mp3});

    Future<List<String>> queued(int sessionId) async {
      final rows = await (db.select(db.queueSessionItems)
            ..where((i) => i.sessionId.equals(sessionId))
            ..orderBy([(i) => OrderingTerm(expression: i.position)]))
          .get();
      return [for (final r in rows) r.uuidId];
    }

    test('a partly undecodable album starts a queue of only the playable '
        'members, with one album click', () async {
      await start(
          reconciled: true, offline: true, sessionId: null, codecs: mp3Only);
      await download('n1', codec: 'flac'); // undecodable here
      await download('n2', codec: 'mp3');
      expect(await actions().playNext(album), isA<Accepted>());
      expect(player.activated, hasLength(1));
      expect(await queued(player.activated.single), ['n2']);
      expect(await clicks(), [('album', 'srv-1:2')]);
    });

    test('all downloads undecodable: RejectedUnplayableOffline, no queue '
        'started, no click', () async {
      await start(
          reconciled: true, offline: true, sessionId: null, codecs: mp3Only);
      await download('n1', codec: 'flac');
      await download('n2', codec: 'flac');
      expect(await actions().addToQueue(album),
          isA<RejectedUnplayableOffline>());
      expect(player.activated, isEmpty);
      expect(await db.select(db.queueSessions).get(), isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('downloads missing on disk: rejected, the missing files reported',
        () async {
      await start(reconciled: true, offline: true, sessionId: null);
      await download('n1', onDisk: false);
      await download('n2', onDisk: false);
      expect(await actions().playNext(album),
          isA<RejectedUnplayableOffline>());
      expect(player.activated, isEmpty);
      expect(await clicks(), isEmpty);
      expect(player.issues.whereType<LocalFileMissing>().map((i) => i.trackUuid),
          unorderedEquals(['n1', 'n2']));
    });

    // 6-R2-08: a single track follows the same offline rule with no queue.
    Future<TrackScope> trackScope(String uuid) async => TrackScope(
        (await container
                .read(browseRepositoryProvider)
                .getTracksForScope(album, offline: false))
            .firstWhere((t) => t.uuidId == uuid));

    test('a single undecodable track with no queue: rejected, no queue '
        'started, no click', () async {
      await start(
          reconciled: true, offline: true, sessionId: null, codecs: mp3Only);
      await download('n1', codec: 'flac');
      expect(await actions().addToQueue(await trackScope('n1')),
          isA<RejectedUnplayableOffline>());
      expect(player.activated, isEmpty);
      expect(await db.select(db.queueSessions).get(), isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('a single playable track with no queue starts a queue of it, with '
        'one track click', () async {
      await start(
          reconciled: true, offline: true, sessionId: null, codecs: mp3Only);
      await download('n2', codec: 'mp3');
      expect(await actions().playNext(await trackScope('n2')),
          isA<Accepted>());
      expect(await queued(player.activated.single), ['n2']);
      final recorded = await clicks();
      expect(recorded, hasLength(1));
      expect(recorded.single.$1, 'track');
    });

    // 6-R2-05: the queue that existed at admission vanished (no newer
    // request) while the files were checked.
    test('a queue emptied during the offline file checks: Superseded, no new '
        'queue, no click', () async {
      await start(reconciled: true, offline: true);
      await download('n1');
      await download('n2');
      statGate = Completer<void>();
      final pending = actions().addToQueue(album);
      await pumpEventQueue();
      player.simulateQueueEmptied();
      statGate!.complete();
      expect(await pending, isA<Superseded>());
      expect(player.activated, isEmpty);
      expect(player.enqueued, isEmpty);
      expect(await db.select(db.queueSessions).get(), isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('online with no queue, the whole membership starts the queue',
        () async {
      await start(reconciled: true, sessionId: null, codecs: mp3Only);
      await download('n1', codec: 'flac', onDisk: false);
      expect(await actions().addToQueue(album), isA<Accepted>());
      expect(await queued(player.activated.single), ['n1', 'n2']);
    });
  });
  // Review R1-1 (round 1): the missing-download reconcile is awaited after
  // the file checks; a Stop or a replacement admitted then must still win.
  group('6A.2 review r1: supersession after the issues are reported', () {
    Future<Future<PlaybackOutcome>> enqueueHeldAtIssues() async {
      await start(reconciled: true, offline: true);
      await download('n1', onDisk: false); // a missing file: one issue
      await download('n2');
      player.issuesGate = Completer<void>();
      final pending = actions().addToQueue(album);
      for (var i = 0; i < 20 && player.issues.isEmpty; i++) {
        await pumpEventQueue();
      }
      expect(player.issues, isNotEmpty, reason: 'held while reporting');
      return pending;
    }

    test('a Stop while the missing file is reconciled: nothing starts, '
        'nothing queued, no click', () async {
      final pending = await enqueueHeldAtIssues();
      player.simulateStop();
      player.issuesGate!.complete();
      expect(await pending, isA<Superseded>());
      expect(player.activated, isEmpty, reason: 'no fallback queue after Stop');
      expect(player.enqueued, isEmpty);
      expect(await clicks(), isEmpty);
    });

    test('a replacement admitted while the missing file is reconciled '
        'supersedes the enqueue', () async {
      final pending = await enqueueHeldAtIssues();
      player.admitReplacement();
      player.issuesGate!.complete();
      expect(await pending, isA<Superseded>());
      expect(player.enqueued, isEmpty);
      expect(await clicks(), isEmpty);
    });
  });
}
