import 'package:flutter/foundation.dart';
import 'package:frontend/models/track_selection.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

/// A [TrackSelectionControls] for page widget tests (SC-26). It keeps its
/// state in the real [TrackSelection] model and records every input the
/// page sends in [calls] (`toggle <uuid>`, `select <uuid> <revision>`, `clear`, `deselect <uuid>`,
/// `refreshRevision <uuid> <revision>`).
class FakeTrackSelectionControls extends ChangeNotifier
    implements TrackSelectionControls {
  final calls = <String>[];
  TrackSelection _selection = const TrackSelection.empty();

  @override
  TrackSelection get selection => _selection;

  @override
  int get count => _selection.count;

  @override
  bool isSelected(String uuid) => _selection.contains(uuid);

  @override
  void toggle(TrackUI track) {
    calls.add('toggle ${track.uuidId}');
    _selection = _selection.toggled(
      uuid: track.uuidId,
      baseRevision: track.revision,
    );
    notifyListeners();
  }

  @override
  void select(String uuid, {required int? baseRevision}) {
    calls.add('select $uuid $baseRevision');
    if (_selection.contains(uuid)) return;
    _selection = _selection.toggled(uuid: uuid, baseRevision: baseRevision);
    notifyListeners();
  }

  @override
  void clear() {
    calls.add('clear');
    _selection = const TrackSelection.empty();
    notifyListeners();
  }

  @override
  void deselect(String uuid) {
    calls.add('deselect $uuid');
    _selection = _selection.without(uuid);
    notifyListeners();
  }

  @override
  void refreshRevision(String uuid, int revision) {
    calls.add('refreshRevision $uuid $revision');
    _selection = _selection.withRevision(uuid, revision);
    notifyListeners();
  }
}
