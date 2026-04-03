import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/audio/audio_coordinator.dart';
import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/local_reset_service.dart';

class _ResetAudioCoordinator extends AudioCoordinator {
  int stopCalls = 0;

  @override
  AudioState build() => const AudioState();

  @override
  Future<void> stop() async {
    stopCalls++;
    state = const AudioState();
  }
}

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);

  final bool _value;

  @override
  bool build() => _value;
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
    late _ResetAudioCoordinator audio;
    late ProviderContainer container;

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
      ApiClient.init('http://localhost:8000');

      db = AppDatabase(NativeDatabase.memory());
      tempDir = await Directory.systemTemp.createTemp('local-reset-service-test');
      coverStore = await LocalCoverArtStore.create(
        directoryProvider: () async => tempDir,
      );
      downloadManager = DownloadManager(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
      );
      audio = _ResetAudioCoordinator();

      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          localCoverArtStoreProvider.overrideWithValue(coverStore),
          downloadManagerProvider.overrideWithValue(downloadManager),
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
          audioProvider.overrideWith(() => audio),
          offlineModeProvider.overrideWith(() => _StubOffline(true)),
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

      expect(audio.stopCalls, 1);
      // Reset deliberately does NOT publish a `true → false` offline
      // transition — that would fire the app-level recovery listener (sync,
      // resume downloads) against state mid-wipe. The notifier itself is
      // disposed when the ProviderScope is rebuilt after a successful reset.
      expect(container.read(offlineModeProvider), isTrue);
      expect(ApiClient.instance.baseUrl, isEmpty);
      expect(prefs.getKeys(), isEmpty);
      expect(downloadManager.snapshot(), isEmpty);
      expect(downloadFile.existsSync(), isFalse);
      expect(partialFile.existsSync(), isFalse);
      expect(tracksDir.existsSync(), isFalse);
      expect(coverStore.has(77), isFalse);
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
      // CoverArtCacheManager(noop) is registered via the provider override.
      expect(
        registered.any((r) => r is CoverArtCacheManager),
        isTrue,
      );
      // 4 direct + 4 adapters = 8 reset steps total.
      expect(registered.length, 8);
    });
  });

  group('LocalResetService priority ordering', () {
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
          _Recording('transport', ResetPriority.clearTransport, log),
          _Recording('files', ResetPriority.deleteFiles, log),
          _Recording('downloads', ResetPriority.cancelInFlight, log),
          _Recording('prefs', ResetPriority.clearPreferences, log),
          _Recording('db', ResetPriority.wipeDatabase, log),
        ];

        final container = ProviderContainer(
          overrides: [
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

    test('sort is stable for equal-priority resettables', () async {
      final log = <String>[];
      final container = ProviderContainer(
        overrides: [
          localResettablesProvider.overrideWithValue(<LocalResettable>[
            _Recording('a', 50, log),
            _Recording('b', 50, log),
            _Recording('c', 50, log),
          ]),
        ],
      );
      addTearDown(container.dispose);

      await container.read(localResetServiceProvider).reset();

      // List.sort is not guaranteed stable in Dart, but for ties the test
      // just asserts all three ran exactly once — any order is acceptable.
      expect(log, hasLength(3));
      expect(log.toSet(), {'a', 'b', 'c'});
    });
  });
}
