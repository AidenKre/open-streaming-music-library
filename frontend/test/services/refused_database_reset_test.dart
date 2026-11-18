// Pre-merge review D3-01 (owner, 2026-11-18): a local database of another
// schema version is refused when it opens, and the reset ("Reset and
// disconnect") must still work on it. Its first step, the fence, cannot write
// to that database: the reset then deletes the database file and its side
// files, opens a fresh one, and goes on with every other step (downloads
// through the owned-file checks, cover art, the recap folder, caches, the
// database, preferences, the stored sign-in, the session log). A reset that
// was killed anywhere on the way ends, on the next launch, in the same clean
// state. These tests use real files and the real reset participants.
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/recap_export_files.dart';
import 'package:frontend/services/recap_export_platform.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/test_credentials.dart';
import '../helpers/test_offline.dart';

class _StillQueuePlayer extends QueuePlayer {
  @override
  AudioState build() => const AudioState();
  @override
  Future<void> quiesce() async {}
}

/// A plain database stamped 8 with one table and one row: an app database
/// written by an earlier build.
class _OtherBuild extends GeneratedDatabase {
  _OtherBuild(super.e);
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
  @override
  int get schemaVersion => 8;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await customStatement('CREATE TABLE old_tracks (title TEXT)');
      await customStatement("INSERT INTO old_tracks VALUES ('old')");
    },
  );
}

Future<void> _writeOtherBuild(File file) async {
  final db = _OtherBuild(NativeDatabase(file));
  await db.customSelect('SELECT 1').get();
  await db.close();
}

/// What a person's device holds before the reset (and what the reset must
/// remove): a download, a stored cover, a shared recap, the session log,
/// settings and the sign-in.
class _Device {
  _Device(this.root);
  final Directory root;

  File get dbFile => File(p.join(root.path, 'support', 'database.db'));
  Directory get support => Directory(p.join(root.path, 'support'));
  Directory get documents => Directory(p.join(root.path, 'documents'));
  Directory get tracks => Directory(p.join(documents.path, 'tracks'));
  Directory get temp => Directory(p.join(root.path, 'tmp'));
  Directory get recap =>
      Directory(p.join(temp.path, RecapExportFiles.folderName));
  final secure = FakeSecureBackend();

  CredentialStore credentials() =>
      CredentialStore(secure: secure, directory: support);
  SessionEventLogFile sessionLog() => SessionEventLogFile(support);

  Future<void> fill({bool tracksDone = false, bool filesDone = false,
      bool prefsDone = false, bool credentialsDone = false}) async {
    support.createSync(recursive: true);
    temp.createSync(recursive: true);
    if (!tracksDone) {
      tracks.createSync(recursive: true);
      File(p.join(tracks.path, 'old-track.m4a')).writeAsBytesSync([1, 2]);
    }
    if (!filesDone) {
      recap.createSync(recursive: true);
      File(p.join(recap.path, 'year.png')).writeAsBytesSync([3]);
      final log = sessionLog();
      await log.append('Database not opened: reason=version_refused');
      await log.idle();
    }
    if (!prefsDone) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('serverUrl', 'http://s');
      await prefs.setString('settings.streamQuality', '320');
    }
    if (!credentialsDone) await credentials().save(testCredentials);
  }

  /// Everything the reset removes is gone; the marker too.
  Future<void> expectClean() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getKeys(), isEmpty, reason: 'settings and the marker');
    expect(await credentials().read(), isNull, reason: 'the sign-in');
    expect(tracks.existsSync(), isFalse, reason: 'the downloads');
    expect(recap.existsSync(), isFalse, reason: 'the shared recap');
    expect(sessionLog().file.existsSync(), isFalse, reason: 'the session log');
  }
}

