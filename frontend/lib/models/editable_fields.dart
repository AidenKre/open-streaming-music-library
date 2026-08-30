import 'package:frontend/models/app_info.dart';

/// The client's built-in list of editable track tag fields, mirroring the
/// backend's EDIT_FIELD_SPECS (backend/app/models/edit_fields.py).
///
/// The single client source for BOTH the conservative cold-offline default
/// schema (`defaultAppInfo`) and the optimistic-write gate
/// ([editableMetadataColumns]) — so a field the form lets the user edit can
/// never be silently stripped from the local optimistic write by a stale
/// second copy of the list.
const List<FieldDescriptor> defaultEditableTrackFields = [
  FieldDescriptor(key: 'title', label: 'Title', valueType: 'text'),
  FieldDescriptor(key: 'artist', label: 'Artist', valueType: 'text'),
  FieldDescriptor(key: 'album', label: 'Album', valueType: 'text'),
  FieldDescriptor(
      key: 'album_artist', label: 'Album Artist', valueType: 'text'),
  FieldDescriptor(key: 'year', label: 'Year', valueType: 'year'),
  FieldDescriptor(key: 'date', label: 'Date', valueType: 'text'),
  FieldDescriptor(key: 'genre', label: 'Genre', valueType: 'text'),
  FieldDescriptor(
      key: 'track_number', label: 'Track Number', valueType: 'int'),
  FieldDescriptor(key: 'disc_number', label: 'Disc Number', valueType: 'int'),
];

/// Track tag columns a user may edit, derived from the descriptors above.
/// Gates the optimistic local write (`applyOptimisticTrackEdit`) and the
/// pre-edit snapshot read (`readEditableColumns`).
final Set<String> editableMetadataColumns = {
  for (final f in defaultEditableTrackFields) f.key,
};
