import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/library_sync_status.dart';

import '../ui/browse_harness.dart';

class _ScriptedSync extends TrackSyncNotifier {
  _ScriptedSync(this.initial);
  final TrackSyncState initial;
  @override
  Future<TrackSyncState> build() async => initial;
  void set(TrackSyncState s) => state = AsyncData(s);
}

/// Audit 4A(a) M2: the bounded initial-sync feedback reads one model status.
void main() {
  Future<(ProviderContainer, _ScriptedSync, TestOffline)> make(
    TrackSyncState initial, {
    bool offline = false,
  }) async {
    final sync = _ScriptedSync(initial);
    final off = TestOffline(offline);
    final c = ProviderContainer(
      overrides: [
        trackSyncProvider.overrideWith(() => sync),
        offlineModeProvider.overrideWith(() => off),
      ],
    );
    addTearDown(c.dispose);
    await c.read(trackSyncProvider.future);
    return (c, sync, off);
  }

  test('idle before the first sync result (unknown is not a failure)', () {
    final c = ProviderContainer(
      overrides: [offlineModeProvider.overrideWith(() => TestOffline(false))],
    );
    addTearDown(c.dispose);
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.idle);
  });

  // Re-audit 4A #4: the status follows LIBRARY syncs only (was any guarded
  // run, incl. a conflict's single-track refresh).
  test('syncing, failed, then idle after a good library sync', () async {
    final (c, sync, _) = await make(
      const TrackSyncState(isSyncing: true, librarySyncing: true),
    );
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.syncing);
    sync.set(const TrackSyncState(error: 'boom', libraryError: 'boom'));
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.failed);
    sync.set(const TrackSyncState());
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.idle);
  });

  test('a single-track refresh neither shows progress nor an error', () async {
    final (c, sync, _) = await make(const TrackSyncState(isSyncing: true));
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.idle);
    sync.set(const TrackSyncState(error: 'refresh failed'));
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.idle);
  });

  test('offline: idle (the offline banner explains; no Retry)', () async {
    final (c, _, off) = await make(
      const TrackSyncState(error: 'boom', libraryError: 'boom'),
      offline: true,
    );
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.idle);
    off.set(false);
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.failed);
  });
}
