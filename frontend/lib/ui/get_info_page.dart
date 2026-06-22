import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/ui/widgets/master_write_confirm_dialog.dart';
import 'package:frontend/ui/widgets/metadata_form.dart';

/// Schema-driven "Get Info" page for a track. Two tiers: editable metadata
/// fields (capabilities ∩ client-safe, via [MetadataForm]) and display-only
/// info rows (intrinsic audio facts + path). Reads work offline; the save path
/// is wired onto the outbox in slice 6 (here it is a stub).
class GetInfoPage extends ConsumerStatefulWidget {
  const GetInfoPage({super.key, required this.track});

  final TrackUI track;

  @override
  ConsumerState<GetInfoPage> createState() => _GetInfoPageState();
}

class _GetInfoPageState extends ConsumerState<GetInfoPage> {
  MetadataEdit _edit = const MetadataEdit.empty();
  bool _writeToFile = false;

  TrackUI get _track => widget.track;

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
    if (_edit.isEmpty) {
      _toast('No changes to save');
      return;
    }
    final mode = _writeToFile ? EditWriteMode.dbAndMaster : EditWriteMode.dbOnly;
    if (mode == EditWriteMode.dbAndMaster) {
      final confirmed = await showMasterWriteConfirmDialog(context);
      if (!confirmed) return;
    }
    _submit(_edit, mode);
  }

  /// TODO(slice-6): replace with the optimistic local write + outbox enqueue.
  /// Kept as the single seam so the form/page above stay persistence-neutral.
  void _submit(MetadataEdit edit, EditWriteMode mode) {
    _toast('Saving lands in slice 6 (mode: ${mode.wire}, '
        '${edit.touched.length} field(s))');
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final caps = ref.watch(appInfoProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Get Info'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
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
            title: const Text('Also write tags to the file on disk'),
            subtitle: const Text('Permanent; may move the file'),
            value: _writeToFile,
            onChanged: (v) => setState(() => _writeToFile = v),
          ),
          const Divider(height: 32),
        ],
        Text('Info', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ..._infoRows(),
      ],
    );
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
                child: Text(label,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
              Expanded(child: Text(value ?? '—')),
            ],
          ),
        ),
    ];
  }
}
