import 'package:flutter/material.dart';
import 'package:frontend/models/browse_filters.dart';

/// Horizontally scrollable row of capsule filter chips for a browse surface.
///
/// Stateless presentation: the surface's `BrowseFilterControls` owns the
/// [BrowseFilters]; this renders them and forwards taps. Adding a filter
/// means adding a chip here next to its [BrowseFilters] field and a setter on
/// the controller.
///
/// The chips are always tappable. Offline mode only changes the surface's
/// [BrowseFilters] (Downloaded switches on), so the user can still switch it
/// off to browse everything.
class FilterBar extends StatelessWidget {
  static const downloadedChipKey = ValueKey('filter-chip-downloaded');

  final BrowseFilters filters;

  /// The user tapped the Downloaded chip (the new selected value).
  final ValueChanged<bool> onDownloadedChanged;

  const FilterBar({
    super.key,
    required this.filters,
    required this.onDownloadedChanged,
  });

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
            onSelected: onDownloadedChanged,
          ),
        ],
      ),
    );
  }
}
