import 'package:flutter/material.dart';
import 'package:frontend/models/browse_filters.dart';

/// Horizontally scrollable row of capsule filter chips for a browse surface.
///
/// Stateless presentation: the owning page holds the [BrowseFilters] and
/// re-queries in [onChanged]. Adding a filter means adding a chip here next to
/// its [BrowseFilters] field.
///
/// Offline, the Downloaded chip is locked on (selected + disabled) because
/// nothing else is playable. This replaces the old `DownloadedOnlyBadge` on
/// pages that show the bar. The user's own value is untouched underneath, so
/// it reappears when the app comes back online.
class FilterBar extends StatelessWidget {
  static const downloadedChipKey = ValueKey('filter-chip-downloaded');

  final BrowseFilters filters;
  final ValueChanged<BrowseFilters> onChanged;
  final bool isOffline;

  const FilterBar({
    super.key,
    required this.filters,
    required this.onChanged,
    required this.isOffline,
  });

  @override
  Widget build(BuildContext context) {
    Widget downloaded = FilterChip(
      key: downloadedChipKey,
      label: const Text('Downloaded'),
      shape: const StadiumBorder(),
      selected: filters.effectiveDownloaded(isOffline: isOffline),
      onSelected: isOffline
          ? null
          : (value) => onChanged(filters.copyWith(downloaded: value)),
    );
    if (isOffline) {
      downloaded = Tooltip(
        message: 'Offline — only downloaded music is available',
        child: downloaded,
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(children: [downloaded]),
    );
  }
}
