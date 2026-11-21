import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';

/// The library (catalog) sync as the user should see it (phase-4 §4: the
/// session host's sync has bounded loading/error/retry feedback).
enum LibrarySyncStatus {
  /// Nothing to show: no result yet, the last sync succeeded, or offline
  /// (the offline banner explains, and a sync can't run).
  idle,

  /// A sync is running.
  syncing,

  /// The last sync failed while online; the user can retry.
  failed,

  /// The last sync failed because the server's library looks restored from
  /// an older backup: retrying cannot help, only a reset of this device.
  serverRestored,
}

/// One model status for every surface that shows sync feedback.
final librarySyncStatusProvider = Provider<LibrarySyncStatus>((ref) {
  if (ref.watch(offlineModeProvider)) return LibrarySyncStatus.idle;
  final state = ref.watch(trackSyncProvider).value;
  if (state == null) return LibrarySyncStatus.idle;
  // Library (catalog) syncs only: a conflict's single-track refresh neither
  // shows progress nor sets or clears the library's error.
  if (state.librarySyncing) return LibrarySyncStatus.syncing;
  if (state.libraryServerRestored) return LibrarySyncStatus.serverRestored;
  if (state.libraryError != null) return LibrarySyncStatus.failed;
  return LibrarySyncStatus.idle;
});

/// Whether a complete library (catalog) sync has finished since this device
/// was bound to this server and user: the stored marker
/// `server_binding.catalog_reconciled_at_binding` (kept across a log-out,
/// with the device library; cleared by a reset or a restored server).
/// Only then does an empty device library mean an empty library. Read again
/// whenever a library sync starts or ends; false with no binding.
final libraryCatalogSyncedProvider = FutureProvider<bool>((ref) async {
  ref.watch(trackSyncProvider.select((a) => a.value?.librarySyncing));
  final binding = await ref.read(serverBindingRepositoryProvider).current();
  return binding?.catalogReconciled ?? false;
});
