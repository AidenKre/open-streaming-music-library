import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/services/local_resettable.dart';

/// Persists cover art on disk using only the cover-art id (no sha256/phash).
///
/// Files are stored as `{coverArtId}.bin` under the app documents directory.
/// The store is content-agnostic — bytes are written verbatim from the server
/// response, and consumers read them back as raw bytes for decoding.
class LocalCoverArtStore implements LocalResettable {
  static int _tmpCounter = 0;

  /// Bumped by every reset. A download that started before a reset (its
  /// response may land long after) must not store the old library's cover.
  int _resetEpoch = 0;

  final Directory _directory;
  final ApiClient _apiClient;

  /// Signed out (a 401 closed the binding gate): [download] sends nothing.
  final bool Function() _isSignedOut;

  LocalCoverArtStore(
    this._directory,
    this._apiClient, {
    bool Function()? isSignedOut,
  }) : _isSignedOut = isSignedOut ?? (() => false);

  /// Resolves and creates `<base>/cover_art`.
  static Future<Directory> ensureDirectory({
    Future<Directory> Function()? directoryProvider,
  }) async {
    final base =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    final dir = Directory(p.join(base.path, 'cover_art'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<LocalCoverArtStore> create({
    Future<Directory> Function()? directoryProvider,
    required ApiClient apiClient,
    bool Function()? isSignedOut,
  }) async {
    final dir = await ensureDirectory(directoryProvider: directoryProvider);
    return LocalCoverArtStore(dir, apiClient, isSignedOut: isSignedOut);
  }

  @visibleForTesting
  Directory get directory => _directory;

  File fileFor(int coverArtId) =>
      File(p.join(_directory.path, '$coverArtId.bin'));

  bool has(int coverArtId) => fileFor(coverArtId).existsSync();

  /// Downloads cover art bytes from the server and stores them locally.
  /// No-ops when the file already exists. Returns true on success (or already
  /// present), false on any failure (network, HTTP, or filesystem), and
  /// without a request while signed out (a 401 closed the gate).
  /// Cover art is best-effort — callers (e.g. DownloadManager) must not let
  /// a failure here fail the parent operation. The request is intentionally
  /// single-attempt and does NOT flip global offline mode: cover art is a
  /// high-volume endpoint (one fetch per album/artist tile), so a flaky
  /// thumbnail should fall back to its placeholder, not stall on 3 retries
  /// or darken the whole UI by entering offline mode.
  Future<bool> download(int coverArtId) async {
    final target = fileFor(coverArtId);
    if (target.existsSync()) return true;
    if (_isSignedOut()) return false;

    // Unique per call: concurrent downloads of one id must not share a temp
    // file (static counter, as store instances can share the folder).
    final tmp = File('${target.path}.partial-${_tmpCounter++}');
    final epoch = _resetEpoch;
    try {
      final bytes = await _apiClient.getBytes(
        ['cover_art', coverArtId.toString()],
        retry: false,
        triggerOfflineHook: false,
      );
      // Write to a temp file then rename so partial bytes are never visible.
      await tmp.writeAsBytes(bytes, flush: true);
      if (epoch != _resetEpoch) {
        await tmp.delete();
        return false;
      }
      await tmp.rename(target.path);
      if (epoch != _resetEpoch) {
        // A reset started during the rename: it may have missed this file.
        await target.delete();
        return false;
      }
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

  /// Per cover id: the tail of the lookups and removals queued on it.
  final Map<int, Future<void>> _idTails = {};

  /// Runs [body] after every earlier lookup or removal of [coverArtId].
  Future<T> _serialized<T>(int coverArtId, Future<T> Function() body) {
    final release = Completer<void>();
    final previous = _idTails[coverArtId] ?? Future<void>.value();
    final mine = release.future;
    _idTails[coverArtId] = mine;
    return previous.then((_) async {
      try {
        return await body();
      } finally {
        release.complete();
        if (identical(_idTails[coverArtId], mine)) _idTails.remove(coverArtId);
      }
    });
  }

  /// Whether the cover is stored, answered only after a removal of it that
  /// is under way has finished (see [removeIfUnused]).
  Future<bool> holds(int coverArtId) =>
      _serialized(coverArtId, () async => has(coverArtId));

  /// Deletes the stored cover unless [inUse] says something still uses it.
  /// The question and the delete run as one step against [holds]: a
  /// download committed meanwhile either counts as a use or, asking after
  /// the delete, fetches the cover again. True when a file was deleted.
  Future<bool> removeIfUnused(
    int coverArtId,
    Future<bool> Function() inUse,
  ) =>
      _serialized(coverArtId, () async {
        if (await inUse()) return false;
        final f = fileFor(coverArtId);
        if (!await f.exists()) return false;
        await f.delete();
        return true;
      });

  Future<void> clear() async {
    if (!await _directory.exists()) return;
    await for (final entity in _directory.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }
  }

  // --- LocalResettable -------------------------------------------------------
  @override
  int get resetPriority => ResetPriority.deleteFiles;

  @override
  Future<void> resetLocalState() async {
    _resetEpoch++;
    await clear();
    // Decoded FileImages are keyed by path; a reused cover id in the next
    // library would otherwise show the previous library's picture.
    try {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
    } on FlutterError {
      // No binding means no decoded images to evict.
    }
  }
}
