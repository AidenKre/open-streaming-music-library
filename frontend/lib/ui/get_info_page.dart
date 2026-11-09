import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/ui/shell/shell_chrome.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/ui/edit_controller.dart';
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
    final pending = await ref
        .read(editControlsProvider)
        .hasPendingMasterWrite(_track.uuidId);
    if (!mounted) return;
    if (pending) setState(() => _writeToFile = true);
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

  Future<List<String>> _suggestions(String key, String query) =>
      ref.read(editControlsProvider).suggestions(key, query);

  Future<void> _save() async {
    if (!_editing) return;
    final edits = ref.read(editControlsProvider);
    final mode = _writeToFile
        ? EditWriteMode.dbAndMaster
        : EditWriteMode.dbOnly;
    switch (await edits.planSave(_track, _edit, mode)) {
      case EditSavePlan.noChanges:
        _toast('No changes to save');
        return;
      case EditSavePlan.confirmMasterWrite:
        if (!mounted) return;
        final confirmed = await showMasterWriteConfirmDialog(context);
        if (!confirmed) return;
      case EditSavePlan.ready:
        break;
    }
    final submitted = await edits.submit(_track, _edit, mode);
    if (!mounted) return;
    _toast(
      submitted == EditSubmitted.online
          ? 'Saved'
          : 'Saved — will sync when online',
    );
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
      // Ends above the shell's floating bottom chrome (4B).
      padding: ShellChromeInsets.padEnd(context, const EdgeInsets.all(16)),
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
              // Keys _suggestions can actually resolve (drift-backed).
              autocompleteKeys: const {
                'artist',
                'album_artist',
                'album',
                'genre',
              },
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
      // Null = the server doesn't know it; a real 0 still shows "0 kbps".
      (
        'Bitrate',
        switch (_track.bitrateKbps) {
          null => 'Unknown',
          final kbps => '${kbps.round()} kbps',
        },
      ),
      // Null = unknown, shown as '—' by _displayValue (never 'null Hz').
      (
        'Sample rate',
        switch (_track.sampleRateHz) {
          null => null,
          final hz => '$hz Hz',
        },
      ),
      ('Channels', _track.channels?.toString()),
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
