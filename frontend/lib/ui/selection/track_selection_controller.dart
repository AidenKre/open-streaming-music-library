import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/track_selection.dart';
import 'package:frontend/models/ui/track_ui.dart';

/// The track-selection input of one browse page (SC-17/SC-26): it holds the
/// page's [TrackSelection], so views only render [selection] and forward row
/// taps.
///
/// Page-scoped: the owning page creates it from
/// [trackSelectionControllerFactoryProvider] and disposes it. The selection
/// survives query and page changes because it lives here, not in the list.
/// A row with an unknown revision is selected with a null revision.
abstract interface class TrackSelectionControls implements Listenable {
  /// The current selection, in selection order.
  TrackSelection get selection;

  int get count;

  bool isSelected(String uuid);

  /// The user tapped [track]: select it with its row revision, or deselect it.
  void toggle(TrackUI track);

  /// Selects [uuid] at [baseRevision] (null = unknown) when it is not
  /// selected yet; otherwise changes nothing.
  void select(String uuid, {required int? baseRevision});

  /// Drops the whole selection; notifies only if it was non-empty.
  void clear();

  void deselect(String uuid);

  void refreshRevision(String uuid, int revision);

  void dispose();
}

typedef TrackSelectionFactory = TrackSelectionControls Function();

/// Creates a fresh [TrackSelectionControls] per call. Override in tests to
/// substitute a fake.
final trackSelectionControllerFactoryProvider = Provider<TrackSelectionFactory>(
  (ref) =>
      () => TrackSelectionController(),
);

/// Holds a [TrackSelection] and no rules (SC-26): all of them live in the
/// model. Does no I/O.
class TrackSelectionController extends ChangeNotifier
    implements TrackSelectionControls {
  TrackSelection _selection = const TrackSelection.empty();
  bool _disposed = false;

  @override
  TrackSelection get selection => _selection;

  @override
  int get count => _selection.count;

  @override
  bool isSelected(String uuid) => _selection.contains(uuid);

  @override
  void toggle(TrackUI track) {
    if (_disposed) return;
    _selection = _selection.toggled(
      uuid: track.uuidId,
      baseRevision: track.revision,
    );
    notifyListeners();
  }

  @override
  void select(String uuid, {required int? baseRevision}) {
    if (_disposed || _selection.contains(uuid)) return;
    _selection = _selection.toggled(uuid: uuid, baseRevision: baseRevision);
    notifyListeners();
  }

  @override
  void clear() {
    if (_disposed || _selection.isEmpty) return;
    _selection = const TrackSelection.empty();
    notifyListeners();
  }

  @override
  void deselect(String uuid) => _set(_selection.without(uuid));

  @override
  void refreshRevision(String uuid, int revision) =>
      _set(_selection.withRevision(uuid, revision));

  void _set(TrackSelection next) {
    if (_disposed || listEquals(next.entries, _selection.entries)) return;
    _selection = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}
