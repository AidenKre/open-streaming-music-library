// Phase 5 decision 6: the Downloaded page's damaged downloads section.
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/downloads_controller.dart';
import 'package:frontend/ui/widgets/damaged_downloads_section.dart';

import '../fake_downloads_controls.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

Future<void> _insertTrack(AppDatabase db, String uuid,
    {String? damagedFilePath, String? filePath}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 0,
    'last_updated': 0,
    'revision': 1,
    'metadata': {
      'title': 'Title $uuid',
      'artist': 'A',
      'codec': 'aac',
      'duration': 1.0,
      'bitrate_kbps': 192.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  });
  await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
  await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
    TracksCompanion(
      filePath: Value(filePath),
      damagedFilePath: Value(damagedFilePath),
    ),
  );
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;
  late FakeDownloadsControls controls;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('damaged-section-test');
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
    controls = FakeDownloadsControls();
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Widget wrap({bool offline = false}) {
    final manager = DownloadManager(
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      isOfflineFn: () => true,
    );
    addTearDown(manager.dispose);
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        downloadManagerProvider.overrideWithValue(manager),
        downloadsControlsProvider.overrideWithValue(controls),
        offlineModeProvider.overrideWith(() => _StubOffline(offline)),
      ],
      // Like the Downloaded page: the section above an Expanded list.
      child: const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            DamagedDownloadsSection(),
            Expanded(child: Placeholder(key: Key('downloaded-list'))),
          ]),
        ),
      ),
    );
  }

  // Drift's stream-close timers run at scope disposal (as in the stale
  // banner test).
  Future<void> flushDispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }

  testWidgets('hidden when there are no damaged downloads', (tester) async {
    await _insertTrack(db, 'ok', filePath: '/dl/ok');
    await tester.pumpWidget(wrap());
    await settle(tester);
    expect(find.textContaining('couldn’t be played'), findsNothing);
    await flushDispose(tester);
  });

  testWidgets('lists damaged downloads; actions go through the controls',
      (tester) async {
    await _insertTrack(db, 'a', damagedFilePath: '/dl/a');
    await _insertTrack(db, 'b', damagedFilePath: '/dl/b');
    await _insertTrack(db, 'ok', filePath: '/dl/ok');
    await tester.pumpWidget(wrap());
    await settle(tester);
    expect(find.text(damagedDownloadsLabel(2)), findsOneWidget);
    expect(find.text('Title a'), findsOneWidget);
    expect(find.text('Title b'), findsOneWidget);
    expect(find.text('Title ok'), findsNothing);
    expect(find.textContaining('They stream until'), findsOneWidget);

    await tester.tap(find.text('Re-download all'));
    await tester.tap(find.byTooltip('Re-download').first);
    await tester.tap(find.byTooltip('Delete damaged file').last);
    await tester.pump();
    expect(controls.calls,
        ['redownloadDamaged a,b', 'redownloadDamaged a', 'deleteDamaged b']);
    await flushDispose(tester);
  });

  testWidgets('review: many damaged rows scroll inside the section; the '
      'list keeps its space', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (var i = 0; i < 30; i++) {
      await _insertTrack(db, 't$i', damagedFilePath: '/dl/t$i');
    }
    await tester.pumpWidget(wrap());
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'no overflow');
    expect(find.text(damagedDownloadsLabel(30)), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('downloaded-list'))).height,
        greaterThan(300));
    await flushDispose(tester);
  });

  testWidgets('review: a queued re-download keeps Delete available',
      (tester) async {
    await _insertTrack(db, 'a', damagedFilePath: '/dl/a');
    await tester.pumpWidget(wrap());
    await settle(tester);
    final manager = ProviderScope.containerOf(
            tester.element(find.byType(DamagedDownloadsSection)))
        .read(downloadManagerProvider);
    // Offline manager: the job stays queued.
    await tester.runAsync(() async => manager.enqueueTracks(
        [TrackUI.fromQueryRow((await db.getTrackByUuid('a')).first)],
        quality: '320'));
    await tester.pump();
    expect(find.text('Re-downloading…'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete damaged file'));
    await tester.pump();
    expect(controls.calls, ['deleteDamaged a']);
    await flushDispose(tester);
  });

  testWidgets('offline: re-downloading needs the server; Delete still works',
      (tester) async {
    await _insertTrack(db, 'a', damagedFilePath: '/dl/a');
    await tester.pumpWidget(wrap(offline: true));
    await settle(tester);
    expect(find.text(damagedDownloadsLabel(1)), findsOneWidget);
    expect(find.textContaining('skipped while offline'), findsOneWidget);
    await tester.tap(find.text('Re-download all'));
    await tester.tap(find.byTooltip('Re-download'));
    await tester.tap(find.byTooltip('Delete damaged file'));
    await tester.pump();
    expect(controls.calls, ['deleteDamaged a']);
    await flushDispose(tester);
  });
}
