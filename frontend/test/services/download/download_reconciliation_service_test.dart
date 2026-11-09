import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/database/database.dart';
import 'package:frontend/services/download/download_reconciliation_service.dart';
import 'package:frontend/services/download/download_status_reader.dart';

Future<void> _insertTrack(
  AppDatabase db,
  String uuid, {
  String? filePath,
  int? downloadedBitrateKbps,
  int? fileSizeBytes,
  String? downloadedQuality,
}) async {
  await db.into(db.tracks).insert(
        TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
          filePath: Value(filePath),
          downloadedBitrateKbps: Value(downloadedBitrateKbps),
          fileSizeBytes: Value(fileSizeBytes),
          downloadedQuality: Value(downloadedQuality),
        ),
      );
}

Future<String?> _damagedPath(AppDatabase db, String uuid) async =>
    (await (db.select(db.tracks)..where((t) => t.uuidId.equals(uuid)))
            .getSingle())
        .damagedFilePath;

Future<({String? filePath, int? bitrate, int? size, String? quality})>
    _readDownloadState(AppDatabase db, String uuid) async {
  final row = await (db.select(db.tracks)
        ..where((t) => t.uuidId.equals(uuid)))
      .getSingle();
  return (
    filePath: row.filePath,
    bitrate: row.downloadedBitrateKbps,
    size: row.fileSizeBytes,
    quality: row.downloadedQuality,
  );
}

