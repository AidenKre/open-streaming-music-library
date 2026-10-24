import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';

Future<void> _insertTrack(
  AppDatabase db, {
  required String uuid,
  required int revision,
  int? downloadedAtRevision,
  String codec = 'aac',
  String? downloadedCodec,
  double bitrateKbps = 192.0,
  int? downloadedBitrateKbps,
  String title = 'My Track',
}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 0,
    'last_updated': 0,
    'revision': revision,
    'metadata': {
      'title': title,
      'artist': 'A',
      'codec': codec,
      'duration': 1.0,
      'bitrate_kbps': bitrateKbps,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  });
  await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
  await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
    TracksCompanion(
      filePath: Value('/local/$uuid.audio'),
      downloadedAtRevision: Value(downloadedAtRevision),
      downloadedCodec: Value(downloadedCodec),
      downloadedBitrateKbps: Value(downloadedBitrateKbps),
      downloadedQuality: const Value('192'),
    ),
  );
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('stale-banner-test');
    ApiClient.initForTest(
      'http://test:8080',
      MockClient((_) async => http.Response.bytes([1], 200)),
    );
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap({bool notify = true}) {
    final manager = DownloadManager(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
    );
    addTearDown(manager.dispose);
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        downloadManagerProvider.overrideWithValue(manager),
        settingsProvider.overrideWith(() => _FixedSettings(notify)),
      ],
      child: const MaterialApp(home: Scaffold(body: StaleDownloadsBanner())),
    );
  }

  // Unmounts the tree, then flushes drift's stream-close timers (scheduled
  // during ProviderScope disposal) so flutter_test's pending-timer invariant
  // passes -- same pattern used by pending_edits_banner_test.dart for the
  // same reason (both watch a Drift-backed StreamProvider).
  Future<void> flushDispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('hidden when there are no stale downloads', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump(); // first stream emission

    expect(find.byType(StaleDownloadsBanner), findsOneWidget);
    expect(find.textContaining('outdated'), findsNothing);

    await flushDispose(tester);
  });

  testWidgets('shows a count when a download is stale', (tester) async {
    await _insertTrack(
      db,
      uuid: 'abc',
      revision: 6,
      downloadedAtRevision: 5,
      codec: 'aac',
      downloadedCodec: 'flac',
    );

    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(find.textContaining('1 download'), findsOneWidget);

    await flushDispose(tester);
  });

  testWidgets(
    'hidden when notifyStaleDownloads is false, even with stale downloads',
    (tester) async {
      await _insertTrack(
        db,
        uuid: 'abc',
        revision: 6,
        downloadedAtRevision: 5,
      );

      await tester.pumpWidget(wrap(notify: false));
      await tester.pump();

      expect(find.textContaining('outdated'), findsNothing);

      await flushDispose(tester);
    },
  );

  testWidgets('tapping the banner opens a list with a diff and actions',
      (tester) async {
    await _insertTrack(
      db,
      uuid: 'abc',
      revision: 6,
      downloadedAtRevision: 5,
      codec: 'aac',
      downloadedCodec: 'flac',
      bitrateKbps: 192.0,
      downloadedBitrateKbps: 1000,
      title: 'My Favorite Song',
    );

    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.tap(find.byType(InkWell));
    await tester.pump(); // start the sheet route
    await tester.pump(const Duration(seconds: 1)); // finish its animation

    expect(find.text('My Favorite Song'), findsOneWidget);
    expect(find.textContaining('flac'), findsWidgets);
    expect(find.textContaining('aac'), findsWidgets);
    expect(find.byTooltip('Re-download'), findsOneWidget);
    expect(find.byTooltip('Dismiss'), findsOneWidget);

    await flushDispose(tester);
  });

  testWidgets('dismiss removes the track from the list', (tester) async {
    await _insertTrack(
      db,
      uuid: 'abc',
      revision: 6,
      downloadedAtRevision: 5,
    );

    await tester.pumpWidget(wrap());
    await tester.pump();

    await tester.tap(find.byType(InkWell));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump(const Duration(seconds: 1));

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.staleDismissedAtRevision, 6);

    await flushDispose(tester);
  });
}

class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this._notify);
  final bool _notify;

  @override
  Future<AppSettings> build() async {
    return AppSettings(
      persistedStreamQuality: 'original',
      downloadQuality: 'original',
      notifyStaleDownloads: _notify,
    );
  }
}
