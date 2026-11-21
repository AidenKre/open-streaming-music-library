// Rebuilding the search index is all or nothing. Each rebuild
// empties a search table and fills it again; a failure (or a kill) between
// the two steps used to leave the table empty, so search found nothing until
// the next rebuild. A rebuild that fails now leaves the index as it was.
// Callers already inside a transaction (a sync page) still commit and roll
// back with their own transaction.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

/// The real database; the first statement that starts with [failOn] fails.
class _FailingDb extends AppDatabase {
  _FailingDb() : super(NativeDatabase.memory());

  String? failOn;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    if (failOn != null && statement.startsWith(failOn!)) {
      throw StateError('refill failed');
    }
    await super.customStatement(statement, args);
  }
}

Future<void> _seed(AppDatabase db) async {
  await db.customStatement("INSERT INTO artists (id, name) VALUES (1, 'Abba')");
  await db.customStatement(
    'INSERT INTO albums (id, name, artist_id, year, is_single_grouping) '
    "VALUES (1, 'Arrival', 1, 1976, 0)",
  );
  await db.customStatement(
    'INSERT INTO tracks (uuid_id, created_at, last_updated, revision) '
    "VALUES ('u1', 1, 1, 1)",
  );
  await db.customStatement(
    'INSERT INTO trackmetadata (uuid_id, title, artist, album, artist_id, '
    "album_id, has_album_art) VALUES ('u1', 'Dancing Queen', 'Abba', "
    "'Arrival', 1, 1, 0)",
  );
}

/// How many entries of the search [table] match [term].
Future<int> _matches(AppDatabase db, String table, String term) async =>
    (await db.customSelect(
      'SELECT count(*) AS n FROM $table WHERE $table MATCH ?',
      variables: [Variable.withString(term)],
    ).getSingle()).read<int>('n');

/// The seeded artist, album and track are all found.
Future<void> _expectSeedFound(AppDatabase db) async {
  expect(await _matches(db, 'fts_artists', 'abba'), 1, reason: 'artist');
  expect(await _matches(db, 'fts_albums', 'arrival'), 1, reason: 'album');
  expect(await _matches(db, 'fts_tracks', 'queen'), 1, reason: 'track');
}

void main() {
  late _FailingDb db;

  setUp(() async {
    db = _FailingDb();
    await _seed(db);
    await db.rebuildFtsIndexes();
    await _expectSeedFound(db);
  });
  tearDown(() => db.close());

  group('a rebuild that fails part-way leaves the index as it was', () {
    test('artists and albums: the album refill fails', () async {
      db.failOn = 'INSERT INTO fts_albums(rowid';
      await expectLater(db.rebuildParentFtsIndexes(), throwsA(isA<StateError>()));
      db.failOn = null;

      await _expectSeedFound(db);
    });

    test('artists and albums: the artist refill fails', () async {
      db.failOn = 'INSERT INTO fts_artists(rowid';
      await expectLater(db.rebuildParentFtsIndexes(), throwsA(isA<StateError>()));
      db.failOn = null;

      await _expectSeedFound(db);
    });

    test('the whole index: the track refill fails, and the artists and albums '
        'it rebuilt first are rolled back too', () async {
      await db.customStatement("UPDATE artists SET name = 'Blondie' WHERE id = 1");
      db.failOn = 'INSERT INTO fts_tracks(rowid';
      await expectLater(db.rebuildFtsIndexes(), throwsA(isA<StateError>()));
      db.failOn = null;

      expect(await _matches(db, 'fts_tracks', 'queen'), 1,
          reason: 'the track index was not left empty');
      await _expectSeedFound(db);
      expect(await _matches(db, 'fts_artists', 'blondie'), 0,
          reason: 'the artist rebuild is part of the one that failed');
    });
  });

  group('a rebuild inside a caller\'s transaction', () {
    test('commits with it', () async {
      await db.transaction(() async {
        await db.customStatement(
          "INSERT INTO artists (id, name) VALUES (2, 'Blondie')",
        );
        await db.rebuildParentFtsIndexes();
      });

      expect(await _matches(db, 'fts_artists', 'blondie'), 1);
      await _expectSeedFound(db);
    });

    test('rolls back with it', () async {
      await expectLater(
        db.transaction(() async {
          await db.customStatement(
            "INSERT INTO artists (id, name) VALUES (2, 'Blondie')",
          );
          await db.rebuildParentFtsIndexes();
          throw StateError('the caller failed');
        }),
        throwsA(isA<StateError>()),
      );

      expect(await _matches(db, 'fts_artists', 'blondie'), 0);
      expect(
        await db.customSelect('SELECT id FROM artists WHERE id = 2').get(),
        isEmpty,
      );
      await _expectSeedFound(db);
    });

    test('that fails is undone alone: the caller can go on and commit',
        () async {
      await db.transaction(() async {
        db.failOn = 'INSERT INTO fts_albums(rowid';
        await expectLater(
          db.rebuildParentFtsIndexes(),
          throwsA(isA<StateError>()),
        );
        db.failOn = null;
        expect(await _matches(db, 'fts_albums', 'arrival'), 1,
            reason: 'inside the caller, the failed rebuild is already undone');
        await db.customStatement(
          "INSERT INTO artists (id, name) VALUES (2, 'Blondie')",
        );
      });

      await _expectSeedFound(db);
      expect(
        await db.customSelect('SELECT id FROM artists WHERE id = 2').get(),
        hasLength(1),
        reason: "the caller's own write committed",
      );
    });
  });
}
