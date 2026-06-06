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
