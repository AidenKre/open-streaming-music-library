import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/quality_presets.dart';

typedef TempDirectoryProvider = Future<Directory> Function();

/// Build the streaming URL for a track. When [quality] is `null` or
/// `original`, no `quality` query parameter is sent — the server returns the
/// untouched source file. Any other preset triggers server-side transcoding.
Uri buildTrackStreamUri(String uuidId, {String? quality}) {
  final baseUri = Uri.parse(ApiClient.instance.baseUrl);
  final basePath = baseUri.pathSegments.where((segment) => segment.isNotEmpty);
  final query = (quality == null || quality == originalQuality)
      ? null
      : {'quality': quality};
  return baseUri.replace(
    pathSegments: [...basePath, 'tracks', uuidId, 'stream'],
    queryParameters: query,
  );
}

abstract class TrackCacheManager {
  File? getCachedFile(String uuidId);
  Future<void> prefetch(TrackUI track);
  Future<void> cancelPrefetch();
  Future<void> clear();
  Future<void> evict(String uuidId);
}

const _contentTypeToExtension = <String, String>{
  'audio/flac': '.flac',
  'audio/mpeg': '.mp3',
  'audio/mp4': '.m4a',
  'audio/x-m4a': '.m4a',
  'audio/alac': '.m4a',
  'audio/aac': '.aac',
  'audio/ogg': '.ogg',
  'audio/wav': '.wav',
  'audio/x-wav': '.wav',
  'audio/webm': '.webm',
};

String _extensionFromContentType(String? contentType) {
  if (contentType == null) return '.audio';
  final mimeType = contentType.split(';').first.trim().toLowerCase();
  return _contentTypeToExtension[mimeType] ?? '.audio';
}

class HttpTrackCacheManager implements TrackCacheManager {
  final Directory _cacheDirectory;
  final ApiClient _apiClient;

  StreamSubscription<List<int>>? _prefetchSubscription;
  File? _prefetchPartialFile;
  Completer<void>? _prefetchCompleter;
  Completer<void>? _prefetchDone;
  int _prefetchGeneration = 0;

  HttpTrackCacheManager._(this._cacheDirectory, this._apiClient);

  static Future<HttpTrackCacheManager> create({
    TempDirectoryProvider? tempDirectoryProvider,
    ApiClient? apiClient,
  }) async {
    final tempDirectory = await (tempDirectoryProvider ?? getTemporaryDirectory)();
    final cacheDirectory = Directory(
      p.join(tempDirectory.path, 'track_cache'),
    );
    await cacheDirectory.create(recursive: true);
    await _clearDirectory(cacheDirectory);
    return HttpTrackCacheManager._(
      cacheDirectory,
      apiClient ?? ApiClient.instance,
    );
  }

  @visibleForTesting
  Directory get cacheDirectory => _cacheDirectory;

  File _partialFileFor(String uuidId) =>
      File(p.join(_cacheDirectory.path, '$uuidId.part'));

  @override
  File? getCachedFile(String uuidId) {
    return _findByUuid(uuidId);
  }

  File? _findByUuid(String uuidId) {
    if (!_cacheDirectory.existsSync()) return null;
    final prefix = '$uuidId.';
    for (final entity in _cacheDirectory.listSync()) {
      if (entity is File) {
        final name = p.basename(entity.path);
        if (name.startsWith(prefix) && !name.endsWith('.part')) {
          return entity;
        }
      }
    }
    return null;
  }

  @override
  Future<void> prefetch(TrackUI track) async {
    final generation = ++_prefetchGeneration;
    final done = Completer<void>();
    _prefetchDone = done;

    try {
      await _cancelActivePrefetch();
      if (generation != _prefetchGeneration) {
        return;
      }

      final existing = getCachedFile(track.uuidId);
      if (existing != null) {
        return;
      }

      final partialFile = _partialFileFor(track.uuidId);

      try {
        await _cacheDirectory.create(recursive: true);
        await _deleteIfExists(partialFile);

        final http.StreamedResponse response;
        try {
          response = await _apiClient.send(
            () => http.Request('GET', buildTrackStreamUri(track.uuidId)),
          );
        } on ApiException {
          await _deleteIfExists(partialFile);
          return;
        } on NetworkException {
          await _deleteIfExists(partialFile);
          return;
        } catch (_) {
          // Defensive fallback for unexpected exceptions.
          await _deleteIfExists(partialFile);
          return;
        }
        if (generation != _prefetchGeneration) {
          await _deleteIfExists(partialFile);
          return;
        }
        // ApiClient.send guarantees a 2xx response or throws.

        final ext = _extensionFromContentType(response.headers['content-type']);
        final cachedFile = File(
          p.join(_cacheDirectory.path, '${track.uuidId}$ext'),
        );

        final sink = partialFile.openWrite();
        final completer = Completer<void>();
        var downloadCompleted = false;

        _prefetchPartialFile = partialFile;
        _prefetchCompleter = completer;
        _prefetchSubscription = response.stream.listen(
          sink.add,
          onDone: () {
            downloadCompleted = true;
            if (!completer.isCompleted) {
              completer.complete();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(error, stackTrace);
            }
          },
          cancelOnError: true,
        );

        await completer.future;

        if (!downloadCompleted) {
          // Download was interrupted (cancel unblocked the completer).
          try { await sink.close(); } catch (_) {}
          await _deleteIfExists(partialFile);
          return;
        }

        await sink.flush();
        await sink.close();

        // Use sync operations to prevent cancel from interleaving
        // between the check and the rename.
        if (cachedFile.existsSync()) cachedFile.deleteSync();
        partialFile.renameSync(cachedFile.path);
      } catch (_) {
        await _deleteIfExists(partialFile);
      } finally {
        if (_prefetchPartialFile?.path == partialFile.path) {
          _clearActivePrefetchHandles();
        }
      }
    } finally {
      if (!done.isCompleted) {
        done.complete();
      }
    }
  }

  @override
  Future<void> cancelPrefetch() async {
    _prefetchGeneration++;
    await _cancelActivePrefetch();
    // Wait for the prefetch coroutine to finish its cleanup/rename
    // so that any completed download is available via getCachedFile.
    final done = _prefetchDone;
    if (done != null && !done.isCompleted) {
      await done.future;
    }
  }

  @override
  Future<void> clear() async {
    await cancelPrefetch();
    if (!await _cacheDirectory.exists()) {
      return;
    }

    await for (final entity in _cacheDirectory.list()) {
      if (entity is File) {
        await entity.delete();
      }
    }
  }

  @override
  Future<void> evict(String uuidId) async {
    final file = _findByUuid(uuidId);
    if (file != null) {
      await _deleteIfExists(file);
    }
  }

  Future<void> _cancelActivePrefetch() async {
    final subscription = _prefetchSubscription;
    final completer = _prefetchCompleter;

    _clearActivePrefetchHandles();

    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    await subscription?.cancel();
    // Sink close and partial file cleanup are handled by the prefetch
    // coroutine itself, which checks the downloadCompleted flag.
  }

  void _clearActivePrefetchHandles() {
    _prefetchSubscription = null;
    _prefetchPartialFile = null;
    _prefetchCompleter = null;
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) {
      await file.delete();
    }
  }

  static Future<void> _clearDirectory(Directory directory) async {
    if (!await directory.exists()) {
      return;
    }
    await for (final entity in directory.list()) {
      await entity.delete(recursive: true);
    }
  }

  @visibleForTesting
  Future<void> close() async {
    await cancelPrefetch();
  }
}
