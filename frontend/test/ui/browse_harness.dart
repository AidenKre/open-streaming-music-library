import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_coordinator.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';

/// Shared fixtures for the root browse-page (filter chip + in-page search)
/// widget tests. Everything runs against a real in-memory drift DB with FTS
/// rebuilt; only network/audio-bound providers are replaced.

/// One track to seed. Artists/albums are derived (and de-duplicated) from it.
class SeedTrack {
  const SeedTrack({
    required this.uuid,
    required this.title,
    required this.artistId,
    required this.artist,
    this.albumId,
    this.album,
    this.downloaded = false,
    this.trackNumber = 1,
  });

  final String uuid;
  final String title;
  final int artistId;
  final String artist;
  final int? albumId;
  final String? album;
  final bool downloaded;
  final int trackNumber;
}

Future<void> seedLibrary(AppDatabase db, List<SeedTrack> tracks) async {
  final artists = <int, String>{};
  final albums = <int, (String, int)>{};
  for (final t in tracks) {
    artists[t.artistId] = t.artist;
    if (t.albumId != null) albums[t.albumId!] = (t.album ?? '', t.artistId);
  }
  await db.batch((batch) {
    for (final e in artists.entries) {
      batch.insert(
        db.artists,
        ArtistsCompanion(id: Value(e.key), name: Value(e.value)),
      );
    }
    for (final e in albums.entries) {
      batch.insert(
        db.albums,
        AlbumsCompanion(
          id: Value(e.key),
          name: Value(e.value.$1),
          artistId: Value(e.value.$2),
          isSingleGrouping: const Value(false),
        ),
      );
    }
  });
  for (final t in tracks) {
    final dto = ClientTrackDto.fromJson({
      'uuid_id': t.uuid,
      'created_at': 1000,
      'last_updated': 1000,
      'revision': 1,
      'metadata': {
        'title': t.title,
        'artist': t.artist,
        'album': t.album,
        'album_artist': t.artist,
        'artist_id': t.artistId,
        'album_id': t.albumId,
        'track_number': t.trackNumber,
        'disc_number': 1,
        'codec': 'flac',
        'duration': 60.0,
        'bitrate_kbps': 900.0,
        'sample_rate_hz': 44100,
        'channels': 2,
        'has_album_art': false,
      },
    });
    await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
    await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
    if (t.downloaded) await markDownloaded(db, t.uuid);
  }
  await db.rebuildFtsIndexes();
}

Future<void> markDownloaded(AppDatabase db, String uuid) async {
  await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
    TracksCompanion(
      filePath: Value('/downloads/$uuid.flac'),
      downloadedAtRevision: const Value(1),
    ),
  );
}

/// Offline flag the test can flip mid-test via [set], without the real
/// health-poll timer.
class TestOffline extends OfflineModeNotifier {
  TestOffline(this.initial);
  final bool initial;

  @override
  bool build() => initial;

  void set(bool value) => state = value;
}

class StubTrackSync extends TrackSyncNotifier {
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {}
}

class EmptyConversionJobs extends ConversionJobsNotifier {
  @override
  List<ConversionJob> build() => const [];
}

/// Records play calls instead of driving the real audio stack.
class RecordingAudio extends AudioCoordinator {
  final List<Map<String, Object?>> calls = [];

  @override
  AudioState build() => const AudioState();

  @override
  Future<void> playFromQueue({
    required TrackUI track,
    required String sourceType,
    int? artistId,
    int? albumId,
    List<OrderParameter> orderParams = const [],
    bool downloadedOnly = false,
  }) async {
    calls.add({
      'method': 'playFromQueue',
      'uuid': track.uuidId,
      'sourceType': sourceType,
      'downloadedOnly': downloadedOnly,
    });
  }

  @override
  Future<void> playFromTrackList(
    List<String> uuids,
    TrackUI startTrack, {
    required String sourceType,
  }) async {
    calls.add({
      'method': 'playFromTrackList',
      'uuids': uuids,
      'uuid': startTrack.uuidId,
      'sourceType': sourceType,
    });
  }
}

/// Builds the provider scope used by the browse-page tests. Holds the real
/// [DownloadManager] (on a temp dir) so tests can delete a download through
/// the production path, which bumps `downloadStatusVersionProvider`.
class BrowseHarness {
  BrowseHarness._(this.db, this.tempDir, this.coverStore, this.manager);

  final AppDatabase db;
  final Directory tempDir;
  final LocalCoverArtStore coverStore;
  final DownloadManager manager;
  final audio = RecordingAudio();
  late TestOffline offline;

  static Future<BrowseHarness> create(AppDatabase db) async {
    final tempDir = await Directory.systemTemp.createTemp('browse-harness');
    final coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
    final manager = DownloadManager(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
    );
    return BrowseHarness._(db, tempDir, coverStore, manager);
  }

  Future<void> dispose() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }

  Widget wrap(Widget child, {bool offline = false}) {
    this.offline = TestOffline(offline);
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        localCoverArtStoreProvider.overrideWithValue(coverStore),
        downloadManagerProvider.overrideWithValue(manager),
        offlineModeProvider.overrideWith(() => this.offline),
        trackSyncProvider.overrideWith(StubTrackSync.new),
        appInfoProvider.overrideWith((ref) async => const AppInfo()),
        conversionJobsProvider.overrideWith(EmptyConversionJobs.new),
        audioProvider.overrideWith(() => audio),
      ],
      child: MaterialApp(home: child),
    );
  }
}

/// Unmounting a page cancels a drift stream subscription, which schedules a
/// zero-duration timer; flush it inside the test body so the binding's
/// pending-timer invariant passes.
Future<void> teardownTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 1));
}
