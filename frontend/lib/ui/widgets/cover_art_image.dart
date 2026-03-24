import 'package:flutter/material.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';

/// Displays cover art from the backend when [hasAlbumArt] is true and
/// [coverArtId] is non-null. Falls back to [fallback] while loading, on error,
/// or when either condition is not met.
class CoverArtImage extends StatelessWidget {
  static const List<int> _decodeBuckets = [96, 384, 768];

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
  Widget build(BuildContext context) {
    if (!hasAlbumArt || coverArtId == null) return fallback;

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
          borderRadius: borderRadius,
          child: Image(
            image: coverArtCache.imageProvider(
              coverArtId!,
              cacheWidth: cacheWidth,
              cacheHeight: cacheHeight,
            ),
            width: width,
            height: height,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallback,
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

    final physicalPixels = logicalPixels * devicePixelRatio;
    return _decodeBuckets.reduce((best, candidate) {
      final bestDistance = (best - physicalPixels).abs();
      final candidateDistance = (candidate - physicalPixels).abs();
      return candidateDistance < bestDistance ? candidate : best;
    });
  }
}
