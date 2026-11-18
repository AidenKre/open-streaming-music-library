import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/download/track_downloader.dart'
    show DownloadsLeftByReset;
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/recap_export_files.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/session_event_log.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/test_credentials.dart';
import '../helpers/test_offline.dart';

class _ResetQueuePlayer extends QueuePlayer {
  int stopCalls = 0;
  int quiesceCalls = 0;

  @override
  AudioState build() => const AudioState();

  @override
  Future<void> stop() async {
    stopCalls++;
    state = const AudioState();
  }

  @override
  Future<void> quiesce() async => quiesceCalls++;
}

/// Records the order in which it was reset. Used to verify the
/// priority-sorted invocation contract.
class _Recording implements LocalResettable {
  _Recording(this.label, this.priority, this.log);

  final String label;
  final int priority;
  final List<String> log;

  @override
  int get resetPriority => priority;

  @override
  Future<void> resetLocalState() async {
    log.add(label);
  }
}

/// Throws on reset to verify per-resettable try/catch isolation.
class _Throwing implements LocalResettable {
  _Throwing(this.priority, this.log);

  final int priority;
  final List<String> log;

  @override
  int get resetPriority => priority;

  @override
  Future<void> resetLocalState() async {
    log.add('threw');
    throw StateError('boom');
  }
}

