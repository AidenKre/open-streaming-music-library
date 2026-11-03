import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
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
