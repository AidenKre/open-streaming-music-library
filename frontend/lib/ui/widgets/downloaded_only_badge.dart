import 'package:flutter/material.dart';

/// Strip shown at the top of list pages (artists/albums/search) while the
/// app is offline, to make the active "downloaded-only" filter visible.
/// Without it an empty or shrunken list reads like the library was wiped.
class DownloadedOnlyBadge extends StatelessWidget {
  const DownloadedOnlyBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.download_done, size: 16, color: colors.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Showing downloaded only',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
