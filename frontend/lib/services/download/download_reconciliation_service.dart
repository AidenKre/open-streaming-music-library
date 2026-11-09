import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/services/download/download_status_reader.dart';

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
/// stalling the event loop on slow filesystems, and DB writes happen inside
/// one transaction.
class DownloadReconciliationService {
  DownloadReconciliationService({
    required AppDatabase db,
    required DownloadStatusReader statusReader,
    Future<bool> Function(String path)? fileExists,
    int batchSize = 32,
  })  : _db = db,
        _statusReader = statusReader,
        _fileExists = fileExists ?? _defaultFileExists,
        _batchSize = batchSize;

  final AppDatabase _db;
  final DownloadStatusReader _statusReader;
  final Future<bool> Function(String path) _fileExists;
  final int _batchSize;

  Future<bool>? _running;

  static Future<bool> _defaultFileExists(String path) => File(path).exists();

  /// Walks `tracks.file_path IS NOT NULL`, clears the download columns for
  /// rows whose file is missing, and bumps the download-status version when
  /// at least one row changed. Concurrent calls dedupe onto the running run
  /// so app startup and a quick resume can't double-scan.
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
    // Only the path that was checked: a download committed meanwhile wins.
    final cleared = await (_db.update(_db.tracks)
          ..where((t) => t.uuidId.equals(trackUuid) & t.filePath.equals(path)))
        .write(clearedDownloadColumns);
    if (cleared == 0) return false;
    _statusReader.bumpVersion();
    return true;
  }

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

    final missing = <String>[];
    for (var i = 0; i < rows.length; i += _batchSize) {
      final end = (i + _batchSize > rows.length) ? rows.length : i + _batchSize;
      final batch = rows.sublist(i, end);
      final results = await Future.wait(batch.map((r) async {
        final path = r.read<String>('file_path');
        final exists = await _fileExists(path);
        return exists ? null : r.read<String>('uuid_id');
      }));
      for (final uuid in results) {
        if (uuid != null) missing.add(uuid);
      }
    }

    // A damaged file (decision 6) is its `file_path`, checked above. A store
    // from before 2026-11-09 may hold a damaged path with `file_path`
    // cleared; one removed outside the app is forgotten too.
    final damaged = await _db
        .customSelect(
          'SELECT uuid_id, damaged_file_path FROM tracks '
          'WHERE damaged_file_path IS NOT NULL AND file_path IS NULL',
        )
        .get();
    final damagedGone = <(String, String)>[];
    for (final r in damaged) {
      final path = r.read<String>('damaged_file_path');
      if (!await _fileExists(path)) {
        damagedGone.add((r.read<String>('uuid_id'), path));
      }
    }

    if (missing.isEmpty && damagedGone.isEmpty) return false;

    await _db.transaction(() async {
      for (final uuid in missing) {
        await (_db.update(_db.tracks)..where((t) => t.uuidId.equals(uuid)))
            .write(clearedDownloadColumns);
      }
      for (final (uuid, path) in damagedGone) {
        await (_db.update(_db.tracks)
              ..where((t) =>
                  t.uuidId.equals(uuid) & t.damagedFilePath.equals(path)))
            .write(const TracksCompanion(damagedFilePath: Value(null)));
      }
    });

    _statusReader.bumpVersion();
    return true;
  }
}
