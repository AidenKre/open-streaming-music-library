import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;

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

  Future<bool> _run() async {
    final rows = await _db
        .customSelect(
          'SELECT uuid_id, file_path FROM tracks WHERE file_path IS NOT NULL',
        )
        .get();
    if (rows.isEmpty) return false;

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

    if (missing.isEmpty) return false;

    await _db.transaction(() async {
      for (final uuid in missing) {
        await (_db.update(_db.tracks)..where((t) => t.uuidId.equals(uuid)))
            .write(const TracksCompanion(
          filePath: Value(null),
          downloadedBitrateKbps: Value(null),
          fileSizeBytes: Value(null),
          downloadedQuality: Value(null),
        ));
      }
    });

    _statusReader.bumpVersion();
    return true;
  }
}
