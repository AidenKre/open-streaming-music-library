import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/database/database.dart';
import 'package:frontend/services/download/download_status_reader.dart';

Future<void> _insertTrack(
  AppDatabase db,
  String uuid, {
  String? filePath,
}) async {
  await db
      .into(db.tracks)
      .insert(
        TracksCompanion.insert(
          uuidId: uuid,
          createdAt: 0,
          lastUpdated: 0,
          filePath: Value(filePath),
        ),
      );
}

void main() {
  late AppDatabase db;
  late DownloadStatusReader reader;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    reader = DownloadStatusReader(db: db);
  });

  tearDown(() async {
    reader.dispose();
    await db.close();
  });

  test('bumpVersion increments downloadStatusVersion', () {
    final before = reader.downloadStatusVersion.value;
    reader.bumpVersion();
    expect(reader.downloadStatusVersion.value, before + 1);
    reader.bumpVersion();
    expect(reader.downloadStatusVersion.value, before + 2);
  });

  test('downloadedUuidsForUuids returns empty set for empty input', () async {
    expect(await reader.downloadedUuidsForUuids(const []), isEmpty);
  });

  test(
    'downloadedUuidsForUuids excludes tracks with null file_path',
    () async {
      await _insertTrack(db, 'a');
      await _insertTrack(db, 'b');
      final result = await reader.downloadedUuidsForUuids(['a', 'b']);
      expect(result, isEmpty);
    },
  );

  test(
    'downloadedUuidsForUuids excludes uuids whose file is missing on disk',
    () async {
      // file_path is set, but no file exists at that path.
      await _insertTrack(db, 'a', filePath: '/nonexistent/${"a"}.m4a');
      final result = await reader.downloadedUuidsForUuids(['a']);
      expect(result, isEmpty);
    },
  );

  test(
    'downloadedUuidsForUuids includes uuids whose file exists on disk',
    () async {
      final tmp = await Directory.systemTemp.createTemp('reader_test_');
      try {
        final f = File(p.join(tmp.path, 'a.m4a'));
        await f.writeAsString('audio');
        await _insertTrack(db, 'a', filePath: f.path);
        await _insertTrack(db, 'b');

        final result = await reader.downloadedUuidsForUuids(['a', 'b']);
        expect(result, {'a'});
      } finally {
        await tmp.delete(recursive: true);
      }
    },
  );
}
