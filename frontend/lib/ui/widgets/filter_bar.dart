import 'package:flutter/material.dart';
import 'package:frontend/models/browse_filters.dart';

/// Horizontally scrollable row of capsule filter chips for a browse surface.
///
/// Stateless presentation: the owning page holds the [BrowseFilters] and
/// re-queries in [onChanged]. Adding a filter means adding a chip here next to
/// its [BrowseFilters] field.
///
/// The chips are always tappable. Offline mode only changes the page's
/// [BrowseFilters] (Downloaded switches on), so the user can still switch it
/// off to browse everything.
class FilterBar extends StatelessWidget {
  static const downloadedChipKey = ValueKey('filter-chip-downloaded');

  final BrowseFilters filters;
  final ValueChanged<BrowseFilters> onChanged;

  const FilterBar({super.key, required this.filters, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          FilterChip(
            key: downloadedChipKey,
            label: const Text('Downloaded'),
            shape: const StadiumBorder(),
            selected: filters.downloaded,
            onSelected: (value) => onChanged(filters.userSetDownloaded(value)),
          ),
        ],
      ),
    );
  }
}
