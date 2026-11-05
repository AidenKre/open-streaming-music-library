import 'package:flutter/foundation.dart';

/// The filter-chip selection for one browse surface (a root browse tab or
/// Search today, Home in Phase 6). Session-only: the surface's
/// `BrowseFilterControls` holds it; it is never global or persisted.
///
/// Minimal on purpose — a new filter is a new field + `copyWith` arg, a chip in
/// `FilterBar`, and its query clause. The search query is deliberately NOT
/// here; it belongs to `LibrarySearchController`.
///
/// Offline mode switches Downloaded on ([wentOffline]) as a sensible default,
/// but never locks it: the user can switch it off to browse the full library
/// from local metadata. Reconnecting ([cameOnline]) undoes only an ON that
/// offline applied and the user left alone.
/// How a surface's Downloaded filter reacts to connectivity (SC-09).
enum OfflineFilterPolicy {
  /// Offline switches Downloaded on; reconnecting undoes only that ON.
  /// Every Phase 3/4 surface.
  autoApply,

  /// Never touched by connectivity (Phase 6's Home chip and See all).
  manual,
}

@immutable
class BrowseFilters {
  const BrowseFilters({
    this.downloaded = false,
    this.downloadedByOffline = false,
    this.policy = OfflineFilterPolicy.autoApply,
  }) : assert(
         !downloadedByOffline || downloaded,
         'only an ON can have been applied by offline',
       );

  /// Starting selection for a page created while [isOffline].
  /// How connectivity changes affect [downloaded].
  final OfflineFilterPolicy policy;

  factory BrowseFilters.initial({
    required bool isOffline,
    OfflineFilterPolicy policy = OfflineFilterPolicy.autoApply,
  }) => isOffline && policy == OfflineFilterPolicy.autoApply
      ? const BrowseFilters(downloaded: true, downloadedByOffline: true)
      : BrowseFilters(policy: policy);

  /// Whether the queries filter to downloaded music.
  final bool downloaded;

  /// [downloaded] was switched on by going offline, not by the user, so
  /// coming back online should switch it off again.
  final bool downloadedByOffline;

  BrowseFilters copyWith({bool? downloaded, bool? downloadedByOffline}) {
    return BrowseFilters(
      downloaded: downloaded ?? this.downloaded,
      downloadedByOffline: downloadedByOffline ?? this.downloadedByOffline,
      policy: policy,
    );
  }

  /// The user tapped the Downloaded chip. The value is now theirs, so a
  /// later reconnect leaves it alone.
  BrowseFilters userSetDownloaded(bool value) =>
      copyWith(downloaded: value, downloadedByOffline: false);

  /// Offline: default to what's playable. An ON the user chose stays theirs.
  BrowseFilters wentOffline() =>
      policy == OfflineFilterPolicy.manual || downloaded
      ? this
      : copyWith(downloaded: true, downloadedByOffline: true);

  /// Back online: undo offline's own ON; keep anything the user chose.
  BrowseFilters cameOnline() => downloadedByOffline
      ? copyWith(downloaded: false, downloadedByOffline: false)
      : this;

  @override
  bool operator ==(Object other) =>
      other is BrowseFilters &&
      other.downloaded == downloaded &&
      other.downloadedByOffline == downloadedByOffline &&
      other.policy == policy;

  @override
  int get hashCode => Object.hash(downloaded, downloadedByOffline, policy);

  @override
  String toString() =>
      'BrowseFilters(downloaded: $downloaded, '
      'downloadedByOffline: $downloadedByOffline, policy: ${policy.name})';
}