void main() {
  group('LocalResetService end-to-end', () {
    late AppDatabase db;
    late Directory tempDir;
    late LocalCoverArtStore coverStore;
    late DownloadManager downloadManager;
    late SharedPreferences prefs;
    late _ResetQueuePlayer audio;
    late ProviderContainer container;
    late FakeSecureBackend secure;
    late CredentialStore credentials;
    late SessionEventLogFile sessionLog;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'serverUrl': 'http://localhost:8000',
        'settings.streamQuality': '320',
        'settings.downloadQuality': '128',
        'lastRevision': 123,
        'audioVolume': 0.42,
        'future.key': 'also removed',
      });
      prefs = await SharedPreferences.getInstance();

      db = AppDatabase(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp('local-reset-service-test');
      final api = testApiClient(
        'http://localhost:8000',
        MockClient((_) async => fail('the reset test makes no requests')),
      );
      coverStore = await LocalCoverArtStore.create(
        directoryProvider: () async => tempDir,
        apiClient: api,
      );
      downloadManager = DownloadManager(
        apiClient: api,
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
      );
      audio = _ResetQueuePlayer();
      secure = FakeSecureBackend();
      credentials = CredentialStore(
        secure: secure,
        directory: Directory(p.join(tempDir.path, 'app-support')),
      );
      await credentials.save(testCredentials);
      // Sign-off s7-app-texts item 2: the session log lives next to the
      // credential fallback file, in the app's support folder.
      sessionLog = SessionEventLogFile(
        Directory(p.join(tempDir.path, 'app-support')),
      );
      await sessionLog.append('Stored sign-in dropped at launch: reason=x');

      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          localCoverArtStoreProvider.overrideWithValue(coverStore),
          downloadManagerProvider.overrideWithValue(downloadManager),
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
          queuePlayerProvider.overrideWith(() => audio),
          offlineModeProvider.overrideWith(() => TestOffline(true)),
          credentialStoreProvider.overrideWithValue(credentials),
          sessionEventLogFileProvider.overrideWithValue(sessionLog),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      downloadManager.dispose();
      await db.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('reset returns the frontend to local first-run state', () async {
      final tracksDir = Directory(p.join(tempDir.path, 'tracks'));
      await tracksDir.create(recursive: true);
      final downloadFile = File(p.join(tracksDir.path, 'reset-track.m4a'));
      await downloadFile.writeAsBytes([1, 2, 3]);
      final partialFile = File(p.join(tracksDir.path, 'partial.m4a.partial'));
      await partialFile.writeAsBytes([4, 5, 6]);
      await coverStore.fileFor(77).writeAsBytes([9]);

      await db.customStatement(
        "INSERT INTO artists (id, name) VALUES (1, 'Reset Artist')",
      );
      await db.customStatement(
        "INSERT INTO tracks "
        "(uuid_id, created_at, last_updated, file_path) "
        "VALUES ('reset-track', 1, 2, ?)",
        [downloadFile.path],
      );
      await db.customStatement(
        "INSERT INTO trackmetadata "
        "(uuid_id, title, duration, bitrate_kbps, sample_rate_hz, channels, "
        "has_album_art, cover_art_id) "
        "VALUES ('reset-track', 'Reset Song', 120, 320, 44100, 2, 1, 77)",
      );
      await db.customStatement(
        "INSERT INTO fts_tracks "
        "(rowid, title, artist_name, album_name) "
        "VALUES (1, 'Reset Song', 'Reset Artist', '')",
      );

      container.read(offlineModeProvider.notifier).enterOffline();
      expect(container.read(offlineModeProvider), isTrue);

      await container.read(localResetServiceProvider).reset();

      // SC-15: playback is quiesced (the first participant), not wiped.
      expect(audio.quiesceCalls, 1);
      expect(audio.stopCalls, 0);
      // Reset deliberately does NOT publish a `true → false` offline
      // transition — that would fire the app-level recovery listener (sync,
      // resume downloads) against state mid-wipe. The notifier itself is
      // disposed when the ProviderScope is rebuilt after a successful reset.
      expect(container.read(offlineModeProvider), isTrue);
      expect(prefs.getKeys(), isEmpty);
      expect(downloadManager.snapshot(), isEmpty);
      expect(downloadFile.existsSync(), isFalse);
      expect(partialFile.existsSync(), isFalse);
      expect(tracksDir.existsSync(), isFalse);
      expect(coverStore.has(77), isFalse);
      expect(sessionLog.file.existsSync(), isFalse,
          reason: 'the session log is local state too');
      expect(await db.select(db.tracks).get(), isEmpty);
      expect(await db.select(db.trackmetadata).get(), isEmpty);
      expect(await db.select(db.artists).get(), isEmpty);

      final ftsRows = await db
          .customSelect(
            "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH '\"Reset\"*'",
          )
          .get();
      expect(ftsRows, isEmpty);
    });

    // The reset deletes downloads only through the owned-file clean-up's
    // checks (the owner, 2026-11-17; option A). A recorded file outside the
    // downloads folder is left, the reset says so once, and the next launch
    // finishes the reset: the database wipe removed the row, so nothing is
    // found again and connecting works (no loop).
    test('a downloaded file outside the downloads folder is left, reported '
        'once, and the next launch finishes the reset', () async {
      final outside = Directory(p.join(tempDir.path, 'elsewhere'))
        ..createSync();
      final file = File(p.join(outside.path, 'kept.m4a'))
        ..writeAsBytesSync([4, 2]);
      await db.customStatement(
        "INSERT INTO tracks (uuid_id, created_at, last_updated, file_path) "
        "VALUES ('kept', 1, 2, ?)",
        [file.path],
      );
      final service = container.read(localResetServiceProvider);

      final failure = await service.reset().then<Object?>(
            (_) => null,
            onError: (Object e) => e,
          );

      expect(failure, isA<LocalResetException>());
      final failures = (failure! as LocalResetException).failures;
      expect(failures.map((f) => f.participant), [downloadManager]);
      expect(failures.single.error, isA<DownloadsLeftByReset>());
      expect((failure as LocalResetException).wipeFailed, isTrue);
      expect(file.readAsBytesSync(), [4, 2]);
      expect(await db.select(db.tracks).get(), isEmpty);
      expect(await service.hasPendingReset(), isTrue);

      await service.completePendingReset();

      expect(await service.hasPendingReset(), isFalse);
      expect(file.readAsBytesSync(), [4, 2]);
    });

    test(
      'reset while offline does not publish a true→false offline transition',
      () async {
        // A `true → false` transition is the signal the app-level recovery
        // listener uses to kick off sync + resume-downloads. During reset
        // that signal is a lie — the URL, prefs, DB, and downloads are all
        // being wiped. So reset must not produce that transition.
        container.read(offlineModeProvider.notifier).enterOffline();
        expect(container.read(offlineModeProvider), isTrue);

        final transitions = <(bool, bool)>[];
        container.listen<bool>(offlineModeProvider, (prev, next) {
          transitions.add((prev ?? false, next));
        }, fireImmediately: false);

        await container.read(localResetServiceProvider).reset();

        final recoveryTransitions = transitions
            .where((t) => t.$1 == true && t.$2 == false)
            .toList();
        expect(
          recoveryTransitions,
          isEmpty,
          reason: 'reset must not look like a normal offline→online recovery',
        );
      },
    );

    test('default registry advertises the expected real subsystems', () {
      final registered = container.read(localResettablesProvider);
      // Identity check the four direct implementors — the other entries are
      // adapter classes private to local_reset_service.dart.
      expect(registered, contains(same(downloadManager)));
      expect(registered, contains(same(coverStore)));
      expect(registered, contains(same(db)));
      expect(registered, contains(same(credentials)));
      expect(registered, contains(same(sessionLog)));
      // CoverArtCacheManager(noop) is registered via the provider override.
      expect(
        registered.any((r) => r is CoverArtCacheManager),
        isTrue,
      );
      // 5 direct + 2 adapters = 7 reset steps total (playback is a quiesce
      // participant, not a wipe step; the transport URL is no longer a step:
      // the scope rebuild after the reset replaces the client, Phase M §7.2;
      // the credential store is a wipe participant, SC-15 Phase M; the
      // session log file is one when the app gives it, s7-app-texts).
      // Pre-merge review C2-03: the recap export folder is a wipe step.
      expect(registered.any((r) => r is RecapExportFiles), isTrue);
      expect(registered.length, 9);
    });

    // SC-15 Phase M amendment (M-U19 store): the credential store is a wipe
    // participant: a reset deletes the stored credentials, secure storage
    // and fallback file alike.
    test('reset deletes the stored credentials', () async {
      expect(await credentials.read(), testCredentials);
      await container.read(localResetServiceProvider).reset();
      expect(secure.values, isEmpty);
      expect(await credentials.read(), isNull);
    });

    test('a credential wipe that fails is reported, and the other steps '
        'still run', () async {
      // Neither the secure delete nor the signed-out marker can be written
      // (review r1 finding 1: a failed secure delete alone is covered by the
      // marker file).
      secure.deleteError = StateError('keychain locked');
      final blocker = File(p.join(tempDir.path, 'not-a-directory'));
      await blocker.writeAsString('x');
      credentials = CredentialStore(secure: secure, directory: Directory(blocker.path));
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWith((_) async => prefs),
        localCoverArtStoreProvider.overrideWithValue(coverStore),
        downloadManagerProvider.overrideWithValue(downloadManager),
        coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        queuePlayerProvider.overrideWith(() => audio),
        offlineModeProvider.overrideWith(() => TestOffline(true)),
        credentialStoreProvider.overrideWithValue(credentials),
      ]);
      addTearDown(c.dispose);
      final error = await c
          .read(localResetServiceProvider)
          .reset()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<LocalResetException>());
      final failures = (error! as LocalResetException).failures;
      expect(failures.map((f) => f.participant), [same(credentials)]);
      expect(await db.select(db.tracks).get(), isEmpty);
    });

    // U22-FE-LIFECYCLE-A-11: the real preferences step (registered by
    // default), not a hand copy: it keeps the pending-reset marker for the
    // end of the wipe, and a key it cannot remove fails the step.
    test('the preferences step keeps the reset marker and fails on a key it '
        'cannot remove', () async {
      final refusing = _RefusingRemovePrefs(prefs, refuse: 'audioVolume');
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWith((_) async => refusing),
        localCoverArtStoreProvider.overrideWithValue(coverStore),
        downloadManagerProvider.overrideWithValue(downloadManager),
        coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        queuePlayerProvider.overrideWith(() => audio),
        offlineModeProvider.overrideWith(() => TestOffline(true)),
        credentialStoreProvider.overrideWithValue(credentials),
      ]);
      addTearDown(c.dispose);
      final error = await c
          .read(localResetServiceProvider)
          .reset()
          .then<Object?>((_) => null, onError: (Object e) => e);
      final failures = (error! as LocalResetException).failures;
      expect(failures, hasLength(1));
      expect(failures.single.quiesce, isFalse);
      expect('${failures.single.error}', contains('"audioVolume"'));
      expect(refusing.removed, isNot(contains(LocalResetService.resetPendingKey)),
          reason: 'the step skips the marker; a failed wipe keeps it');
      expect(prefs.getBool(LocalResetService.resetPendingKey), isTrue);
      expect(prefs.containsKey('audioVolume'), isTrue);
    });

    test('a clean wipe: the preferences step leaves the reset marker; only '
        'the end of the wipe removes it', () async {
      final recording = _RefusingRemovePrefs(prefs, refuse: '');
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWith((_) async => recording),
        localCoverArtStoreProvider.overrideWithValue(coverStore),
        downloadManagerProvider.overrideWithValue(downloadManager),
        coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        queuePlayerProvider.overrideWith(() => audio),
        offlineModeProvider.overrideWith(() => TestOffline(true)),
        credentialStoreProvider.overrideWithValue(credentials),
      ]);
      addTearDown(c.dispose);
      await c.read(localResetServiceProvider).reset();
      expect(
          recording.removed
              .where((k) => k == LocalResetService.resetPendingKey),
          hasLength(1));
      expect(recording.removed.last, LocalResetService.resetPendingKey);
      expect(prefs.getKeys(), isEmpty);
    });
  });

  // Review major 2 (user, 2026-11-09): a durable marker makes an interrupted
  // or failed reset finish before anything binds.
  group('the pending-reset marker', () {
    late AppDatabase markerDb;
    late SharedPreferences markerPrefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({'serverUrl': 'http://a'});
      markerPrefs = await SharedPreferences.getInstance();
      markerDb = AppDatabase(NativeDatabase.memory());
    });
    tearDown(() => markerDb.close());

    ProviderContainer containerWith(List<LocalResettable> registry,
        {List<Quiescable> quiescables = const [],
        ServerBindingRepository? bindings}) {
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(markerDb),
        sharedPreferencesProvider.overrideWith((_) async => markerPrefs),
        localQuiescablesProvider.overrideWithValue(quiescables),
        localResettablesProvider.overrideWithValue(registry),
        if (bindings != null)
          serverBindingRepositoryProvider.overrideWithValue(bindings),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test('is set before the fence, survives the wipe, and is cleared once '
        'every step succeeded', () async {
      final seen = <bool?>[];
      final c = containerWith([
        _Probe(() => seen.add(markerPrefs.getBool('resetPending'))),
        _PrefsWipe(markerPrefs),
        _Probe(() => seen.add(markerPrefs.getBool('resetPending'))),
      ]);
      await c.read(localResetServiceProvider).reset();
      expect(seen, [true, true], reason: 'set during the whole wipe');
      expect(markerPrefs.getBool('resetPending'), isNull);
      expect(await c.read(localResetServiceProvider).hasPendingReset(),
          isFalse);
    });

    test('a failed wipe step keeps it', () async {
      final c = containerWith([_Throwing(10, [])]);
      await expectLater(c.read(localResetServiceProvider).reset(),
          throwsA(isA<LocalResetException>()));
      expect(await c.read(localResetServiceProvider).hasPendingReset(),
          isTrue);
    });

    // Pre-merge review D5-02: the marker is what makes the next launch
    // finish an interrupted wipe. A reset that could not save it stops
    // before the fence: nothing is quiesced, fenced or wiped.
    test('a marker that cannot be saved aborts before the fence; nothing is '
        'wiped', () async {
      final log = <String>[];
      final quiesce = _CountingQuiescable();
      final refusing = _RefusingMarkerPrefs(markerPrefs);
      final c = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(markerDb),
        sharedPreferencesProvider.overrideWith((_) async => refusing),
        localQuiescablesProvider.overrideWithValue([quiesce]),
        localResettablesProvider
            .overrideWithValue([_Recording('wipe', 10, log)]),
      ]);
      addTearDown(c.dispose);
      await c.read(serverBindingRepositoryProvider).ensureProvisional('http://a');

      await expectLater(c.read(localResetServiceProvider).reset(),
          throwsA(isA<LocalResetAbortedException>()));

      expect(refusing.refusedMarker, isTrue, reason: 'the save was asked');
      expect(log, isEmpty, reason: 'nothing is wiped');
      expect(quiesce.calls, 0, reason: 'nothing is quiesced');
      expect(await c.read(serverBindingRepositoryProvider).current(), isNotNull,
          reason: 'not fenced');
      expect(markerPrefs.getString('serverUrl'), 'http://a');
    });

    test('a fence that fails aborts with the marker kept', () async {
      final c = containerWith([], bindings: _FailingFence(markerDb));
      await expectLater(c.read(localResetServiceProvider).reset(),
          throwsA(isA<LocalResetAbortedException>()));
      expect(markerPrefs.getBool('resetPending'), isTrue);
    });

    test('completePendingReset fences and wipes without quiescing, then '
        'clears it', () async {
      final log = <String>[];
      final quiesce = _CountingQuiescable();
      final c = containerWith([_Recording('wipe', 10, log)],
          quiescables: [quiesce]);
      await markerPrefs.setBool('resetPending', true);
      await c.read(serverBindingRepositoryProvider).ensureProvisional('http://a');
      await c.read(localResetServiceProvider).completePendingReset();
      expect(log, ['wipe']);
      expect(quiesce.calls, 0);
      expect(await c.read(serverBindingRepositoryProvider).current(), isNull);
      expect(markerPrefs.getBool('resetPending'), isNull);
    });

    test('a completion whose wipe fails keeps it', () async {
      final c = containerWith([_Throwing(10, [])]);
      await markerPrefs.setBool('resetPending', true);
      await expectLater(c.read(localResetServiceProvider).completePendingReset(),
          throwsA(isA<LocalResetException>()));
      expect(markerPrefs.getBool('resetPending'), isTrue);
    });
  });

  group('LocalResetService priority ordering', () {
    // SC-15: every reset fences first (deletes the binding row), so each
    // container needs a database even when the wipe steps are fakes; no
    // quiesce participants (these tests are about the wipe bands).
    late AppDatabase orderDb;
    setUp(() => orderDb = AppDatabase(NativeDatabase.memory()));
    tearDown(() => orderDb.close());

    test(
      'runs resettables in strict descending priority order regardless of '
      'registration order',
      () async {
        final log = <String>[];
        // Deliberately shuffle insertion order so a naive iteration would
        // produce a different order than the priority sort.
        final registry = <LocalResettable>[
          _Recording('caches', ResetPriority.clearCaches, log),
          _Recording('audio', ResetPriority.stopBackgroundWork, log),
          _Recording('transport', 0, log),
          _Recording('files', ResetPriority.deleteFiles, log),
          _Recording('downloads', ResetPriority.cancelInFlight, log),
          _Recording('prefs', ResetPriority.clearPreferences, log),
          _Recording('db', ResetPriority.wipeDatabase, log),
        ];

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(orderDb),
            localQuiescablesProvider.overrideWithValue(const []),
            localResettablesProvider.overrideWithValue(registry),
          ],
        );
        addTearDown(container.dispose);

        await container.read(localResetServiceProvider).reset();

        expect(log, <String>[
          'audio', // 100
          'downloads', // 80
          'files', // 60
          'caches', // 40
          'db', // 20
          'prefs', // 10
          'transport', // 0
        ]);
      },
    );

    test(
      'one failing resettable does not abort the rest, but reset surfaces '
      'the failure as a LocalResetException',
      () async {
        final log = <String>[];
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(orderDb),
            localQuiescablesProvider.overrideWithValue(const []),
            localResettablesProvider.overrideWithValue(<LocalResettable>[
              _Recording('first', 100, log),
              _Throwing(50, log),
              _Recording('last', 10, log),
            ]),
          ],
        );
        addTearDown(container.dispose);

        Object? thrown;
        try {
          await container.read(localResetServiceProvider).reset();
        } catch (e) {
          thrown = e;
        }

        // Every step still ran.
        expect(log, ['first', 'threw', 'last']);
        // And the partial-reset condition was surfaced, not swallowed.
        expect(thrown, isA<LocalResetException>());
        final ex = thrown as LocalResetException;
        expect(ex.failures, hasLength(1));
        expect(ex.failures.single.error, isA<StateError>());
      },
    );

    test(
      'multiple failing resettables are reported in one aggregate exception',
      () async {
        final log = <String>[];
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(orderDb),
            localQuiescablesProvider.overrideWithValue(const []),
            localResettablesProvider.overrideWithValue(<LocalResettable>[
              _Throwing(100, log),
              _Recording('middle', 50, log),
              _Throwing(10, log),
            ]),
          ],
        );
        addTearDown(container.dispose);

        Object? thrown;
        try {
          await container.read(localResetServiceProvider).reset();
        } catch (e) {
          thrown = e;
        }

        expect(log, ['threw', 'middle', 'threw']);
        expect(thrown, isA<LocalResetException>());
        expect((thrown as LocalResetException).failures, hasLength(2));
      },
    );

    test(
      'reset completes normally (no throw) when every step succeeds',
      () async {
        final log = <String>[];
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(orderDb),
            localQuiescablesProvider.overrideWithValue(const []),
            localResettablesProvider.overrideWithValue(<LocalResettable>[
              _Recording('a', 100, log),
              _Recording('b', 50, log),
            ]),
          ],
        );
        addTearDown(container.dispose);

        await container.read(localResetServiceProvider).reset();

        expect(log, ['a', 'b']);
      },
    );

    test('equal-priority resettables each run exactly once', () async {
      final log = <String>[];
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(orderDb),
          localQuiescablesProvider.overrideWithValue(const []),
          localResettablesProvider.overrideWithValue(<LocalResettable>[
            _Recording('a', 50, log),
            _Recording('b', 50, log),
            _Recording('c', 50, log),
          ]),
        ],
      );
      addTearDown(container.dispose);

      await container.read(localResetServiceProvider).reset();

      // List.sort is not guaranteed stable in Dart: for ties any order is
      // acceptable, so the test asserts only that all three ran once.
      expect(log, hasLength(3));
      expect(log.toSet(), {'a', 'b', 'c'});
    });
  });

  // U22-FE-LIFECYCLE-A-05: the default quiet order (SC-15), read from the
  // real wiring. Building the list builds no participant's subsystem.
  test('the default quiesce participants, in order', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(localQuiescablesProvider).map((q) => q.quiesceName), [
      'playback',
      'queue-warm',
      'listens',
      'preview',
      'history',
      'uploads',
      'delete-jobs',
      'owned-file-cleanup',
      'submissions',
    ]);
  });

  // Other-issues row 71 (SC-15): the warm-up's debounce timers are quieted
  // right after playback, so no warm-up request leaves during or after the
  // wipe. The timer is a fake one (testWidgets); the reset runs for real.
  testWidgets('a warm-up scheduled before a reset sends nothing after the '
      'quiet step', (tester) async {
    var requests = 0;
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async {
        requests++;
        return http.Response('', 204);
      }),
    );
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final warm = QueueWarmService(
      queueRepo: _NoQueueRead(),
      apiClient: api,
    );
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      queuePlayerProvider.overrideWith(_ResetQueuePlayer.new),
      offlineModeProvider.overrideWith(() => TestOffline(true)),
      queueWarmServiceProvider.overrideWithValue(warm),
      localResettablesProvider.overrideWithValue(const []),
    ]);
    c.read(queueWarmServiceProvider);
    // The warm-up is built here with no offline check of its own; the
    // stubbed offline flag only keeps the reset from taking a revoker.
    warm.scheduleWarmUuids(['dl-1'], quality: '320');
    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(() => c.read(localResetServiceProvider).reset());
    await tester.pump(const Duration(milliseconds: 700));
    expect(requests, 0);

    warm.scheduleWarmUuids(['dl-2'], quality: '320');
    await tester.pump(const Duration(milliseconds: 700));
    expect(requests, 0, reason: 'no timer starts once quieted');

    c.dispose();
    warm.dispose();
    await tester.runAsync(db.close);
  });

  test('quieting the warm-up never builds it', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c
        .read(localQuiescablesProvider)
        .singleWhere((q) => q.quiesceName == 'queue-warm')
        .quiesce();
    expect(c.exists(queueWarmServiceProvider), isFalse);
  });

  group('LocalResetException', () {
    LocalResetFailure q() => LocalResetFailure(
          String, StateError('x'), StackTrace.empty,
          quiesce: true);
    LocalResetFailure w([Object? participant]) => LocalResetFailure(
          String, StateError('x'), StackTrace.empty,
          participant: participant);

    test('empty list: quiesce only, nothing kept', () {
      final e = LocalResetException([]);
      expect(e.quiesceOnly, isTrue);
      expect(e.wipeFailed, isFalse);
      expect(e.databaseKept, isFalse);
    });

    test('only quiesce failures', () {
      final e = LocalResetException([q(), q()]);
      expect(e.quiesceOnly, isTrue);
      expect(e.wipeFailed, isFalse);
      expect(e.databaseKept, isFalse);
    });

    test('a quiesce failure plus a non-quiesce one', () {
      final e = LocalResetException([q(), w(3)]);
      expect(e.quiesceOnly, isFalse);
      expect(e.wipeFailed, isTrue);
      expect(e.databaseKept, isFalse);
    });

    test('a database participant means the database was kept', () {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final e = LocalResetException([w(db)]);
      expect(e.databaseKept, isTrue);
      expect(e.wipeFailed, isTrue);
    });

    test('a non-quiesce failure of another participant keeps no database', () {
      final e = LocalResetException([w(3)]);
      expect(e.wipeFailed, isTrue);
      expect(e.databaseKept, isFalse);
    });
  });
}

