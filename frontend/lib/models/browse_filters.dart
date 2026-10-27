import 'package:flutter/foundation.dart';

/// The filter-chip selection for one browse surface (a root browse tab today,
/// the Home page in Phase 4). Session-only: the owning page keeps it in its
/// `State`; it is never global or persisted.
///
/// Minimal on purpose — a new filter is a new field + `copyWith` arg, a chip in
/// `FilterBar`, and its query clause. The search query is deliberately NOT
/// here; it belongs to `LibrarySearchController`.
@immutable
class BrowseFilters {
  const BrowseFilters({this.downloaded = false});

  /// The user's explicit "Downloaded" choice. Offline mode never rewrites it,
  /// so the chip returns to this value when the app comes back online.
  final bool downloaded;

  BrowseFilters copyWith({bool? downloaded}) {
    return BrowseFilters(downloaded: downloaded ?? this.downloaded);
  }

  /// What queries actually filter by: offline forces downloaded-only, since
  /// nothing else is playable.
  bool effectiveDownloaded({required bool isOffline}) =>
      downloaded || isOffline;

  @override
  bool operator ==(Object other) =>
      other is BrowseFilters && other.downloaded == downloaded;

  @override
  int get hashCode => downloaded.hashCode;

  @override
  String toString() => 'BrowseFilters(downloaded: $downloaded)';
}
