import 'package:flutter/foundation.dart';
import 'package:frontend/services/history/history_diagnostics.dart';

/// What the history sync state means for a statistics snapshot (spec §4
/// "sync freshness/pending-upload indicator"). A model rule: the view only
/// renders it.
@immutable
final class ListeningSyncNote {
  const ListeningSyncNote({
    required this.serverWithoutSync,
    required this.syncProblem,
    required this.pendingListens,
    required this.allUploaded,
  });

  /// From [diagnostics] (null while unknown) and the snapshot's count of
  /// counted listens still waiting to upload.
  factory ListeningSyncNote.of({
    required HistoryDiagnostics? diagnostics,
    required int pendingListens,
  }) {
    final serverWithoutSync = diagnostics?.waitingForServerSupport ?? false;
    final syncProblem =
        diagnostics != null &&
        !serverWithoutSync &&
        (diagnostics.lastError != null ||
            diagnostics.quarantined > 0 ||
            diagnostics.frozenListens > 0 ||
            diagnostics.listenError != null);
    return ListeningSyncNote(
      serverWithoutSync: serverWithoutSync,
      syncProblem: syncProblem,
      pendingListens: pendingListens,
      allUploaded:
          diagnostics != null &&
          !serverWithoutSync &&
          !syncProblem &&
          pendingListens == 0,
    );
  }

  /// The server does not sync history: only this device's listens count.
  final bool serverWithoutSync;

  /// Sync or listen recording is failing: other devices' listens (or some
  /// of this device's) may be missing.
  final bool syncProblem;

  /// Counted listens in the snapshot not uploaded yet.
  final int pendingListens;

  /// Known to be fully uploaded with nothing failing.
  final bool allUploaded;
}
