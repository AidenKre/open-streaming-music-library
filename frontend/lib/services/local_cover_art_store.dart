import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:frontend/api/api_client.dart';

/// Persists cover art on disk using only the cover-art id (no sha256/phash).
///
/// Files are stored as `{coverArtId}.bin` under the app documents directory.
/// The store is content-agnostic — bytes are written verbatim from the server
/// response, and consumers read them back as raw bytes for decoding.
class LocalCoverArtStore {
  final Directory _directory;
  final ApiClient _apiClient;

  LocalCoverArtStore._(this._directory, this._apiClient);

  static Future<LocalCoverArtStore> create({
    Future<Directory> Function()? directoryProvider,
    ApiClient? apiClient,
  }) async {
    final base =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    final dir = Directory(p.join(base.path, 'cover_art'));
    await dir.create(recursive: true);
    return LocalCoverArtStore._(dir, apiClient ?? ApiClient.instance);
  }

  @visibleForTesting
  Directory get directory => _directory;

  File fileFor(int coverArtId) =>
      File(p.join(_directory.path, '$coverArtId.bin'));

  bool has(int coverArtId) => fileFor(coverArtId).existsSync();

  /// Downloads cover art bytes from the server and stores them locally.
  /// No-ops when the file already exists. Returns true on success (or already
  /// present), false on any failure (network, HTTP, or filesystem).
  /// ApiClient handles transient network retries internally; a returned
  /// `false` means the failure survived retries or could not be persisted.
  /// Cover art is best-effort — callers (e.g. DownloadManager) must not let
  /// a failure here fail the parent operation.
  Future<bool> download(int coverArtId) async {
    final target = fileFor(coverArtId);
    if (target.existsSync()) return true;

    final tmp = File('${target.path}.partial');
    try {
      final bytes = await _apiClient.getBytes(
        ['cover_art', coverArtId.toString()],
      );
      // Write to a temp file then rename so partial bytes are never visible.
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
      return true;
    } catch (_) {
      // Any failure (ApiException, NetworkException, FileSystemException,
      // etc.) is treated as a soft failure. Best-effort cleanup so failed
      // downloads don't accumulate orphan `.partial` files.
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  Future<void> remove(int coverArtId) async {
    final f = fileFor(coverArtId);
    if (await f.exists()) {
      await f.delete();
    }
  }

  Future<void> clear() async {
    if (!await _directory.exists()) return;
    await for (final entity in _directory.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }
  }
}
