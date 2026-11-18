import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:flutter/foundation.dart' show protected;
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/editable_fields.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'autocomplete_queries.dart';
part 'browse_queries.dart';
part 'database.g.dart';
part 'download_state_queries.dart';
part 'edit_outbox_queries.dart';
part 'query_parameters.dart';
part 'search_index.dart';
part 'tables.dart';
part 'track_sql.dart';

const _historyContentTrigger = '''
CREATE TRIGGER history_content
AFTER UPDATE OF kind, entity_type, entity_ref, occurred_at, seconds_played, track_length
ON history_events
WHEN OLD.kind IS NOT NEW.kind
  OR OLD.entity_type IS NOT NEW.entity_type
  OR OLD.entity_ref IS NOT NEW.entity_ref
  OR OLD.occurred_at IS NOT NEW.occurred_at
  OR OLD.seconds_played IS NOT NEW.seconds_played
  OR OLD.track_length IS NOT NEW.track_length
BEGIN
  INSERT INTO local_counters (key, value) VALUES ('history_content', 1)
  ON CONFLICT(key) DO UPDATE SET value = value + 1;
END
''';

const _catalogAttributionTriggers = [
  '''
CREATE TRIGGER catalog_attribution_insert
AFTER INSERT ON trackmetadata
BEGIN
  INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 1)
  ON CONFLICT(key) DO UPDATE SET value = value + 1;
END
''',
  '''
CREATE TRIGGER catalog_attribution_delete
AFTER DELETE ON trackmetadata
BEGIN
  INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 1)
  ON CONFLICT(key) DO UPDATE SET value = value + 1;
END
''',
  '''
CREATE TRIGGER catalog_attribution_update
AFTER UPDATE OF title, artist, album, album_artist, artist_id, album_id
ON trackmetadata
WHEN OLD.title IS NOT NEW.title
  OR OLD.artist IS NOT NEW.artist
  OR OLD.album IS NOT NEW.album
  OR OLD.album_artist IS NOT NEW.album_artist
  OR OLD.artist_id IS NOT NEW.artist_id
  OR OLD.album_id IS NOT NEW.album_id
BEGIN
  INSERT INTO local_counters (key, value) VALUES ('catalog_attribution', 1)
  ON CONFLICT(key) DO UPDATE SET value = value + 1;
END
''',
];

/// Nulls every column that marks a track as downloaded. The single shared
/// definition for every clear path (delete, reset fence, a commit undone by a
/// reset) so adding a downloaded-state column can't leave a row half-cleared.
/// Must stay in sync with the columns `TrackDownloader` writes on commit.
const clearedDownloadColumns = TracksCompanion(
  filePath: Value(null),
  damagedFilePath: Value(null),
  downloadedBitrateKbps: Value(null),
  fileSizeBytes: Value(null),
  downloadedQuality: Value(null),
  downloadedAtRevision: Value(null),
  downloadedCodec: Value(null),
  staleDismissedAtRevision: Value(null),
);

// ── FTS5 virtual table creation statements ──────────────────────────────

