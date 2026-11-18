import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/local_resettable.dart';

/// The process-wide disk cache, overridden at startup; null means no disk
/// cache.
final coverArtDiskCacheProvider = Provider<BaseCacheManager?>((ref) => null);

/// How often the connection has come back (offline to online) in this
/// scope. A cover tile whose load failed uses it as its retry counter, so it
/// loads again when the connection returns (other-issues row 73).
final coverArtReconnectsProvider =
    NotifierProvider<CoverArtReconnects, int>(CoverArtReconnects.new);

class CoverArtReconnects extends Notifier<int> {
  @override
  int build() {
    ref.listen<bool>(offlineModeProvider, (previous, next) {
      if (previous == true && !next) state++;
    });
    return 0;
  }
}

/// Encapsulates all cover-art caching logic.
///
/// Consumers use this class to obtain image providers for widgets,
/// prefetch upcoming artwork, and resolve file-based URIs for the
/// system media notification (audio service).
class CoverArtCacheManager implements LocalResettable {
  CoverArtCacheManager({
    required ApiClient api,
    BaseCacheManager? cache,
    LocalCoverArtStore? localStore,
    Map<String, String>? authHeaders,
    Future<bool> Function()? mayAttachToken,
  }) : _api = api,
       _cache = cache,
       _localStore = localStore,
       _authHeaders = authHeaders,
       _mayAttachToken = mayAttachToken;

  /// Creates a [CoverArtCacheManager] without a backing cache.
  /// Only for use in tests where the cache is not exercised.
  @visibleForTesting
  CoverArtCacheManager.noop({ApiClient? api})
    : _api = api,
      _cache = null,
      _localStore = null,
      _authHeaders = null,
      _mayAttachToken = null;

  final ApiClient? _api;
  final BaseCacheManager? _cache;
  final LocalCoverArtStore? _localStore;

  /// This scope's auth header, passed per call (spec 7.2). It is never stored
  /// in the cache database, and cache keys stay token-free.
  final Map<String, String>? _authHeaders;

  /// Asked per request before the token is attached (the binding gate's
  /// permit). Null with a token present means no: fail closed.
  final Future<bool> Function()? _mayAttachToken;

  /// Fetches [url] through [cache]. Without an auth header: a plain fetch.
  /// With one: the disk cache is checked first and a still-valid hit is
  /// served without asking the permit (no fetch, so no token). Only when a
  /// fetch is needed does the token go out, and only when the permit says yes
  /// right now; otherwise nothing touches the network -- a stale file on disk
  /// is served, else this throws (callers already treat a failure as "no art").
  Future<File> _fetch(BaseCacheManager cache, String url) async {
    final headers = _authHeaders;
    if (headers == null || headers.isEmpty) return cache.getSingleFile(url);
    final cached = await cache.getFileFromCache(url);
    if (cached != null && cached.validTill.isAfter(DateTime.now())) {
      return cached.file;
    }
    var may = false;
    try {
      may = await (_mayAttachToken?.call() ?? Future.value(false));
    } catch (_) {}
    if (may) return cache.getSingleFile(url, headers: headers);
    if (cached != null) return cached.file;
    throw StateError('cover art not available without the token');
  }

  String _url(int coverArtId) =>
      _api?.coverArtUrl(coverArtId) ?? '/cover_art/$coverArtId';