void main() {
  late Directory root;
  late _Device device;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('osml-refused-reset-');
    device = _Device(root);
  });
  tearDown(() => root.delete(recursive: true));

  /// One launch of the app on [device]: a fresh database connection on its
  /// file, the real reset participants. [open] is the connection setup.
  Future<(ProviderContainer, AppDatabase)> launch({
    QueryExecutor Function(File)? open,
    Credentials? credentials,
  }) async {
    final db = AppDatabase(
      AppDatabaseConnection(() async => device.dbFile, open: open),
    );
    final api = testApiClient(
      'http://s',
      MockClient((_) async => fail('the reset sends no request')),
    );
    final covers = await LocalCoverArtStore.create(
      directoryProvider: () async => device.documents,
      apiClient: api,
    );
    final downloads = DownloadManager(
      apiClient: api,
      db: db,
      coverArtStore: covers,
      directoryProvider: () async => device.documents,
    );
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      apiClientProvider.overrideWithValue(api),
      localCoverArtStoreProvider.overrideWithValue(covers),
      downloadManagerProvider.overrideWithValue(downloads),
      coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
      recapExportPlatformProvider.overrideWithValue(
        NativeRecapExportPlatform(temporaryDirectory: () async => device.temp),
      ),
      queuePlayerProvider.overrideWith(_StillQueuePlayer.new),
      offlineModeProvider.overrideWith(() => TestOffline(false)),
      credentialStoreProvider.overrideWithValue(device.credentials()),
      credentialsProvider.overrideWithValue(credentials),
      sessionEventLogFileProvider.overrideWithValue(device.sessionLog()),
    ]);
    addTearDown(() async {
      c.dispose();
      downloads.dispose();
      await db.close();
    });
    return (c, db);
  }

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version').getSingle())
          .read<int>('user_version');

  for (final (name, QueryExecutor Function(File) open) in [
    ('on the background isolate (as the app)',
        NativeDatabase.createInBackground),
    ('on this isolate', NativeDatabase.new),
  ]) {
    test('$name: Reset deletes the refused file and every other piece of '
        'local data, and the next launch starts at the server address',
        () async {
      await device.fill();
      device.support.createSync(recursive: true);
      await _writeOtherBuild(device.dbFile);
      final (c, db) =
          await launch(open: open, credentials: await device.credentials().read());
      await expectLater(
        c.read(sessionServiceProvider).resumeSavedSession(),
        throwsA(predicate((e) => databaseVersionRefusalIn(e) != null)),
      );

      final failure = await c.read(sessionServiceProvider).resetLocalData();

      expect(failure, isNull, reason: '$failure');
      await device.expectClean();
      expect(await userVersion(db), 1, reason: 'a fresh database');
      final old = await db
          .customSelect("SELECT 1 FROM sqlite_master WHERE name = 'old_tracks'")
          .get();
      expect(old, isEmpty);

      // The next launch: a new connection on the same file.
      final (next, nextDb) = await launch(open: open);
      final start =
          await next.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.serverAddress);
      expect(start.error, isNull);
      expect(await userVersion(nextDb), 1);
    });
  }

  // The whole path through the real controller, on the app's own
  // connection setup (the refusal arrives wrapped from the background
  // isolate): the refusal screen, Reset, then the server-address screen.
  test('the controller: launch shows the refusal; Reset ends at the server '
      'address with nothing to report', () async {
    await device.fill();
    await _writeOtherBuild(device.dbFile);
    final (c, _) = await launch(
      open: NativeDatabase.createInBackground,
      credentials: await device.credentials().read(),
    );
    final controls = c.read(sessionControlsProvider);

    await controls.start();
    expect(controls.phase, SessionPhase.credentialsUnavailable);
    expect(controls.databaseRefused, isTrue);

    await controls.disconnect();
    expect(controls.phase, SessionPhase.resetComplete);
    expect(controls.resetFailure, isNull);
    await controls.acknowledgeReset();
    expect(controls.phase, SessionPhase.serverAddress);
    await device.expectClean();
  });

  // Review R-3: a discard that fails part-way (the folder cannot be
  // written, so the file cannot be deleted) aborts that reset and leaves a
  // working connection: a second Reset in the same run finishes the job, and
  // a third (on the fresh database) is an ordinary reset.
  for (final (name, QueryExecutor Function(File) open) in [
    ('on the background isolate (as the app)',
        NativeDatabase.createInBackground),
    ('on this isolate', NativeDatabase.new),
  ]) {
    test('$name: a discard that fails part-way can be retried in the same run',
        () async {
      await device.fill();
      await _writeOtherBuild(device.dbFile);
      final (c, db) = await launch(
        open: open,
        credentials: await device.credentials().read(),
      );
      final service = c.read(sessionServiceProvider);
      await expectLater(service.resumeSavedSession(), throwsA(anything));

      await Process.run('chmod', ['555', device.support.path]);
      addTearDown(() => Process.run('chmod', ['755', device.support.path]));
      final failed = await service.resetLocalData();
      expect(failed, isNotNull, reason: 'the file could not be deleted');
      expect(device.dbFile.existsSync(), isTrue);
      expect(
          (await SharedPreferences.getInstance())
              .getBool(LocalResetService.resetPendingKey),
          isTrue,
          reason: 'the next launch would finish it');

      await Process.run('chmod', ['755', device.support.path]);
      expect(await service.resetLocalData(), isNull);
      await device.expectClean();
      expect(await userVersion(db), 1);

      expect(await service.resetLocalData(), isNull,
          reason: 'a later reset in the same run is an ordinary one');
      expect(await userVersion(db), 1);
    });
  }

  test('the confirmation sheet cannot count what a refused database holds: '
      'it shows the one uncounted line', () async {
    device.support.createSync(recursive: true);
    await _writeOtherBuild(device.dbFile);
    final (c, _) = await launch();
    expect(await c.read(sessionServiceProvider).pendingLossSummaries(),
        [LocalResetService.uncountedLossSummary]);
  });

  // The app killed during the reset: the marker was saved first, so the next
  // launch finishes the reset whatever had been done; it ends as clean as an
  // uninterrupted reset, and the launch after that starts at the server
  // address.
  for (final (point, dbState, done) in [
    ('after the marker was saved, before the file was deleted', 'refused',
        <String>{}),
    ('after the file was deleted, before a fresh one opened', 'absent',
        <String>{}),
    ('after the fresh file was fenced, before any wipe step', 'fresh',
        <String>{}),
    ('after the downloads step', 'fresh', {'tracks'}),
    ('after the file steps', 'fresh', {'tracks', 'files'}),
    ('after the preferences step', 'fresh', {'tracks', 'files', 'prefs'}),
    ('after every step, before the marker was cleared', 'fresh',
        {'tracks', 'files', 'prefs', 'credentials'}),
  ]) {
    test('killed $point: the next launch ends in the same clean state',
        () async {
      await device.fill(
        tracksDone: done.contains('tracks'),
        filesDone: done.contains('files'),
        prefsDone: done.contains('prefs'),
        credentialsDone: done.contains('credentials'),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(LocalResetService.resetPendingKey, true);
      switch (dbState) {
        case 'refused':
          await _writeOtherBuild(device.dbFile);
        case 'fresh':
          final fresh = AppDatabase(NativeDatabase(device.dbFile));
          await fresh.customSelect('SELECT 1').get();
          await fresh.close();
      }

      final (c, db) = await launch(open: NativeDatabase.createInBackground);
      final start = await c.read(sessionServiceProvider).resumeSavedSession();

      expect(start.kind, SessionStartKind.resetFinished);
      await device.expectClean();
      expect(await userVersion(db), 1);

      final (next, _) = await launch(open: NativeDatabase.createInBackground);
      final again =
          await next.read(sessionServiceProvider).resumeSavedSession();
      expect(again.kind, SessionStartKind.serverAddress);
      expect(again.error, isNull);
    });
  }
}
