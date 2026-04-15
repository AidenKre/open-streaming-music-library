import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/services/local_cover_art_store.dart';

/// Global instance shared by all consumers. Initialised once at app startup
/// via [initCoverArtCache] and read by the Riverpod provider, widgets, and
/// the prefetch helper.
late CoverArtCacheManager coverArtCache;

/// Call once during app startup (e.g. in `main()`).
/// An optional [manager] can be passed for testing.
void initCoverArtCache([CoverArtCacheManager? manager]) {
  coverArtCache = manager ?? CoverArtCacheManager();
}

/// Encapsulates all cover-art caching logic.
///
/// Consumers use this class to obtain image providers for widgets,
/// prefetch upcoming artwork, and resolve file-based URIs for the
/// system media notification (audio service).
class CoverArtCacheManager {
  CoverArtCacheManager({BaseCacheManager? cache, LocalCoverArtStore? localStore})
    : _cache = cache ?? DefaultCacheManager(),
      _localStore = localStore;

  /// Creates a [CoverArtCacheManager] without a backing cache.
  /// Only for use in tests where the cache is not exercised.
  @visibleForTesting
  CoverArtCacheManager.noop() : _cache = null, _localStore = null;

  final BaseCacheManager? _cache;
  final LocalCoverArtStore? _localStore;

  String _url(int coverArtId) => ApiClient.instance.coverArtUrl(coverArtId);

  /// Returns an [ImageProvider] backed by the disk cache.
  ///
  /// If the image has been downloaded locally (via [LocalCoverArtStore]) it is
  /// served from disk without a network request. Otherwise falls through to
  /// the network cache.
  ///
  /// Optional [cacheWidth] and [cacheHeight] allow the image to be decoded at
  /// the size the UI actually needs instead of full resolution.
  ImageProvider imageProvider(
    int coverArtId, {
    int? cacheWidth,
    int? cacheHeight,
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
        : CoverArtImageProvider(url, cache);
    return ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, provider);
  }

  /// Prefetches cover art so it is ready when the UI or audio service needs it.
  void prefetch(List<int> coverArtIds) {
    final cache = _cache;
    if (cache == null) return;
    for (final id in coverArtIds) {
      cache.downloadFile(_url(id));
    }
  }

  /// Resolves the best available [Uri] for [MediaItem.artUri].
  ///
  /// Returns a `file://` URI when the image is available locally (either via
  /// [LocalCoverArtStore] or the network cache), a network URL when it is not,
  /// or `null` when the track has no cover art.
  Future<Uri?> resolveArtUri({
    required bool hasAlbumArt,
    required int? coverArtId,
  }) async {
    if (!hasAlbumArt || coverArtId == null) return null;

    final local = _localStore;
    if (local != null && local.has(coverArtId)) {
      return Uri.file(local.fileFor(coverArtId).path);
    }

    final url = _url(coverArtId);
    final cache = _cache;
    if (cache != null) {
      final fileInfo = await cache.getFileFromCache(url);
      if (fileInfo != null) return Uri.file(fileInfo.file.path);
    }
    return Uri.parse(url);
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

  const CoverArtImageProvider(this.url, this.cache);

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
    final file = await cache.getSingleFile(url);
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
      other is CoverArtImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
