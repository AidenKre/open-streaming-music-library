import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';

/// Displays cover art from the backend when [hasAlbumArt] is true and
/// [coverArtId] is non-null. Falls back to [fallback] while loading, on error,
/// or when either condition is not met. A tile whose load failed loads again
/// when the connection returns (other-issues row 73); one that did not fail
/// keeps its image.
class CoverArtImage extends ConsumerStatefulWidget {
  static const int _maxDecodeDimension = 2048;

  final bool hasAlbumArt;
  final int? coverArtId;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final Widget fallback;

  const CoverArtImage({
    super.key,
    required this.hasAlbumArt,
    required this.coverArtId,
    this.width,
    this.height,
    required this.borderRadius,
    required this.fallback,
  });

  @override
  ConsumerState<CoverArtImage> createState() => _CoverArtImageState();
}

class _CoverArtImageState extends ConsumerState<CoverArtImage> {
  /// The retry counter of the image key in use.
  int _retry = 0;

  /// The load under [_retry] failed (set from the error builder, which runs
  /// during a build: no setState).
  bool _failed = false;

  @override
  void didUpdateWidget(CoverArtImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverArtId != widget.coverArtId) _failed = false;
  }

  @override
  Widget build(BuildContext context) {
    final hasAlbumArt = widget.hasAlbumArt;
    final coverArtId = widget.coverArtId;
    final width = widget.width;
    final height = widget.height;
    final fallback = widget.fallback;
    if (!hasAlbumArt || coverArtId == null) return fallback;
    // A failed tile takes the reconnect count as its new retry counter.
    final reconnects = ref.watch(coverArtReconnectsProvider);
    if (_failed && reconnects != _retry) {
      _retry = reconnects;
      _failed = false;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final devicePixelRatio =
            MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
        final cacheWidth = _bucketedPhysicalPixels(
          width ?? _finiteDimension(constraints.maxWidth),
          devicePixelRatio,
        );
        final cacheHeight = _bucketedPhysicalPixels(
          height ?? _finiteDimension(constraints.maxHeight),
          devicePixelRatio,
        );

        return ClipRRect(
          borderRadius: widget.borderRadius,
          child: Image(
            // A new state per retry: the old load's error must not mark the
            // retried load failed (review F2).
            key: ValueKey(_retry),
            image: ref.watch(coverArtCacheProvider).imageProvider(
              coverArtId,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
              retry: _retry,
            ),
            width: width,
            height: height,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) {
              _failed = true;
              return fallback;
            },
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded || frame != null) return child;
              return fallback;
            },
          ),
        );
      },
    );
  }

  double? _finiteDimension(double dimension) {
    if (!dimension.isFinite || dimension <= 0) {
      return null;
    }
    return dimension;
  }

  int? _bucketedPhysicalPixels(double? logicalPixels, double devicePixelRatio) {
    if (logicalPixels == null) {
      return null;
    }

    final physicalPixels = (logicalPixels * devicePixelRatio).ceil();
    return physicalPixels.clamp(1, CoverArtImage._maxDecodeDimension);
  }
}
