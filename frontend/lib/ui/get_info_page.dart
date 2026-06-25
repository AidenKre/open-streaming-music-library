import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/ui/widgets/master_write_confirm_dialog.dart';
import 'package:frontend/ui/widgets/metadata_form.dart';

/// Schema-driven "Get Info" page for a track. Metadata opens view-only, then
/// becomes editable after the header Edit action. The Info tier remains
/// display-only (intrinsic audio facts + path). Reads work offline.
class GetInfoPage extends ConsumerStatefulWidget {
  const GetInfoPage({super.key, required this.track});

  final TrackUI track;

  @override
  ConsumerState<GetInfoPage> createState() => _GetInfoPageState();
}

class _GetInfoPageState extends ConsumerState<GetInfoPage> {
  MetadataEdit _edit = const MetadataEdit.empty();
  bool _editing = false;
  bool _writeToFile = false;

  TrackUI get _track => widget.track;

  @override
  void initState() {
    super.initState();
    _loadPendingWriteMode();
  }

  /// Reflect a queued `db_and_master` edit so reopening Get Info shows the
  /// master-write toggle already on — and re-saving can keep escalating to a
  /// master-file write.
  Future<void> _loadPendingWriteMode() async {
    final mode = await ref.read(databaseProvider).pendingWriteMode(_track.uuidId);
    if (!mounted) return;
    if (mode == 'db_and_master') setState(() => _writeToFile = true);
  }

  Object? _currentValue(String key) {
    switch (key) {
      case 'title':
        return _track.title;
      case 'artist':
        return _track.artist;
      case 'album':
        return _track.album;
      case 'album_artist':
        return _track.albumArtist;
      case 'year':
        return _track.year;
      case 'date':
        return _track.date;
      case 'genre':
        return _track.genre;
      case 'track_number':
        return _track.trackNumber;
      case 'disc_number':
        return _track.discNumber;
      default:
        return null;
    }
  }

  Future<List<String>> _suggestions(String key, String query) {
    final db = ref.read(databaseProvider);
    switch (key) {
      case 'artist':
      case 'album_artist':
        return db.artistSuggestions(query);
      case 'album':
        return db.albumSuggestions(query);
      case 'genre':
        return db.genreSuggestions(query);
      default:
        return Future.value(const []);
    }
  }

  Future<void> _save() async {
    if (!_editing) return;
    final mode = _writeToFile
        ? EditWriteMode.dbAndMaster
        : EditWriteMode.dbOnly;
    // Enabling master-write is itself a saveable change (re-tag the file from
    // the current DB values), so "no changes" only applies to a DB-only save
    // with no edited fields.
    if (_edit.isEmpty && mode == EditWriteMode.dbOnly) {
      _toast('No changes to save');
      return;
    }
    if (mode == EditWriteMode.dbAndMaster) {
      final confirmed = await showMasterWriteConfirmDialog(context);
      if (!confirmed) return;
    }
    await _submit(_edit, mode);
  }

  /// Optimistic local write + outbox enqueue, then a best-effort flush if
  /// online. The form/page stay persistence-neutral — this is the only seam
  /// that knows about the outbox.
  Future<void> _submit(MetadataEdit edit, EditWriteMode mode) async {
    final outbox = ref.read(editOutboxProvider);
    // base_revision is captured here, at submit (NULL forces the conflict path).
    await outbox.enqueue(
      uuidId: _track.uuidId,
      edit: edit,
      writeMode: mode,
      baseRevision: _track.revision,
    );
    final online = !ref.read(offlineModeProvider);
    if (online) {
      unawaited(outbox.flush());
    }
    if (!mounted) return;
    _toast(online ? 'Saved' : 'Saved — will sync when online');
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  void _startEditing() {
    setState(() => _editing = true);
  }

  void _cancelEditing() {
    setState(() {
      _editing = false;
      _edit = const MetadataEdit.empty();
      _writeToFile = false;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(appInfoProvider);
    final fields = caps.maybeWhen(
      data: (info) => editableFieldsFor(info, 'track'),
      orElse: () => const <FieldDescriptor>[],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Get Info'),
        actions: [
          if (fields.isNotEmpty)
            if (_editing) ...[
              TextButton(
                onPressed: _cancelEditing,
                child: const Text('Cancel'),
              ),
              TextButton(onPressed: _save, child: const Text('Save')),
            ] else
              TextButton(onPressed: _startEditing, child: const Text('Edit')),
        ],
      ),
      body: caps.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => _body(const []),
        data: (info) => _body(editableFieldsFor(info, 'track')),
      ),
    );
  }

  Widget _body(List<FieldDescriptor> fields) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (fields.isNotEmpty) ...[
          Text('Metadata', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_editing) ...[
            MetadataForm(
              fields: fields,
              current: _currentValue,
              edit: _edit,
              onChanged: (e) => setState(() => _edit = e),
              suggestionsFor: _suggestions,
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Update master file on server'),
              subtitle: const Text(
                'Rewrites tags on the backend server’s disk; may move the file.',
              ),
              value: _writeToFile,
              onChanged: (v) => setState(() => _writeToFile = v),
            ),
          ] else
            ..._metadataRows(fields),
          const Divider(height: 32),
        ],
        Text('Info', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ..._infoRows(),
      ],
    );
  }

  List<Widget> _metadataRows(List<FieldDescriptor> fields) {
    return [
      for (final field in fields)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  field.label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: Text(_displayValue(_currentValue(field.key)))),
            ],
          ),
        ),
    ];
  }

  String _displayValue(Object? value) {
    if (value == null) return '—';
    final text = value.toString();
    return text.isEmpty ? '—' : text;
  }

  List<Widget> _infoRows() {
    final rows = <(String, String?)>[
      ('Codec', _track.codec),
      ('Duration', _track.formattedDuration),
      ('Bitrate', '${_track.bitrateKbps.round()} kbps'),
      ('Sample rate', '${_track.sampleRateHz} Hz'),
      ('Channels', '${_track.channels}'),
      ('Path', _track.filePath),
    ];
    return [
      for (final (label, value) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: Text(value ?? '—')),
            ],
          ),
        ),
    ];
  }
}
