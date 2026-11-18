import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/clock.dart';
import 'package:path/path.dart' as p;

/// The app-owned roots a cleanup row may point into (stored as its name).
enum OwnedRootKind { downloads }

/// What one cleanup attempt did with a row.
enum OwnedCleanupOutcome {
  /// The file was unlinked and the row cleared.
  deleted,

  /// The file was verifiably absent; the row was cleared.
  absent,

  /// The row could not prove the file is the one it was written for; the
  /// row was dropped with a diagnostic and the file left alone.
  retired,

  /// The unlink failed; the row is kept for a retry.
  failed,

  /// The binding changed since the task started; nothing was written.
  fenced,

  /// The row no longer exists (another attempt finished it).
  missing,
}

/// Keyed FIFO async lock over absolute file paths. Errors in one body never
/// wedge the chain, and a path's entry is dropped once it is idle.
class OwnedPathLocks {
  final Map<String, Future<void>> _tails = {};

  /// Runs [body] after every earlier holder of [path] has finished.
  Future<T> withLock<T>(String path, Future<T> Function() body) {
    final release = Completer<void>();
    final previous = _tails[path] ?? Future<void>.value();
    final mine = release.future;
    _tails[path] = mine;
    return previous.then((_) async {
      try {
        return await body();
      } finally {
        release.complete();
        if (identical(_tails[path], mine)) _tails.remove(path);
      }
    });
  }
}

/// The one app-wide path-lock instance (survives scope rebuilds).
final sharedOwnedPathLocks = OwnedPathLocks();

/// Failed attempts after which a pass reports a permanent failure.
const int _permanentAttempts = 5;
const int _batchSize = 100;

enum _Decision { retire, absent, unlink }

/// Durable clean-up of app-owned files whose reference was dropped.
class OwnedFileCleanup {
  OwnedFileCleanup({
    required AppDatabase db,
    required Future<Directory> Function() documentsDirectory,
    OwnedPathLocks? locks,
    Future<void> Function(File file)? deleteFile,
    Clock clock = const SystemClock(),
  }) : _db = db,
       _documentsDirectory = documentsDirectory,
       _locks = locks ?? sharedOwnedPathLocks,
       _deleteFile = deleteFile ?? ((f) => f.delete()),
       _clock = clock;

  final AppDatabase _db;
  final Future<Directory> Function() _documentsDirectory;
  final OwnedPathLocks _locks;
  final Future<void> Function(File file) _deleteFile;
  final Clock _clock;

  /// Runs [body] holding the lock for [path], the one writers of owned
  /// paths (a download commit) take so a cleanup retry for the same path
  /// waits for them. Never call [cleanRows] for [path] inside [body].
  Future<T> withPathLock<T>(String path, Future<T> Function() body) =>
      _locks.withLock(path, body);

  Future<String> _root() async =>
      p.join((await _documentsDirectory()).path, 'tracks');

  /// Must run inside the caller's transaction (the one dropping the
  /// reference). Returns the inserted row ids. Identity is the size and
  /// mtime of a regular file; anything else (or a stat error) leaves it NULL.
  Future<List<int>> enqueueInTransaction(
    Iterable<String> paths, {
    required String? localBindingId,
  }) async {
    final ids = <int>[];
    for (final path in paths) {
      int? size;
      int? mtime;
      try {
        if (await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.file) {
          final stat = await File(path).stat();
          size = stat.size;
          mtime = stat.modified.microsecondsSinceEpoch;
        }
      } on Object {
        size = null;
        mtime = null;
      }
      ids.add(
        await _db
            .into(_db.ownedFileCleanupEntries)
            .insert(
              OwnedFileCleanupEntriesCompanion.insert(
                path: path,
                rootKind: OwnedRootKind.downloads.name,
                size: Value(size),
                mtime: Value(mtime),
                localBindingId: Value(localBindingId),
                createdAt: _clock.nowUtcMs(),
              ),
            ),
      );
    }
    return ids;
  }