// The search tables are contentless (`content=''`): every insert gives the
// rowid itself (the trackmetadata rowid, the artist id, the album id).
// `content_rowid='id'` names no column of theirs; it is kept as written.
const _ftsStatements = [
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_tracks USING fts5("
      "title, artist_name, album_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_artists USING fts5("
      "name, "
      "content='', content_rowid='id', tokenize='unicode61')",
  "CREATE VIRTUAL TABLE IF NOT EXISTS fts_albums USING fts5("
      "name, artist_name, "
      "content='', content_rowid='id', tokenize='unicode61')",
];

String _quoteSqlIdentifier(String identifier) {
  return '"${identifier.replaceAll('"', '""')}"';
}

// ── Database ────────────────────────────────────────────────────────────

/// Why an outbox edit was rejected because its track was deleted server-side.
const trackGoneRejectionReason = 'Track no longer exists on the server';

/// The stored states of an unsent metadata edit (`pending_edits.status`; the
/// table's column default is the same `pending`). See the column's comment
/// for what each means.
abstract final class PendingEditStatus {
  static const pending = 'pending';
  static const conflicted = 'conflicted';
  static const rejected = 'rejected';
  static const takeServer = 'take_server';
}

/// The app's local database. The tables declare references and cascades
/// (`references(...)`, `KeyAction.cascade`), but the app never turns on
/// SQLite's `foreign_keys`, so none of them is enforced: code that deletes
/// rows removes the child rows itself.
@DriftDatabase(
  tables: [
    Artists,
    Albums,
    Tracks,
    Trackmetadata,
    QueueSessions,
    QueueSessionItems,
    QueueSessionPlayOrder,
    PendingEdits,
    ServerBinding,
    SyncCursors,
    HistoryEvents,
    LocalCounters,
    HistorySyncFailures,
    HistoryConflictArchive,
    ActiveListens,
    DurableSubmissions,
    UploadIntents,
    OwnedFileCleanupEntries,
  ],
)
class AppDatabase extends _$AppDatabase
    with
        _AutocompleteQueries,
        _DownloadStateQueries,
        _SearchIndex,
        _BrowseQueries,
        // Must follow _SearchIndex: its 'on' clause needs that mixin.
        _EditOutboxQueries
    implements LocalResettable {
  AppDatabase(super.e);

  /// Schema history was reset before the first release (2026-11-17):
  /// version 1 is the baseline, and a database stamped with any other
  /// version is refused when it opens (see [upgradeSteps]); nothing upgrades
  /// a database from before the reset. The next schema change is version 2.
  ///
  /// While the schema stays at version 1 and its tables are edited directly,
  /// export the version-1 snapshot again after every edit
  /// (`dart run drift_dev schema dump lib/database/database.dart
  /// drift_schemas/default/`): the first upgrade step is generated against it.
  ///
  /// Migration pattern (every schema change follows it):
  ///
  ///  1. Change the table classes, bump [schemaVersion], then run
  ///     `dart run drift_dev make-migrations`. It exports the frozen snapshot
  ///     `drift_schemas/default/drift_schema_vN.json`, and from the second
  ///     snapshot on it also writes `database.steps.dart`, the versioned test
  ///     schemas under `test/drift/` and the generated migration test.
  ///  2. Make [upgradeSteps] return the generated `stepByStep` (import
  ///     `database.steps.dart`) with one `fromXToY` step per version. Each
  ///     step only sees the generated `SchemaY` snapshot, never the
  ///     current Dart tables, so an older upgrader can't be handed a later
  ///     table shape (an unguarded ALTER against the current shape once
  ///     bricked every upgrading install).
  ///  3. Every bump ships with a test that opens a real previous-version
  ///     database file and runs the actual `onUpgrade` — never a hand-replayed
  ///     statement list — and checks the result equals a fresh install.
  ///  4. The whole upgrade is atomic: [migration] runs every step inside one
  ///     `transaction` that also sets `PRAGMA user_version` to the target, so
  ///     a failing step rolls back all of its DDL/DML and the version
  ///     advances only with a successful migration. The transaction is what
  ///     makes it atomic: drift does not wrap `onUpgrade` in one, and the
  ///     generated `stepByStep` writes `user_version` after every step
  ///     (inside this transaction, so those writes roll back too).
  ///     New steps get this for free; never commit or open a nested
  ///     transaction inside a step.
  ///  5. A `TableMigration` rebuild renumbers trackmetadata's implicit rowid,
  ///     which keys `fts_tracks`: a step that rebuilds trackmetadata must
  ///     [rebuildFtsIndexes] afterwards.
  @override
  int get schemaVersion => 1;

  @override
  StreamQueryUpdateRules get streamUpdateRules => StreamQueryUpdateRules([
    ...super.streamUpdateRules.rules,
    // Include inserts too: an upsert can run the payload UPDATE trigger.
    const WritePropagation(
      on: TableUpdateQuery.onTableName('history_events'),
      result: [TableUpdate('local_counters')],
    ),
    // SC-11: the catalog_attribution triggers bump a counter on every
    // insert, update and delete of trackmetadata; drift can't see that.
    const WritePropagation(
      on: TableUpdateQuery.onTableName('trackmetadata'),
      result: [TableUpdate('local_counters')],
    ),
  ]);

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(_historyContentTrigger);
      for (final stmt in _catalogAttributionTriggers) {
        await customStatement(stmt);
      }
      for (final stmt in _ftsStatements) {
        await customStatement(stmt);
      }
    },
    onUpgrade: (m, from, to) => transaction(() async {
      await upgradeSteps(m, from, to);
      // Committed together with the steps, so a crash can't leave a half-done
      // upgrade stamped as done or re-run a finished one. Drift writes the
      // version again after beforeOpen, outside this transaction: a harmless
      // repeat. (A generated stepByStep also writes it after each step, inside
      // this transaction.)
      await customStatement('PRAGMA user_version = $to');
    }),
  );

  /// The upgrade from a stored version to [schemaVersion]; run only through
  /// [migration]'s transaction. Version 1 has no step, so a database stamped
  /// with any other version is refused before anything is written. A test
  /// subclass overrides this to supply a fake step.
  @protected
  OnUpgrade get upgradeSteps => (m, from, to) async {
    throw DatabaseVersionRefused(from, to);
  };

  Future<void> resetLocalData() async {
    await transaction(() async {
      final ftsTables = await customSelect(
        "SELECT name FROM sqlite_master "
        "WHERE type = 'table' "
        "AND sql LIKE 'CREATE VIRTUAL TABLE%USING fts5%'",
        readsFrom: {},
      ).get();
      for (final row in ftsTables) {
        final name = row.read<String>('name');
        final quoted = _quoteSqlIdentifier(name);
        await customStatement(
          "INSERT INTO $quoted($quoted) VALUES('delete-all')",
        );
      }

      for (final table in allTables.toList().reversed) {
        await customStatement(
          'DELETE FROM ${_quoteSqlIdentifier(table.actualTableName)}',
        );
      }

      // Deleting trackmetadata fires the catalog_attribution DELETE trigger,
      // which re-creates its local_counters row after that table was cleared.
      await customStatement('DELETE FROM local_counters');

      try {
        await customStatement('DELETE FROM sqlite_sequence');
      } catch (_) {}
    });
  }

  /// Deletes this database's file when, and only when, it was refused for
  /// another schema version ([DatabaseVersionRefused]); the next use opens
  /// a fresh file at version 1. A file that opens is left alone. Throws
  /// [UnsupportedError] when the database has no file of its own (an
  /// in-memory one).
  Future<void> discardRefusedFile() async {
    final connection = executor;
    if (connection is! AppDatabaseConnection) {
      throw UnsupportedError('this database has no file of its own');
    }
    // Asked again here: only a file this app refuses is ever deleted.
    try {
      await customSelect('SELECT 1').get();
      return;
    } catch (e) {
      if (databaseVersionRefusalIn(e) == null) rethrow;
    }
    await connection.discardFile();
  }

  // --- LocalResettable -------------------------------------------------------
  @override
  int get resetPriority => ResetPriority.wipeDatabase;

  @override
  Future<void> resetLocalState() => resetLocalData();
}

