import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';

import 'package:frontend/database/database.dart';

/// Owns the change-counter that the UI watches to invalidate derived "is this
/// downloaded?" providers, and exposes the aggregate DB queries that report
/// which uuids have a real file on disk.
///
/// Extracted from DownloadManager so the read-side concerns sit alone — the
/// downloader and worker pool only need to call [bumpVersion] when something
/// changes.
class DownloadStatusReader {
  DownloadStatusReader({required AppDatabase db}) : _db = db;

  final AppDatabase _db;
  bool _disposed = false;

  /// Notified once when the underlying tracks table changes such that
  /// downloaded-status checks may have new answers. Lets the UI invalidate
  /// derived providers without polling the DB.
  final ValueNotifier<int> downloadStatusVersion = ValueNotifier<int>(0);

  void bumpVersion() {
    if (_disposed) return;
    downloadStatusVersion.value += 1;
  }

  /// Returns the set of uuid_ids that have a non-null `file_path` (and the
  /// file actually exists on disk). Used by aggregate "fully downloaded"
  /// queries for albums/artists.
  Future<Set<String>> downloadedUuidsForUuids(Iterable<String> uuids) async {
    final unique = uuids.toSet().toList(growable: false);
    if (unique.isEmpty) return const <String>{};
    final placeholders = List.filled(unique.length, '?').join(', ');
    final rows = await _db
        .customSelect(
          'SELECT uuid_id, file_path FROM tracks '
          'WHERE uuid_id IN ($placeholders) AND file_path IS NOT NULL',
          variables: unique.map(Variable.withString).toList(),
        )
        .get();
    final result = <String>{};
    for (final r in rows) {
      final path = r.readNullable<String>('file_path');
      if (path != null && await File(path).exists()) {
        result.add(r.read<String>('uuid_id'));
      }
    }
    return result;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    downloadStatusVersion.dispose();
  }
}