class _Probe implements LocalResettable {
  _Probe(this.onReset);
  final void Function() onReset;
  @override
  int get resetPriority => ResetPriority.wipeDatabase;
  @override
  Future<void> resetLocalState() async => onReset();
}

/// The production prefs wipe's contract: everything but the marker.
class _PrefsWipe implements LocalResettable {
  _PrefsWipe(this.prefs);
  final SharedPreferences prefs;
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async {
    for (final key in prefs.getKeys().toList()) {
      if (key != LocalResetService.resetPendingKey) await prefs.remove(key);
    }
  }
}

class _CountingQuiescable implements Quiescable {
  int calls = 0;
  @override
  String get quiesceName => 'counting';
  @override
  Future<void> quiesce() async => calls++;
}

class _FailingFence extends ServerBindingRepository {
  _FailingFence(super.db);
  @override
  Future<void> fence() async => throw StateError('disk full');
}

/// The real preferences, except that removing [refuse] is refused (the
/// platform answers false). Records every key asked to be removed.
class _RefusingRemovePrefs implements SharedPreferences {
  _RefusingRemovePrefs(this._real, {required this.refuse});
  final SharedPreferences _real;
  final String refuse;
  final removed = <String>[];
  @override
  bool? getBool(String key) => _real.getBool(key);
  @override
  Future<bool> setBool(String key, bool value) => _real.setBool(key, value);
  @override
  String? getString(String key) => _real.getString(key);
  @override
  Set<String> getKeys() => _real.getKeys();
  @override
  Future<bool> remove(String key) async {
    removed.add(key);
    return key == refuse ? false : _real.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The real preferences, except that saving the reset marker is refused
/// (the platform answers false).
class _RefusingMarkerPrefs implements SharedPreferences {
  _RefusingMarkerPrefs(this._real);
  final SharedPreferences _real;
  bool refusedMarker = false;
  @override
  bool? getBool(String key) => _real.getBool(key);
  @override
  Future<bool> setBool(String key, bool value) async {
    if (key == LocalResetService.resetPendingKey) {
      refusedMarker = true;
      return false;
    }
    return _real.setBool(key, value);
  }

  @override
  String? getString(String key) => _real.getString(key);
  @override
  Set<String> getKeys() => _real.getKeys();
  @override
  Future<bool> remove(String key) => _real.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The warm-up's queue: never read by the download-driven warm-up.
class _NoQueueRead implements QueueRepository {
  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
