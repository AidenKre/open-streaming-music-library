// A database file of another schema version is refused when it opens (pre-
// merge review D3-01). The reset then deletes exactly that file and its side
// files, never anything else, and the next use opens a fresh version-1 file.
// Both connection setups are covered: the background isolate the app uses
// (its errors arrive wrapped) and one in this isolate.
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

import '../helpers/server_binding.dart';

/// A plain database stamped [version] with one table and one row: the shape
/// of an app database written by another build.
class _OtherBuild extends GeneratedDatabase {
  _OtherBuild(super.e, this.version);
  final int version;
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => const [];
  @override
  int get schemaVersion => version;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await customStatement('CREATE TABLE old_tracks (title TEXT)');
      await customStatement("INSERT INTO old_tracks VALUES ('kept?')");
    },
  );
}

Future<void> _writeOtherBuild(File file, {int version = 8}) async {
  final db = _OtherBuild(NativeDatabase(file), version);
  await db.customSelect('SELECT 1').get();
  await db.close();
}

Future<int> _userVersion(AppDatabase db) async =>
    (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
      'user_version',
    );

Future<Object> _errorOf(Future<Object?> f) =>
    f.then<Object>((_) => fail('expected a failure'), onError: (Object e) => e);

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('osml-app-db-');
    file = File('${dir.path}/database.db');
  });
  tearDown(() => dir.delete(recursive: true));

  for (final (name, QueryExecutor Function(File) open) in [
    ('the background isolate (as the app)', NativeDatabase.createInBackground),
    ('this isolate', NativeDatabase.new),
  ]) {
    group('on $name', () {
      AppDatabase appDb() =>
          AppDatabase(AppDatabaseConnection(() async => file, open: open));

      test('a file of another version is refused, and the refusal is '
          'recognised with both versions', () async {
        await _writeOtherBuild(file);
        final db = appDb();
        addTearDown(db.close);
        final error = await _errorOf(db.customSelect('SELECT 1').get());
        final refusal = databaseVersionRefusalIn(error);
        expect(refusal, isNotNull, reason: 'error was ${error.runtimeType}');
        expect(refusal!.found, 8);
        expect(refusal.expected, 1);
      });

      test('discarding a refused file deletes it and its side files only; '
          'the next use opens a fresh version-1 database', () async {
        await _writeOtherBuild(file);
        final db = appDb();
        addTearDown(db.close);
        await _errorOf(db.customSelect('SELECT 1').get());
        // Side files of the refused file, and neighbours that are not it.
        for (final side in ['-wal', '-shm', '-journal']) {
          File('${file.path}$side').writeAsStringSync('side');
        }
        final neighbours = [
          File('${dir.path}/database.db.bak')..writeAsStringSync('n'),
          File('${dir.path}/other.db')..writeAsStringSync('n'),
          File('${dir.path}/database.db-wal.old')..writeAsStringSync('n'),
          File('${dir.path}/libCachedImageData.db')..writeAsStringSync('n'),
        ];
        final folder = Directory('${dir.path}/database.db.d')..createSync();

        await db.discardRefusedFile();

        for (final side in ['-wal', '-shm', '-journal']) {
          expect(File('${file.path}$side').existsSync(), isFalse,
              reason: 'side file $side');
        }
        for (final n in neighbours) {
          expect(n.readAsStringSync(), 'n', reason: '${n.path} is not the db');
        }
        expect(folder.existsSync(), isTrue);

        expect(await _userVersion(db), 1);
        expect(await db.select(db.serverBinding).get(), isEmpty);
        final old = await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE name = 'old_tracks'",
            )
            .get();
        expect(old, isEmpty, reason: 'the old file is gone');
      });

      test('a file that opens is never deleted', () async {
        final db = appDb();
        addTearDown(db.close);
        await seedTestBinding(db, baseUrl: 'http://s');

        await db.discardRefusedFile();

        expect(file.existsSync(), isTrue);
        expect(await db.select(db.serverBinding).get(), hasLength(1));
      });

      test('a link at the database path is removed as a link; its target is '
          'left as it was', () async {
        final elsewhere = Directory('${dir.path}/elsewhere')..createSync();
        final target = File('${elsewhere.path}/real.db');
        await _writeOtherBuild(target);
        final bytes = target.readAsBytesSync();
        Link(file.path).createSync(target.path);
        final db = appDb();
        addTearDown(db.close);
        await _errorOf(db.customSelect('SELECT 1').get());

        await db.discardRefusedFile();

        expect(target.readAsBytesSync(), bytes, reason: 'never followed');
        expect(await _userVersion(db), 1);
        expect(
          FileSystemEntity.typeSync(file.path, followLinks: false),
          FileSystemEntityType.file,
          reason: 'the fresh database is a file of its own',
        );
      });

      test('a folder at a side file path is left; the discard still '
          'completes', () async {
        await _writeOtherBuild(file);
        final db = appDb();
        addTearDown(db.close);
        await _errorOf(db.customSelect('SELECT 1').get());
        final folder = Directory('${file.path}-shm')..createSync();
        File('${folder.path}/inside').writeAsStringSync('x');

        await db.discardRefusedFile();

        expect(File('${folder.path}/inside').readAsStringSync(), 'x');
        expect(await _userVersion(db), 1);
      });
    });
  }

  test('any other error is not a refusal', () {
    expect(databaseVersionRefusalIn(StateError('database is locked')), isNull);
    expect(databaseVersionRefusalIn(null), isNull);
  });

  test('a database without a file of its own has nothing to discard', () async {
    final db = AppDatabase(NativeDatabase.memory(
      setup: (raw) => raw.execute('PRAGMA user_version = 8'),
    ));
    addTearDown(db.close);
    await expectLater(db.discardRefusedFile(), throwsUnsupportedError);
  });
}