  /// Returns an [ImageProvider] backed by the disk cache.
  ///
  /// If the image has been downloaded locally (via [LocalCoverArtStore]) it is
  /// served from disk without a network request. Otherwise falls through to
  /// the network cache.
  ///
  /// Optional [cacheWidth] and [cacheHeight] allow the image to be decoded at
  /// the size the UI actually needs instead of full resolution. A different
  /// [retry] gives a different image key, so a load that failed is tried
  /// again instead of served from the image cache.
  ImageProvider imageProvider(
    int coverArtId, {
    int? cacheWidth,
    int? cacheHeight,
    int retry = 0,
  }) {
    final local = _localStore;
    if (local != null && local.has(coverArtId)) {
      return ResizeImage.resizeIfNeeded(
        cacheWidth,
        cacheHeight,
        FileImage(local.fileFor(coverArtId)),
      );
    }
    final url = _url(coverArtId);
    final cache = _cache;
    final ImageProvider provider = cache == null
        ? NetworkImage(url)
        : CoverArtImageProvider(
            url,
            cache,
            () => _fetch(cache, url),
            retry: retry,
          );
    return ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, provider);
  }

  /// Prefetches cover art so it is ready when the UI or audio service needs it.
  ///
  /// Called from grid item builders, so it runs on every rebuild: it must be
  /// cheap for art that's already here and must never throw. Locally
  /// downloaded art is skipped; `getSingleFile` serves a still-valid cached
  /// copy without touching the network (`downloadFile` always re-downloads).
  /// Fire-and-forget and best-effort, so a failed fetch (offline, server
  /// error) is dropped -- `ignore()` keeps it from surfacing as an unhandled
  /// async error.
  void prefetch(List<int> coverArtIds) {
    final cache = _cache;
    if (cache == null) return;
    final local = _localStore;
    for (final id in coverArtIds.toSet()) {
      if (local != null && local.has(id)) continue;
      _fetch(cache, _url(id)).ignore();
    }
  }

  Future<void> clear() async {
    await _cache?.emptyCache();
    await _localStore?.clear();
  }

  // --- LocalResettable -------------------------------------------------------
  @override
  int get resetPriority => ResetPriority.clearCaches;

  @override
  Future<void> resetLocalState() => clear();

  /// The `file://` URI of locally downloaded art, known without waiting;
  /// null when it isn't stored locally (then use [resolveArtUri]).
  Uri? localArtUri(int coverArtId) {
    final local = _localStore;
    if (local == null || !local.has(coverArtId)) return null;
    return Uri.file(local.fileFor(coverArtId).path);
  }

  /// Resolves the best available [Uri] for [MediaItem.artUri].
  ///
  /// Returns a `file://` URI when the image is stored locally, cached, or can
  /// be fetched into the cache with the auth header. Never a network URL (the
  /// OS cannot send the header): `null` when the track has no cover art, there
  /// is no cache, or the fetch fails (spec 7.3).
  Future<Uri?> resolveArtUri({
    required bool hasAlbumArt,
    required int? coverArtId,
  }) async {
    if (!hasAlbumArt || coverArtId == null) return null;

    final local = localArtUri(coverArtId);
    if (local != null) return local;

    final url = _url(coverArtId);
    final cache = _cache;
    if (cache != null) {
      final fileInfo = await cache.getFileFromCache(url);
      if (fileInfo != null) return Uri.file(fileInfo.file.path);
      try {
        final file = await _fetch(cache, url);
        return Uri.file(file.path);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

/// An [ImageProvider] that loads images through [BaseCacheManager].
///
/// On first request the image is fetched from the network and stored in the
/// disk cache. Subsequent requests serve the cached file directly.
@visibleForTesting
class CoverArtImageProvider extends ImageProvider<CoverArtImageProvider> {
  final String url;
  final BaseCacheManager cache;

  /// Loads the file (decides per call whether the token may be sent). Not
  /// part of identity ([==], [hashCode]), so the image cache key stays
  /// token-free.
  final Future<File> Function() load;

  /// Part of identity: a new value is a new image-cache key (a retry).
  final int retry;

  const CoverArtImageProvider(this.url, this.cache, this.load,
      {this.retry = 0});

  @override
  ImageStreamCompleter loadImage(
    CoverArtImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode),
      scale: 1.0,
    );
  }

  Future<ui.Codec> _loadAsync(ImageDecoderCallback decode) async {
    final file = await load();
    final bytes = await file.readAsBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  Future<CoverArtImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  bool operator ==(Object other) =>
      other is CoverArtImageProvider &&
      other.url == url &&
      other.retry == retry;

  @override
  int get hashCode => Object.hash(url, retry);

  @override
  String toString() => 'CoverArtImageProvider($url, retry: $retry)';
}