  /// Runs [body] in a transaction unless the binding no longer matches
  /// [token], in which case it returns null and writes nothing. A non-null
  /// token goes through the shared SC-01 [ServerBindingRepository.runFenced];
  /// a null token requires that no binding row exists (immediate attempts in
  /// a store without a binding).
  Future<({T value})?> _fenced<T>(
    String? token,
    Future<T> Function() body,
  ) async {
    if (token != null) {
      try {
        return await ServerBindingRepository(
          _db,
        ).runFenced(token, () async => (value: await body()));
      } on BindingFencedException {
        return null;
      }
    }
    return _db.transaction(() async {
      if (await ServerBindingRepository(_db).current() != null) return null;
      return (value: await body());
    });
  }

  void _retire(String reason, String path) => developer.log(
    'retired cleanup row: $reason: $path',
    name: 'OwnedFileCleanup',
  );

  /// Attempts the given rows now, fenced on [bindingToken]. Never throws: an
  /// unexpected error yields [OwnedCleanupOutcome.failed] and writes nothing.
  Future<Map<int, OwnedCleanupOutcome>> cleanRows(
    Iterable<int> ids, {
    required String? bindingToken,
  }) async {
    final out = <int, OwnedCleanupOutcome>{};
    for (final id in ids) {
      try {
        out[id] = await _cleanOne(id, bindingToken);
      } on Object catch (e) {
        // Never throws: the row stays (attempts are not bumped, the DB may
        // be what is failing) and the caller requests the runner.
        developer.log(
          'cleanup attempt for row $id failed unexpectedly: $e',
          name: 'OwnedFileCleanup',
        );
        out[id] = OwnedCleanupOutcome.failed;
      }
    }
    return out;
  }

  Future<OwnedFileCleanupRow?> _readRow(int id) => (_db.select(
    _db.ownedFileCleanupEntries,
  )..where((r) => r.id.equals(id))).getSingleOrNull();

  Future<OwnedCleanupOutcome> _cleanOne(int id, String? token) async {
    final row = await _readRow(id);
    if (row == null) return OwnedCleanupOutcome.missing;
    final path = row.path;
    final root = await _root();

    // Lexical check, then the resolved (symlink-aware) check.
    var absentPrecheck = false;
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        !p.isWithin(root, path)) {
      return _retireRow(id, token, 'outside the downloads root', path);
    }
    try {
      final resolvedRoot = await Directory(root).resolveSymbolicLinks();
      final resolvedParent = await Directory(
        p.dirname(path),
      ).resolveSymbolicLinks();
      if (resolvedParent != resolvedRoot &&
          !p.isWithin(resolvedRoot, resolvedParent)) {
        return _retireRow(id, token, 'resolves outside the root', path);
      }
    } on FileSystemException {
      absentPrecheck = true; // root or parent missing: the file is absent
    }

