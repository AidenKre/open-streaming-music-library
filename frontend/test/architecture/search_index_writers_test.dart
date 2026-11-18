// PM-APP-SEARCH: the search tables are contentless and are no longer rebuilt
// after every sync, so every statement in lib/ that writes what they are
// built from (trackmetadata rows and their title/artist/album, artists.name,
// albums.name and artist_id) must keep them in step itself. This lists every
// such statement with what keeps the index in step; a new one fails here
// until it is added with its own index maintenance.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// [file] without line comments, so docs that name a table don't count.
String _code(File file) => file
    .readAsLinesSync()
    .map((line) => line.replaceFirst(RegExp(r'//.*$'), ''))
    .join('\n');

const _tables = r'(?:main\.)?(trackmetadata|artists|albums)';

/// SQL text that writes one of the tables.
final _sqlWrite = RegExp(
  r'''(INSERT\s+(?:OR\s+\w+\s+)?INTO|REPLACE\s+INTO|UPDATE(?:\s+OR\s+\w+)?|DELETE\s+FROM)\s+["`]?'''
  '$_tables'
  r'\b',
  caseSensitive: false,
);

/// A drift write naming one of the tables: `into(db.x)`, `update(db.x)`,
/// `delete(db.x)`, `batch.insert(db.x, ...)` and the like.
final _driftWrite = RegExp(
  r'\b(into|update|delete|insert|insertAll|insertOnConflictUpdate|'
  r'insertAllOnConflictUpdate|replace|replaceAll|deleteWhere|deleteAll)'
  r'\(\s*(?:[\w$]+\.)*'
  '$_tables'
  r'\b',
);

/// A statement built from a table name at run time.
final _dynamicDelete = RegExp(r'DELETE FROM \$\{');

/// Drift's generated managers API on one of the tables.
final _managerWrite = RegExp(r'\bmanagers\.' '$_tables' r'\b');

/// Every write, as `path: statement`, and what keeps the search index in step.
const _known = {
  // Catalog page upsert: the page's per-page delta (readSearchBeforePage /
  // applySearchDeltaOfPage) and the parent rebuild when the page changed
  // artists or albums; the single-track refetch: applyTrackFtsDelta and
  // rebuildParentFtsIndexes.
  'lib/services/sync_service.dart: insert( _db.artists':
      'per-page parent check / refetch parent rebuild',
  'lib/services/sync_service.dart: insert( _db.albums':
      'per-page parent check / refetch parent rebuild',
  'lib/services/sync_service.dart: insert( _db.trackmetadata':
      'per-page track delta / refetch applyTrackFtsDelta',
  // The orphan prune: its removed-row count makes the page rebuild the parent
  // indexes; the refetch rebuilds them.
  'lib/services/sync_service.dart: DELETE FROM albums': 'prune count',
  'lib/services/sync_service.dart: DELETE FROM artists': 'prune count',
  // A catalog page delete: the per-page delta; the refetch's 404: the
  // per-row delta.
  'lib/services/sync_service.dart: delete( _db.trackmetadata':
      'per-page track delta / refetch applyTrackFtsDelta',
  // The optimistic edit (and its revert): applyTrackFtsDelta in the same
  // transaction. It never touches artists or albums.
  'lib/database/edit_outbox_queries.dart: UPDATE trackmetadata':
      'applyTrackFtsDelta',
  // Reset: resetLocalData empties every search table ('delete-all') in the
  // transaction that deletes every table.
  r'lib/database/database.dart: DELETE FROM ${': 'reset wipes the search tables',
};

void main() {
  test('every statement that writes what the search tables index is listed '
      'with what keeps the index in step', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));
    final found = <String>[];
    for (final file in files) {
      final code = _code(file);
      for (final pattern in [_sqlWrite, _driftWrite, _dynamicDelete, _managerWrite]) {
        for (final m in pattern.allMatches(code)) {
          final statement = m.group(0)!.replaceAll(RegExp(r'\s+'), ' ');
          found.add('${file.path}: $statement');
        }
      }
    }
    expect(found..sort(), _known.keys.toList()..sort());
  });

  test('the scan sees each kind of write it looks for', () {
    // Guards the patterns themselves: each of these would be a new writer.
    for (final sample in [
      "customStatement('UPDATE trackmetadata SET title = ?')",
      "customUpdate('insert or replace into artists (id) values (1)')",
      'await (db.update(db.trackmetadata)..where((t) => t.uuidId.equals(u))).write(c);',
      'await db.into(db.albums).insert(row);',
      'batch.deleteWhere(_db.artists, (a) => a.id.equals(1));',
      'await database.into(database.trackmetadata).insert(row);',
      "customStatement('DELETE FROM main.albums WHERE id = ?')",
      'await db.managers.artists.filter((a) => a.id(1)).delete();',
    ]) {
      expect(
        _sqlWrite.hasMatch(sample) ||
            _driftWrite.hasMatch(sample) ||
            _managerWrite.hasMatch(sample),
        isTrue,
        reason: sample,
      );
    }
  });
}
