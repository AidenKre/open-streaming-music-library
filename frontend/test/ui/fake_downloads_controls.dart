import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/ui/downloads_controller.dart';

class FakeDownloadsControls implements DownloadsControls {
  final calls = <String>[];
  @override
  void clearFinished() => calls.add('clearFinished');
  @override
  void cancelQueued(String uuidId) => calls.add('cancel $uuidId');
  @override
  void cancelActive(String uuidId) => calls.add('cancelActive $uuidId');
  @override
  Future<void> dismissStale(String uuidId) async => calls.add('dismiss $uuidId');
  @override
  Future<void> dismissAllStale(Iterable<String> uuidIds) async =>
      calls.add('dismissAll ${uuidIds.join(',')}');
  @override
  Future<({int failed, int total})> redownloadStale(List<TrackUI> tracks) async {
    calls.add('redownload ${tracks.map((t) => t.uuidId).join(',')}');
    return (failed: 0, total: tracks.length);
  }
  /// How many tracks of each [redownloadDamaged] call could not be queued.
  int damagedFailures = 0;
  @override
  Future<({int failed, int total})> redownloadDamaged(
      List<TrackUI> tracks) async {
    calls.add('redownloadDamaged ${tracks.map((t) => t.uuidId).join(',')}');
    return (failed: damagedFailures, total: tracks.length);
  }
  @override
  Future<void> deleteDamaged(String uuidId) async =>
      calls.add('deleteDamaged $uuidId');
}
