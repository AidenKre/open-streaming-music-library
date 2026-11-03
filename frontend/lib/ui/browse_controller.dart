import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/session_service.dart';

/// Input of the library browse pages that isn't a library action: asking
/// for fresh catalog data when a browse route is created (SC-26: views never
/// trigger the sync notifier themselves). Phase 4A moves the initial sync to
/// the session host; creating a Tracks browse route keeps calling this.
abstract interface class BrowseControls {
  /// Pull catalog changes from the server (a no-op offline or while a sync
  /// is already running; the model decides).
  Future<void> refreshLibrary();
}

final browseControlsProvider = Provider<BrowseControls>(
  (ref) => BrowseController(ref),
);

class BrowseController implements BrowseControls {
  BrowseController(this._ref);

  final Ref _ref;

  /// Through the one model entry for a catalog sync (5A.0 gates it there).
  @override
  Future<void> refreshLibrary() =>
      _ref.read(sessionServiceProvider).syncLibrary();
}
