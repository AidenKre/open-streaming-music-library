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
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/downloading_page.dart';

TrackUI _track(String uuid) => TrackUI(
      uuidId: uuid,
      createdAt: 0,
      lastUpdated: 0,
      title: 'Title $uuid',
      artist: 'Artist',
      duration: 120,
      bitrateKbps: 320,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
    );

Future<void> _insertTrack(AppDatabase db, String uuid) async {
  await db.into(db.tracks).insert(
        TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
        ),
      );
  await db.into(db.trackmetadata).insert(
        TrackmetadataCompanion.insert(
          uuidId: uuid,
          duration: 120,
          bitrateKbps: 320,
          sampleRateHz: 44100,
          channels: 2,
          hasAlbumArt: const Value(false),
        ),
      );
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('downloading-page-test');
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
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  DownloadManager buildManager({required http.Client client}) {
    ApiClient.initForTest('http://test:8080', client);
    return DownloadManager(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
    );
  }

  Widget wrap(DownloadManager manager) {
    return ProviderScope(
      overrides: [
        downloadManagerProvider.overrideWithValue(manager),
      ],
      child: const MaterialApp(home: DownloadingPage()),
    );
  }

  testWidgets('shows empty state when no jobs', (tester) async {
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1], 200)),
    );
    // ChangeNotifierProvider.overrideWith handles disposal at scope teardown.

    await tester.pumpWidget(wrap(manager));
    expect(find.text('No downloads yet.'), findsOneWidget);
    expect(find.text('Clear'), findsNothing);
  });

  testWidgets('renders a Finished section after completion and Clear empties it',
      (tester) async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      client: MockClient((_) async => http.Response.bytes([1, 2, 3], 200)),
    );
    // ChangeNotifierProvider.overrideWith handles disposal at scope teardown.

    // Drain the manager outside the fake-async zone so Future.delayed fires.
    await tester.runAsync(() async {
      await manager.enqueueTracks([_track('abc')], quality: '320');
      while (manager.snapshot().any((j) =>
          j.state == DownloadState.queued || j.state == DownloadState.active)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    await tester.pumpWidget(wrap(manager));
    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('Title abc'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('No downloads yet.'), findsOneWidget);
  });

  testWidgets('failed downloads render under Finished with an error icon',
      (tester) async {
    await _insertTrack(db, 'abc');
    final manager = buildManager(
      // Throw so the catch-block populates errorMessage on the job.
      client: MockClient((_) async => throw Exception('boom')),
    );
    // ChangeNotifierProvider.overrideWith handles disposal at scope teardown.

    await tester.runAsync(() async {
      await manager.enqueueTracks([_track('abc')], quality: '320');
      while (manager.snapshot().any((j) =>
          j.state == DownloadState.queued || j.state == DownloadState.active)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    await tester.pumpWidget(wrap(manager));
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('Failed:'), findsOneWidget);
  });
}
