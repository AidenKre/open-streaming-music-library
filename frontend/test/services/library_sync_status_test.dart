import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/library_sync_status.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_offline.dart';


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

  // Other-issues decision 3 (a): a restored server is its own status.
  test('a library sync that found the server restored: serverRestored, '
      'offline idle', () async {
    final (c, sync, off) = await make(const TrackSyncState(
      error: 'boom',
      libraryError: 'boom',
      libraryServerRestored: true,
    ));
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.serverRestored);
    off.set(true);
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.idle);
    off.set(false);
    sync.set(const TrackSyncState(error: 'boom', libraryError: 'boom'));
    expect(c.read(librarySyncStatusProvider), LibrarySyncStatus.failed);
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

  // An empty device library is an empty library only once a complete
  // library sync has finished while this device is bound to this server
  // and user (the stored marker; a log-out keeps it).
  group('a complete library sync has finished on this device', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<(ProviderContainer, _ScriptedSync)> make(
      TrackSyncState initial,
    ) async {
      final sync = _ScriptedSync(initial);
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          trackSyncProvider.overrideWith(() => sync),
        ],
      );
      addTearDown(c.dispose);
      c.listen(libraryCatalogSyncedProvider, (_, _) {});
      await c.read(trackSyncProvider.future);
      return (c, sync);
    }

    test('no binding: no', () async {
      final (c, _) = await make(const TrackSyncState());
      expect(await c.read(libraryCatalogSyncedProvider.future), isFalse);
    });

    test('signed in, no complete sync yet: no', () async {
      await seedTestBinding(db);
      final (c, _) = await make(const TrackSyncState());
      expect(await c.read(libraryCatalogSyncedProvider.future), isFalse);
    });

    test('a complete sync finished: yes', () async {
      await seedTestBinding(db, reconciled: true);
      final (c, _) = await make(const TrackSyncState());
      expect(await c.read(libraryCatalogSyncedProvider.future), isTrue);
    });

    test('read again when a library sync ends', () async {
      await seedTestBinding(db);
      final (c, sync) = await make(
        const TrackSyncState(isSyncing: true, librarySyncing: true),
      );
      expect(await c.read(libraryCatalogSyncedProvider.future), isFalse);
      // The sync's final page stores the marker; then the sync ends.
      await db.update(db.serverBinding).write(
        const ServerBindingCompanion(catalogReconciledAtBinding: Value(true)),
      );
      sync.set(const TrackSyncState());
      expect(await c.read(libraryCatalogSyncedProvider.future), isTrue);
    });
  });
}
