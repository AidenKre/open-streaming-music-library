import 'package:flutter/foundation.dart';

/// The filter-chip selection for one browse surface (a root browse tab today,
/// the Home page in Phase 4). Session-only: the owning page keeps it in its
/// `State`; it is never global or persisted.
///
/// Minimal on purpose — a new filter is a new field + `copyWith` arg, a chip in
/// `FilterBar`, and its query clause. The search query is deliberately NOT
/// here; it belongs to `LibrarySearchController`.
///
/// Offline mode switches Downloaded on ([wentOffline]) as a sensible default,
/// but never locks it: the user can switch it off to browse the full library
/// from local metadata. Reconnecting ([cameOnline]) undoes only an ON that
/// offline applied and the user left alone.
@immutable
class BrowseFilters {
  const BrowseFilters({
    this.downloaded = false,
    this.downloadedByOffline = false,
  }) : assert(
         !downloadedByOffline || downloaded,
         'only an ON can have been applied by offline',
       );

  /// Starting selection for a page created while [isOffline].
  factory BrowseFilters.initial({required bool isOffline}) => isOffline
      ? const BrowseFilters(downloaded: true, downloadedByOffline: true)
      : const BrowseFilters();

  /// Whether the queries filter to downloaded music.
  final bool downloaded;

  /// [downloaded] was switched on by going offline, not by the user, so
  /// coming back online should switch it off again.
  final bool downloadedByOffline;

  BrowseFilters copyWith({bool? downloaded, bool? downloadedByOffline}) {
    return BrowseFilters(
      downloaded: downloaded ?? this.downloaded,
      downloadedByOffline: downloadedByOffline ?? this.downloadedByOffline,
    );
  }

  /// The user tapped the Downloaded chip. The value is now theirs, so a
  /// later reconnect leaves it alone.
  BrowseFilters userSetDownloaded(bool value) =>
      copyWith(downloaded: value, downloadedByOffline: false);

  /// Offline: default to what's playable. An ON the user chose stays theirs.
  BrowseFilters wentOffline() =>
      downloaded ? this : copyWith(downloaded: true, downloadedByOffline: true);

  /// Back online: undo offline's own ON; keep anything the user chose.
  BrowseFilters cameOnline() => downloadedByOffline
      ? copyWith(downloaded: false, downloadedByOffline: false)
      : this;

  @override
  bool operator ==(Object other) =>
      other is BrowseFilters &&
      other.downloaded == downloaded &&
      other.downloadedByOffline == downloadedByOffline;

  @override
  int get hashCode => Object.hash(downloaded, downloadedByOffline);

  @override
  String toString() =>
      'BrowseFilters(downloaded: $downloaded, '
      'downloadedByOffline: $downloadedByOffline)';
}
