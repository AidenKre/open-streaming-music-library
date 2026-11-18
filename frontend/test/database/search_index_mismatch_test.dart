// PM-APP-SEARCH safety net: what SQLite's FTS5 does when a contentless search
// table is told to delete a row with values other than the ones it indexed,
// and what state a transaction is in after FTS5 refuses such a delete. The
// sync's per-page search update relies on both (SyncService
// _updateSearchIndex): a refusal is SQLITE_CORRUPT_VTAB, recognised by
// isSearchIndexMismatch, and is repaired by a full rebuild in the same
// transaction; a mismatch FTS5 accepts silently leaves wrong terms behind.
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';

Future<List<int>> _hits(AppDatabase db, String term) async => [
  for (final r in await db
      .customSelect(
        'SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH ? ORDER BY rowid',
        variables: [Variable.withString(term)],
      )
      .get())
    r.read<int>('rowid'),
];

Future<List<int>> _scan(AppDatabase db) async => [
  for (final r in await db
      .customSelect('SELECT rowid FROM fts_tracks ORDER BY rowid')
      .get())
    r.read<int>('rowid'),
];

const _deleteSql =
    'INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) '
    "VALUES('delete', ?, ?, ?, ?)";

void main() {
  group('a delete given other values than the indexed ones '
      "(row 1 indexed as title 'a b', row 2 as 'c d')", () {
    late AppDatabase db;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await db.customStatement(
        'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
        "VALUES(1, 'a b', '', ''), (2, 'c d', '', '')",
      );
    });
    tearDown(() => db.close());

    // given values -> (raises, rows still found by 'a', by 'b')
    final cases = <String, ((String, String), bool, List<int>, List<int>)>{
      'the exact values': (('a b', ''), false, [], []),
      'a different title': (('x y', ''), false, [1], [1]),
      'a term added': (('a b c', ''), false, [], []),
      'a term removed': (('a', ''), false, [], [1]),
      'an empty value': (('', ''), false, [1], [1]),
      'a term in another column': (('a', 'b'), true, [1], [1]),
    };
    for (final c in cases.entries) {
      final ((title, artist), raises, a, b) = c.value;
      test('${c.key}: ${raises ? 'refused' : 'accepted'}; afterwards "a" '
          'finds $a, "b" finds $b', () async {
        Object? error;
        try {
          await db.customStatement(_deleteSql, [1, title, artist, '']);
        } on Object catch (e) {
          error = e;
        }
        if (raises) {
          expect(error, isNotNull);
          expect(isSearchIndexMismatch(error!), isTrue);
          expect(await _scan(db), [1, 2], reason: 'the refused delete undid itself');
        } else {
          expect(error, isNull);
          expect(await _scan(db), [2], reason: 'the row counts as deleted');
        }
        expect(await _hits(db, 'a'), a);
        expect(await _hits(db, 'b'), b);
        expect(await _hits(db, 'c'), [2]);
      });
    }

    test('a row that was never indexed, in an index that holds others: '
        'accepted', () async {
      await db.customStatement(_deleteSql, [3, 'e f', '', '']);
      expect(await _scan(db), [1, 2]);
      expect(await _hits(db, 'a'), [1]);
    });

    test('a row that was never indexed, in an empty index: refused', () async {
      await db.customStatement(
        "INSERT INTO fts_tracks(fts_tracks) VALUES('delete-all')",
      );
      Object? error;
      try {
        await db.customStatement(_deleteSql, [3, 'e f', '', '']);
      } on Object catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(isSearchIndexMismatch(error!), isTrue);
    });
  });

  // Over a real database file, opened both ways (the app opens it in a
  // background isolate, which relays errors wrapped).
  for (final background in [false, true]) {
    for (final savepoint in [true, false]) {
      test('after a refused delete inside a transaction '
          '(${background ? 'background isolate' : 'same isolate'}, '
          '${savepoint ? 'in a savepoint' : 'no savepoint'}) the transaction '
          'goes on and commits', () async {
        final dir = Directory.systemTemp.createTempSync('pm_app_search_tx_');
        addTearDown(() => dir.deleteSync(recursive: true));
        final file = File('${dir.path}/app.db');
        final db = AppDatabase(
          background
              ? NativeDatabase.createInBackground(file)
              : NativeDatabase(file),
        );
        Object? caught;
        late List<int> keptInside;
        await db.transaction(() async {
          await db.customStatement('CREATE TABLE probe(x)');
          await db.customStatement('INSERT INTO probe VALUES (1)');
          await db.customStatement(
            'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
            "VALUES(5, 'keep me', '', '')",
          );
          // A batch whose first delete is right and whose second names a row
          // the (otherwise empty) index never held.
          Future<void> deltas() => db.batch((b) {
            b.customStatement(_deleteSql, [5, 'keep me', '', '']);
            b.customStatement(_deleteSql, [1, 'a b', '', '']);
          });
          try {
            await (savepoint ? db.transaction(deltas) : deltas());
          } on Object catch (e) {
            caught = e;
          }
          keptInside = await _hits(db, 'keep');
          await db.customStatement('INSERT INTO probe VALUES (2)');
        });
        await db.close();

        expect(isSearchIndexMismatch(caught!), isTrue,
            reason: 'recognised as a search-index mismatch: $caught');
        // Without a savepoint only the refused statement is undone: the
        // batch's first delete stays. The savepoint undoes the whole update.
        expect(keptInside, savepoint ? [5] : <int>[]);

        final reopened = AppDatabase(NativeDatabase(file));
        addTearDown(reopened.close);
        final probe = [
          for (final r in await reopened.customSelect('SELECT x FROM probe').get())
            r.read<int>('x'),
        ];
        expect(probe, [1, 2], reason: 'the transaction committed both rows');
        expect(await _hits(reopened, 'keep'), savepoint ? [5] : <int>[]);
      });
    }
  }
}