void main() {
  late AppDatabase db;
  late DownloadStatusReader reader;
  late DownloadReconciliationService service;
  late Directory tmp;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    reader = DownloadStatusReader(db: db);
    service = DownloadReconciliationService(db: db, statusReader: reader);
    tmp = await Directory.systemTemp.createTemp('reconcile_test_');
  });

  tearDown(() async {
    reader.dispose();
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('clears DB fields for tracks whose file is missing', () async {
    await _insertTrack(
      db,
      'a',
      filePath: p.join(tmp.path, 'never-existed.m4a'),
      downloadedBitrateKbps: 320,
      fileSizeBytes: 12345,
      downloadedQuality: '320',
    );

    final changed = await service.reconcile();

    expect(changed, isTrue);
    final state = await _readDownloadState(db, 'a');
    expect(state.filePath, isNull);
    expect(state.bitrate, isNull);
    expect(state.size, isNull);
    expect(state.quality, isNull);
  });

  test('reconciles one track on request (5B.0d playback recovery)', () async {
    await _insertTrack(db, 'a',
        filePath: p.join(tmp.path, 'missing-a.m4a'),
        downloadedBitrateKbps: 320, fileSizeBytes: 1, downloadedQuality: '320');
    final kept = File(p.join(tmp.path, 'b.m4a'))..writeAsStringSync('x');
    await _insertTrack(db, 'b',
        filePath: kept.path,
        downloadedBitrateKbps: 320, fileSizeBytes: 1, downloadedQuality: '320');
    expect(await service.reconcileTrack('b'), isFalse);
    expect(await service.reconcileTrack('a'), isTrue);
    expect((await _readDownloadState(db, 'a')).filePath, isNull);
    expect((await _readDownloadState(db, 'b')).filePath, kept.path);
  });

  // Decision 6: a download that exists but failed to play.
  group('markDamaged', () {
    test('marks the path damaged and keeps the download and its details '
        '(2026-11-09: the re-download knows the original quality)', () async {
      await _insertTrack(db, 'a',
          filePath: '/dl/a.m4a',
          downloadedBitrateKbps: 320, fileSizeBytes: 9, downloadedQuality: '320');
      final before = reader.downloadStatusVersion.value;
      expect(await service.markDamaged('a', '/dl/a.m4a'), isTrue);
      final state = await _readDownloadState(db, 'a');
      expect(state,
          (filePath: '/dl/a.m4a', bitrate: 320, size: 9, quality: '320'));
      expect(await _damagedPath(db, 'a'), '/dl/a.m4a');
      expect(reader.downloadStatusVersion.value, before + 1);
      // A second mark of the same file changes nothing.
      expect(await service.markDamaged('a', '/dl/a.m4a'), isFalse);
      expect(reader.downloadStatusVersion.value, before + 1);
    });

    test('a damaged download is not a usable one: no Downloaded status',
        () async {
      final file = File(p.join(tmp.path, 'a.m4a'))..writeAsStringSync('x');
      await _insertTrack(db, 'a', filePath: file.path);
      expect(await reader.downloadedUuidsForUuids(['a']), {'a'});
      await service.markDamaged('a', file.path);
      expect(await reader.downloadedUuidsForUuids(['a']), isEmpty);
    });

    test('the full reconcile clears a damaged download whose file is gone',
        () async {
      await _insertTrack(db, 'a',
          filePath: p.join(tmp.path, 'gone.m4a'), downloadedQuality: '320');
      await service.markDamaged('a', p.join(tmp.path, 'gone.m4a'));
      expect(await service.reconcile(), isTrue);
      expect((await _readDownloadState(db, 'a')).filePath, isNull);
      expect(await _damagedPath(db, 'a'), isNull);
    });

    test('a path that changed meanwhile (a new download) wins', () async {
      await _insertTrack(db, 'a', filePath: '/dl/new-a.m4a');
      expect(await service.markDamaged('a', '/dl/old-a.m4a'), isFalse);
      expect((await _readDownloadState(db, 'a')).filePath, '/dl/new-a.m4a');
      expect(await _damagedPath(db, 'a'), isNull);
    });

    test('the full reconcile forgets a pre-2026-11-09 damaged file (path '
        'moved off file_path) that is gone, keeps one that is still there',
        () async {
      final kept = File(p.join(tmp.path, 'kept.m4a'));
      await kept.writeAsString('bad audio');
      await _insertTrack(db, 'a');
      await _insertTrack(db, 'b');
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
          .write(TracksCompanion(
              damagedFilePath: Value(p.join(tmp.path, 'gone.m4a'))));
      await (db.update(db.tracks)..where((t) => t.uuidId.equals('b')))
          .write(TracksCompanion(damagedFilePath: Value(kept.path)));
      expect(await service.reconcile(), isTrue);
      expect(await _damagedPath(db, 'a'), isNull);
      expect(await _damagedPath(db, 'b'), kept.path);
    });
  });

  test('a one-track reconcile keeps a path that changed meanwhile', () async {
    await _insertTrack(db, 'a',
        filePath: p.join(tmp.path, 'old-a.m4a'),
        downloadedBitrateKbps: 320, fileSizeBytes: 1, downloadedQuality: '320');
    final fresh = p.join(tmp.path, 'new-a.m4a');
    final racing = DownloadReconciliationService(
      db: db,
      statusReader: reader,
      fileExists: (path) async {
        // A re-download commits a new path while the old one is checked.
        await (db.update(db.tracks)..where((t) => t.uuidId.equals('a')))
            .write(TracksCompanion(filePath: Value(fresh)));
        return false;
      },
    );
    await racing.reconcileTrack('a');
    expect((await _readDownloadState(db, 'a')).filePath, fresh);
  });

  test('leaves tracks with on-disk files untouched', () async {
    final f = File(p.join(tmp.path, 'present.m4a'));
    await f.writeAsString('audio');
    await _insertTrack(
      db,
      'a',
      filePath: f.path,
      downloadedBitrateKbps: 256,
      fileSizeBytes: 999,
      downloadedQuality: '256',
    );

    final changed = await service.reconcile();

    expect(changed, isFalse);
    final state = await _readDownloadState(db, 'a');
    expect(state.filePath, f.path);
    expect(state.bitrate, 256);
    expect(state.size, 999);
    expect(state.quality, '256');
  });

  test('mixed: clears only the rows whose files vanished', () async {
    final keep = File(p.join(tmp.path, 'keep.m4a'));
    await keep.writeAsString('audio');
    await _insertTrack(db, 'keep',
        filePath: keep.path,
        downloadedBitrateKbps: 320,
        downloadedQuality: '320');
    await _insertTrack(db, 'gone',
        filePath: p.join(tmp.path, 'gone.m4a'),
        downloadedBitrateKbps: 192,
        downloadedQuality: '192');
    // Tracks with no file_path at all are skipped entirely.
    await _insertTrack(db, 'never');

    final changed = await service.reconcile();

    expect(changed, isTrue);
    expect((await _readDownloadState(db, 'keep')).filePath, keep.path);
    expect((await _readDownloadState(db, 'gone')).filePath, isNull);
    expect((await _readDownloadState(db, 'never')).filePath, isNull);
  });

  test('bumps downloadStatusVersion when rows are cleared', () async {
    await _insertTrack(db, 'a', filePath: p.join(tmp.path, 'gone.m4a'));
    final before = reader.downloadStatusVersion.value;

    await service.reconcile();

    expect(reader.downloadStatusVersion.value, before + 1);
  });

  test('does not bump downloadStatusVersion when nothing changes', () async {
    final f = File(p.join(tmp.path, 'present.m4a'));
    await f.writeAsString('audio');
    await _insertTrack(db, 'a', filePath: f.path);
    final before = reader.downloadStatusVersion.value;

    await service.reconcile();

    expect(reader.downloadStatusVersion.value, before);
  });

  test('cleared track no longer appears in file_path IS NOT NULL query',
      () async {
    await _insertTrack(db, 'gone', filePath: p.join(tmp.path, 'gone.m4a'));

    await service.reconcile();

    final rows = await db
        .customSelect('SELECT uuid_id FROM tracks WHERE file_path IS NOT NULL')
        .get();
    expect(rows, isEmpty);
  });

  test('concurrent reconcile calls dedupe onto a single run', () async {
    int callCount = 0;
    final svc = DownloadReconciliationService(
      db: db,
      statusReader: reader,
      fileExists: (path) async {
        callCount++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return false;
      },
    );
    await _insertTrack(db, 'a', filePath: p.join(tmp.path, 'a.m4a'));
    await _insertTrack(db, 'b', filePath: p.join(tmp.path, 'b.m4a'));

    final results = await Future.wait([svc.reconcile(), svc.reconcile()]);

    expect(results, [true, true]);
    expect(callCount, 2); // one per row, not two per row.
  });
}
