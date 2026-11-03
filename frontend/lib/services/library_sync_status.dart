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
}

/// One model status for every surface that shows sync feedback.
final librarySyncStatusProvider = Provider<LibrarySyncStatus>((ref) {
  if (ref.watch(offlineModeProvider)) return LibrarySyncStatus.idle;
  final state = ref.watch(trackSyncProvider).value;
  if (state == null) return LibrarySyncStatus.idle;
  // Library (catalog) syncs only: a conflict's single-track refresh neither
  // shows progress nor sets or clears the library's error.
  if (state.librarySyncing) return LibrarySyncStatus.syncing;
  if (state.libraryError != null) return LibrarySyncStatus.failed;
  return LibrarySyncStatus.idle;
});