    return _locks.withLock(path, () async {
      // Transaction A (fenced): is the path still unreferenced?
      final a = await _fenced<({OwnedFileCleanupRow? row, bool referenced})>(
        token,
        () async {
          final cur = await _readRow(id);
          if (cur == null) return (row: null, referenced: false);
          final ref =
              await (_db.select(_db.tracks)..where(
                    (t) =>
                        t.filePath.equals(path) | t.damagedFilePath.equals(path),
                  )..limit(1))
                  .getSingleOrNull();
          return (row: cur, referenced: ref != null);
        },
      );
      if (a == null) return OwnedCleanupOutcome.fenced;
      final cur = a.value.row;
      if (cur == null) return OwnedCleanupOutcome.missing;

      var decision = _Decision.unlink;
      String retireReason = '';
      if (a.value.referenced) {
        decision = _Decision.retire;
        retireReason = 'a track still references the path';
      } else if (absentPrecheck) {
        decision = _Decision.absent;
      } else {
        // File I/O with no transaction open.
        try {
          final type = await FileSystemEntity.type(path, followLinks: false);
          if (type == FileSystemEntityType.notFound) {
            decision = _Decision.absent;
          } else if (type != FileSystemEntityType.file) {
            decision = _Decision.retire;
            retireReason = 'not a regular file';
          } else if (cur.size == null || cur.mtime == null) {
            decision = _Decision.retire;
            retireReason = 'identity unknown';
          } else if (cur.dev != null || cur.ino != null) {
            decision = _Decision.retire;
            retireReason = 'device/inode cannot be verified';
          } else {
            final stat = await File(path).stat();
            if (stat.size != cur.size ||
                stat.modified.microsecondsSinceEpoch != cur.mtime) {
              decision = _Decision.retire;
              retireReason = 'identity changed (path reused)';
            }
          }
        } on Object catch (e) {
          return _recordFailure(id, token, cur, e);
        }
        if (decision == _Decision.unlink) {
          try {
            await _deleteFile(File(path));
          } on Object catch (e) {
            if (await FileSystemEntity.type(path, followLinks: false) ==
                FileSystemEntityType.notFound) {
              decision = _Decision.absent;
            } else {
              return _recordFailure(id, token, cur, e);
            }
          }
        }
      }

      // Transaction B (fenced): clear the row.
      final b = await _fenced<void>(token, () async {
        await (_db.delete(
          _db.ownedFileCleanupEntries,
        )..where((r) => r.id.equals(id))).go();
      });
      if (b == null) return OwnedCleanupOutcome.fenced;
      if (decision == _Decision.retire) {
        _retire(retireReason, path);
        return OwnedCleanupOutcome.retired;
      }
      return decision == _Decision.absent
          ? OwnedCleanupOutcome.absent
          : OwnedCleanupOutcome.deleted;
    });
  }

  Future<OwnedCleanupOutcome> _retireRow(
    int id,
    String? token,
    String reason,
    String path,
  ) async {
    final r = await _fenced<void>(token, () async {
      await (_db.delete(
        _db.ownedFileCleanupEntries,
      )..where((t) => t.id.equals(id))).go();
    });
    if (r == null) return OwnedCleanupOutcome.fenced;
    _retire(reason, path);
    return OwnedCleanupOutcome.retired;
  }

  Future<OwnedCleanupOutcome> _recordFailure(
    int id,
    String? token,
    OwnedFileCleanupRow cur,
    Object error,
  ) async {
    final r = await _fenced<void>(token, () async {
      await (_db.update(
        _db.ownedFileCleanupEntries,
      )..where((t) => t.id.equals(id))).write(
        OwnedFileCleanupEntriesCompanion(
          attempts: Value(cur.attempts + 1),
          lastError: Value(error.toString()),
        ),
      );
    });
    return r == null ? OwnedCleanupOutcome.fenced : OwnedCleanupOutcome.failed;
  }

  /// The SingleFlightRunner pass body: every pending row, in id order and
  /// batches of 100.
  Future<PassOutcome> runPass(Set<String> reasons) async {
    final String? token;
    try {
      token = (await ServerBindingRepository(_db).current())?.localBindingId;
    } catch (e) {
      // A database of another schema version stays refused until a reset
      // replaces it and rebuilds the scope: a retry cannot help.
      if (databaseVersionRefusalIn(e) != null) return const PassParked();
      rethrow;
    }
    // A pass needs a binding to fence on; a later trigger retries.
    if (token == null) return const PassDone();
    final ids = await (_db.selectOnly(_db.ownedFileCleanupEntries)
          ..addColumns([_db.ownedFileCleanupEntries.id])
          ..orderBy([OrderingTerm.asc(_db.ownedFileCleanupEntries.id)]))
        .map((r) => r.read(_db.ownedFileCleanupEntries.id)!)
        .get();
    final failed = <int>[];
    for (var i = 0; i < ids.length; i += _batchSize) {
      if (i > 0) await Future<void>.delayed(Duration.zero);
      final outcomes = await cleanRows(
        ids.skip(i).take(_batchSize),
        bindingToken: token,
      );
      outcomes.forEach((id, o) {
        if (o == OwnedCleanupOutcome.failed) failed.add(id);
      });
    }
    if (failed.isEmpty) return const PassDone();
    final rows = await (_db.select(
      _db.ownedFileCleanupEntries,
    )..where((r) => r.id.isIn(failed))).get();
    final permanent = rows.any((r) => r.attempts >= _permanentAttempts);
    return PassFailed(
      permanent ? BackoffReason.permanent : BackoffReason.transient,
    );
  }
}
