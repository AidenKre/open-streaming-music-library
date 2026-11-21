import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/services/download/download_status_reader.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';

/// Reconciles `tracks.file_path` against the filesystem.
///
/// `file_path IS NOT NULL` is the in-DB source of truth for "is this track
/// downloaded?". That's only safe if rows pointing at files the OS has
/// removed (manual cleanup, app-data reset, OS-level cache eviction on iOS)
/// get cleared promptly. This service walks the downloaded rows, drops the
/// download-related columns for any whose file no longer exists, and bumps
/// the change-version so derived UI providers refresh.
///
/// Designed to be cheap: a single SELECT pulls just the rows with a non-null
/// `file_path`, file checks are batched in small concurrent groups to avoid
/// stalling the event loop on slow filesystems, and each missing row is
/// re-checked and cleared under its path lock.
class DownloadReconciliationService {
  DownloadReconciliationService({
    required AppDatabase db,
    required DownloadStatusReader statusReader,
    Future<bool> Function(String path)? fileExists,
    OwnedPathLocks? locks,
    int batchSize = 32,
  })  : _db = db,
        _statusReader = statusReader,
        _fileExists = fileExists ?? _defaultFileExists,
        _locks = locks ?? sharedOwnedPathLocks,
        _batchSize = batchSize;

  final AppDatabase _db;
  final DownloadStatusReader _statusReader;
  final Future<bool> Function(String path) _fileExists;
  final OwnedPathLocks _locks;
  final int _batchSize;

  Future<bool>? _running;

  static Future<bool> _defaultFileExists(String path) => File(path).exists();

  /// Walks `tracks.file_path IS NOT NULL`, clears the download columns for
  /// rows whose file is missing, and bumps the download-status version when
  /// at least one row changed. Concurrent calls dedupe onto the running run
  /// so app startup and a quick resume can't double-scan. A damaged download
  /// (decision 6) is its `file_path`, so it is checked here too, and clearing
  /// it drops its mark.
  ///
  /// Returns true iff any rows were updated.
  Future<bool> reconcile() {
    return _running ??= _run().whenComplete(() => _running = null);
  }

  /// Reconciles one track (asked by playback when a recorded file turned
  /// out missing). Returns true iff its download columns were cleared.
  Future<bool> reconcileTrack(String trackUuid) async {
    final row = await (_db.select(_db.tracks)
          ..where((t) => t.uuidId.equals(trackUuid)))
        .getSingleOrNull();
    final path = row?.filePath;
    if (path == null || await _fileExists(path)) return false;
    if (!await _clearIfStillMissing(trackUuid, path)) return false;
    _statusReader.bumpVersion();
    return true;
  }

  /// Under the path lock (the downloader holds it from rename to DB write),
  /// re-checks that [path] is still missing and clears the download columns
  /// only if the row still points at that exact path. A download committed
  /// meanwhile wins. Returns true iff the row changed. Never deletes a file.
  Future<bool> _clearIfStillMissing(String uuid, String path) =>
      _locks.withLock(path, () async {
        if (await _fileExists(path)) return false;
        final changed = await (_db.update(_db.tracks)
              ..where((t) => t.uuidId.equals(uuid) & t.filePath.equals(path)))
            .write(clearedDownloadColumns);
        return changed > 0;
      });

  /// Marks a download that is on disk but failed to play as damaged
  /// (decision 6; playback marks only with evidence). `file_path` and the
  /// other download columns are kept, so a re-download uses the original
  /// quality; the mark alone makes it an unusable download
  /// (`usableDownloadPredicate`): the track streams online and is skipped
  /// offline. The file is kept. Only the path that failed: a download
  /// committed meanwhile wins. Returns true iff the row changed.
  Future<bool> markDamaged(String trackUuid, String path) async {
    final changed = await (_db.update(_db.tracks)
          ..where((t) =>
              t.uuidId.equals(trackUuid) &
              t.filePath.equals(path) &
              t.damagedFilePath.isNull()))
        .write(TracksCompanion(damagedFilePath: Value(path)));
    if (changed == 0) return false;
    _statusReader.bumpVersion();
    return true;
  }

  Future<bool> _run() async {
    final rows = await _db
        .customSelect(
          'SELECT uuid_id, file_path FROM tracks WHERE file_path IS NOT NULL',
        )
        .get();

    final missing = <(String, String)>[];
    for (var i = 0; i < rows.length; i += _batchSize) {
      final end = (i + _batchSize > rows.length) ? rows.length : i + _batchSize;
      final batch = rows.sublist(i, end);
      final results = await Future.wait(batch.map((r) async {
        final path = r.read<String>('file_path');
        final exists = await _fileExists(path);
        return exists ? null : (r.read<String>('uuid_id'), path);
      }));
      for (final gone in results) {
        if (gone != null) missing.add(gone);
      }
    }

    if (missing.isEmpty) return false;

    // Per row: path lock, re-check, then the guarded write (no lock is taken
    // inside a transaction).
    // A failure on a later row still publishes the rows already cleared.
    var changed = false;
    try {
      for (final (uuid, path) in missing) {
        if (await _clearIfStillMissing(uuid, path)) changed = true;
      }
    } finally {
      if (changed) _statusReader.bumpVersion();
    }
    return changed;
  }
}
