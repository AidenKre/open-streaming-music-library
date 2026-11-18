import 'package:frontend/providers/providers.dart';

/// A catalog sync that never runs: an empty state, and [sync] does nothing.
class StubTrackSync extends TrackSyncNotifier {
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {}
}
