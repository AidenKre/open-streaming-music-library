import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/providers.dart';

/// A track sync whose runs the test starts and finishes.
class RunOnceTrackSync extends TrackSyncNotifier {
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {}

  /// One finished run that deleted [deleted] locally (none: a no-op run,
  /// as on every resume).
  void runOnce({Set<String> deleted = const {}}) {
    state = const AsyncData(TrackSyncState(isSyncing: true));
    state = AsyncData(TrackSyncState(deletedTrackUuids: deleted));
  }
}
