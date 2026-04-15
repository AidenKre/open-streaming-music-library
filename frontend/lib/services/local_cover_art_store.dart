import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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
  final http.Client _client;
  final bool _ownsClient;

  LocalCoverArtStore._(
    this._directory, {
    required http.Client client,
    required bool ownsClient,
  })  : _client = client,
        _ownsClient = ownsClient;

  static Future<LocalCoverArtStore> create({
    http.Client? client,
    Future<Directory> Function()? directoryProvider,
  }) async {
    final base =
        await (directoryProvider ?? getApplicationDocumentsDirectory)();
    final dir = Directory(p.join(base.path, 'cover_art'));
    await dir.create(recursive: true);
    return LocalCoverArtStore._(
      dir,
      client: client ?? http.Client(),
      ownsClient: client == null,
    );
  }

  @visibleForTesting
  Directory get directory => _directory;

  File fileFor(int coverArtId) =>
      File(p.join(_directory.path, '$coverArtId.bin'));

  bool has(int coverArtId) => fileFor(coverArtId).existsSync();

  /// Downloads cover art bytes from the server and stores them locally.
  /// No-ops when the file already exists. Returns true on success (or already
  /// present), false if the download failed.
  Future<bool> download(int coverArtId) async {
    final target = fileFor(coverArtId);
    if (target.existsSync()) return true;

    final url = ApiClient.instance.coverArtUrl(coverArtId);
    try {
      final response = await _client.get(Uri.parse(url));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return false;
      }
      // Write to a temp file then rename so partial bytes are never visible.
      final tmp = File('${target.path}.partial');
      await tmp.writeAsBytes(response.bodyBytes, flush: true);
      await tmp.rename(target.path);
      return true;
    } catch (_) {
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

  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}
