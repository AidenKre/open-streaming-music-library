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

void main() {
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
      'lastFetchTime': 123,
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
    expect(container.read(offlineModeProvider), isFalse);
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
}
