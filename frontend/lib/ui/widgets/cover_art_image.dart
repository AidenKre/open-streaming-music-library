import 'package:flutter/material.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';

/// Displays cover art from the backend when [hasAlbumArt] is true and
/// [coverArtId] is non-null. Falls back to [fallback] while loading, on error,
/// or when either condition is not met.
class CoverArtImage extends StatelessWidget {
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

    return ClipRRect(
      borderRadius: borderRadius,
      child: Image(
        image: coverArtCache.imageProvider(coverArtId!),
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
  }
}