// ── Database factory ────────────────────────────────────────────────────

/// The app's database file: `database.db` in the app's support folder.
Future<File> appDatabaseFile() async {
  final dir = await getApplicationSupportDirectory();
  return File(p.join(dir.path, 'database.db'));
}

/// The app's database connection: a background isolate on
/// [appDatabaseFile], opened when first used.
AppDatabaseConnection openAppDatabase() =>
    AppDatabaseConnection(appDatabaseFile);

/// The connection to the app's database file, opened when first used. A
/// file of another schema version is refused when it opens
/// ([DatabaseVersionRefused]) and every later query fails the same way;
/// [discardFile] closes the connection and deletes the file and its side
/// files, and the next use opens a fresh file at the same path.
class AppDatabaseConnection extends QueryExecutor {
  AppDatabaseConnection(this._locate, {QueryExecutor Function(File)? open})
      : _open = open ?? NativeDatabase.createInBackground;

  final Future<File> Function() _locate;
  final QueryExecutor Function(File) _open;
  late QueryExecutor _current = _connect();

  QueryExecutor _connect() => LazyDatabase(() async => _open(await _locate()));

  /// Closes the connection and deletes the database file and its side files
  /// (`-wal`, `-shm`, `-journal`): each only when it is a file, and a link
  /// is removed as a link, never followed. Nothing else is touched, never a
  /// folder. Whatever happens, the next use opens a new connection.
  ///
  /// Deleting a file the background isolate may not have closed yet is fine
  /// where a delete only removes the name (Apple, Android, Linux) and with
  /// the rollback journal this app uses; on Windows the delete can fail, and
  /// the reset then stops and is finished by the next launch.
  Future<void> discardFile() async {
    try {
      await _current.close();
      final file = await _locate();
      for (final suffix in const ['', '-wal', '-shm', '-journal']) {
        final path = '${file.path}$suffix';
        switch (FileSystemEntity.typeSync(path, followLinks: false)) {
          case FileSystemEntityType.file:
            File(path).deleteSync();
          case FileSystemEntityType.link:
            Link(path).deleteSync();
          default:
            break; // absent, a folder or anything else: left as it is
        }
      }
    } finally {
      _current = _connect();
    }
  }

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  Future<bool> ensureOpen(QueryExecutorUser user) => _current.ensureOpen(user);

