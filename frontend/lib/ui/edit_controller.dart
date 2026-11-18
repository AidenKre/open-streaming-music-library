import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/pending_edit_display.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/edit_outbox.dart';

/// Whether a submitted edit is syncing now or will when back online.
enum EditSubmitted { online, offline }

/// Metadata-edit input (SC-26 `EditController`): Get info's save flow and
/// the pending-edits banner's conflict/rejection actions. The rules (no-op
/// saves, master-write escalation, outbox/flush) live in the model
/// [EditOutbox].
abstract interface class EditControls {
  Future<bool> hasPendingMasterWrite(String uuidId);

  Future<List<String>> suggestions(String fieldKey, String query);

  Future<EditSavePlan> planSave(
    TrackUI track,
    MetadataEdit edit,
    EditWriteMode mode,
  );

  Future<EditSubmitted> submit(
    TrackUI track,
    MetadataEdit edit,
    EditWriteMode mode,
  );

  Future<void> resolveKeepMine(String uuidId);

  Future<void> resolveTakeServer(String uuidId);

  Future<void> dismissRejected(String uuidId);
}

final editControlsProvider = Provider<EditControls>(
  (ref) => EditController(ref),
);

class EditController implements EditControls {
  EditController(this._ref);

  final Ref _ref;

  EditOutbox get _outbox => _ref.read(editOutboxProvider);

  @override
  Future<bool> hasPendingMasterWrite(String uuidId) =>
      _outbox.hasPendingMasterWrite(uuidId);

  @override
  Future<List<String>> suggestions(String fieldKey, String query) =>
      _outbox.fieldSuggestions(fieldKey, query);

  @override
  Future<EditSavePlan> planSave(
    TrackUI track,
    MetadataEdit edit,
    EditWriteMode mode,
  ) => _outbox.planSave(track.uuidId, edit, mode);

  @override
  Future<EditSubmitted> submit(
    TrackUI track,
    MetadataEdit edit,
    EditWriteMode mode,
  ) async {
    await _outbox.submit(
      uuidId: track.uuidId,
      edit: edit,
      writeMode: mode,
      baseRevision: track.revision,
    );
    return _ref.read(offlineModeProvider)
        ? EditSubmitted.offline
        : EditSubmitted.online;
  }

  @override
  Future<void> resolveKeepMine(String uuidId) =>
      _outbox.resolveKeepMine(uuidId);

  @override
  Future<void> resolveTakeServer(String uuidId) =>
      _outbox.resolveTakeServer(uuidId);

  @override
  Future<void> dismissRejected(String uuidId) =>
      _outbox.dismissRejected(uuidId);
}

/// One conflicted or rejected edit as the pending-edits sheet shows it.
class EditIssue {
  const EditIssue({
    required this.uuidId,
    required this.trackName,
    this.rejectionReason,
  });

  /// For the sheet's actions only; never shown to a person.
  final String uuidId;

  /// The name a person reads ([editTrackName]).
  final String trackName;

  final String? rejectionReason;
}

/// Conflicted edits for the resolution sheet, each named for a person.
final conflictedEditIssuesProvider = FutureProvider<List<EditIssue>>(
  (ref) async => _issuesFor(ref, await ref.watch(conflictedEditsProvider.future)),
);

/// Rejected edits for the banner sheet, each named for a person.
final rejectedEditIssuesProvider = FutureProvider<List<EditIssue>>(
  (ref) async => _issuesFor(ref, await ref.watch(rejectedEditsProvider.future)),
);

Future<List<EditIssue>> _issuesFor(Ref ref, List<PendingEdit> rows) async {
  if (rows.isEmpty) return const [];
  // The names are a courtesy; the rows are the only way to resolve an edit.
  // A failed track read names them as for a track not on this device (the
  // edit's original values, else "Unknown track") and never empties the list.
  var tracks = const <TrackUI>[];
  try {
    tracks = await ref
        .read(browseRepositoryProvider)
        .getTracksByUuids([for (final row in rows) row.uuidId]);
  } catch (_) {}
  final byUuid = {for (final track in tracks) track.uuidId: track};
  return [
    for (final row in rows)
      EditIssue(
        uuidId: row.uuidId,
        trackName: editTrackName(
          track: byUuid[row.uuidId],
          originalValuesJson: row.originalValuesJson,
        ),
        rejectionReason: row.rejectionReason,
      ),
  ];
}
