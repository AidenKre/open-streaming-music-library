import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/providers/offline_mode_provider.dart';

/// The filter-chip input of one browse surface (SC-09/SC-26): it owns the
/// surface's [BrowseFilters] and applies connectivity to it, so views only
/// render [filters] and forward chip taps.
///
/// Page-scoped and session-only: obtained from
/// [browseFilterControllerFactoryProvider] and disposed by its owner (a
/// browse page today; Phase 6's Home controller with
/// [OfflineFilterPolicy.manual]). Listeners are notified only when the
/// selection actually changes; the owner then re-runs whichever query it
/// shows.
abstract interface class BrowseFilterControls implements Listenable {
  /// The current chip selection.
  BrowseFilters get filters;

  /// The user tapped the Downloaded chip.
  void setDownloaded(bool value);

  void dispose();
}

/// [initial], when non-null, is the starting Downloaded selection (see
/// [BrowseFilterController]); null keeps the offline-derived default.
typedef BrowseFilterFactory =
    BrowseFilterControls Function({OfflineFilterPolicy policy, bool? initial});

/// Creates a surface's [BrowseFilterControls]. Override in tests to
/// substitute a fake.
final browseFilterControllerFactoryProvider = Provider<BrowseFilterFactory>(
  (ref) =>
      ({policy = OfflineFilterPolicy.autoApply, initial}) =>
          BrowseFilterController(ref, policy: policy, initial: initial),
);

class BrowseFilterController extends ChangeNotifier
    implements BrowseFilterControls {
  /// Starts from [BrowseFilters.initial] for the offline state right now and
  /// follows later offline flips until [dispose].
  ///
  /// A non-null [initial] is the user's own Downloaded choice instead (Phase 6
  /// See all seeds its manual filter from Home's current value, then owns it):
  /// it is never marked as set by offline, so a reconnect does not undo it.
  BrowseFilterController(
    Ref ref, {
    OfflineFilterPolicy policy = OfflineFilterPolicy.autoApply,
    bool? initial,
  }) : _filters = initial == null
           ? BrowseFilters.initial(
               isOffline: ref.read(offlineModeProvider),
               policy: policy,
             )
           : BrowseFilters(policy: policy).userSetDownloaded(initial) {
    _offline = ref.listen<bool>(offlineModeProvider, (prev, next) {
      if (prev == next) return;
      _set(next ? _filters.wentOffline() : _filters.cameOnline());
    });
  }

  BrowseFilters _filters;
  ProviderSubscription<bool>? _offline;
  bool _disposed = false;

  @override
  BrowseFilters get filters => _filters;

  @override
  void setDownloaded(bool value) => _set(_filters.userSetDownloaded(value));

  void _set(BrowseFilters next) {
    if (_disposed || next == _filters) return;
    _filters = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _offline?.close();
    _offline = null;
    super.dispose();
  }
}