  @override
  Future<List<Map<String, Object?>>> runSelect(
    String statement,
    List<Object?> args,
  ) => _current.runSelect(statement, args);

  @override
  Future<int> runInsert(String statement, List<Object?> args) =>
      _current.runInsert(statement, args);

  @override
  Future<int> runUpdate(String statement, List<Object?> args) =>
      _current.runUpdate(statement, args);

  @override
  Future<int> runDelete(String statement, List<Object?> args) =>
      _current.runDelete(statement, args);

  @override
  Future<void> runCustom(String statement, [List<Object?>? args]) =>
      _current.runCustom(statement, args);

  @override
  Future<void> runBatched(BatchedStatements statements) =>
      _current.runBatched(statements);

  @override
  TransactionExecutor beginTransaction() => _current.beginTransaction();

  @override
  QueryExecutor beginExclusive() => _current.beginExclusive();

  @override
  Future<void> close() => _current.close();
}

/// The [DatabaseVersionRefused] behind [error], also when it reached this
/// isolate from the database's background isolate (wrapped in
/// [DriftRemoteException], once per isolate hop); null for any other error.
DatabaseVersionRefused? databaseVersionRefusalIn(Object? error) {
  var cause = error;
  while (cause is DriftRemoteException) {
    cause = cause.remoteCause;
  }
  return cause is DatabaseVersionRefused ? cause : null;
}

/// A database stamped with another schema version than this app's: refused
/// when it opens, before anything is written ([AppDatabase.upgradeSteps]).
/// Its text names the two versions and nothing else (no path), so a log line
/// may carry it (pre-merge review D3-01).
class DatabaseVersionRefused extends UnsupportedError {
  DatabaseVersionRefused(this.found, this.expected)
      : super('No upgrade step from database version $found to $expected');

  /// The version the file is stamped with.
  final int found;

  /// This app's schema version.
  final int expected;

  @override
  String toString() =>
      'DatabaseVersionRefused: found version $found, expected version '
      '$expected';
}

// ── DTO → Companion converters ──────────────────────────────────────────

TracksCompanion tracksCompanionFromDto(ClientTrackDto dto) {
  return TracksCompanion(
    uuidId: Value(dto.uuidId),
    createdAt: Value(dto.createdAt),
    lastUpdated: Value(dto.lastUpdated),
    revision: Value(dto.revision),
    // `filePath` is local download state, never owned by the server, so leave
    // it absent — the `/changes` upsert must not clobber it.
    filePath: Value.absent(),
  );
}

TrackmetadataCompanion trackmetadataCompanionFromDto(ClientTrackDto dto) {
  final meta = dto.metadata;
  return TrackmetadataCompanion(
    uuidId: Value(dto.uuidId),
    title: Value(meta.title),
    artist: Value(meta.artist),
    album: Value(meta.album),
    albumArtist: Value(meta.albumArtist),
    artistId: Value(meta.artistId),
    albumId: Value(meta.albumId),
    year: Value(meta.year),
    date: Value(meta.date),
    genre: Value(meta.genre),
    trackNumber: Value(meta.trackNumber),
    discNumber: Value(meta.discNumber),
    codec: Value(meta.codec),
    duration: Value(meta.duration),
    bitrateKbps: Value(meta.bitrateKbps),
    sampleRateHz: Value(meta.sampleRateHz),
    channels: Value(meta.channels),
    hasAlbumArt: Value(meta.hasAlbumArt),
    coverArtId: Value(meta.coverArtId),
  );
}
