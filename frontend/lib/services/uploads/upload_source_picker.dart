/// Phase 7 §7: picking upload sources. The native picker is the one seam
/// tests fake (DEV-7-03: `file_selector`). Model code: nothing from `ui/`.
library;

import 'package:file_selector/file_selector.dart' as fs;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:frontend/services/uploads/upload_source.dart';

/// What one pick produced: readable [sources] in the order picked, and the
/// display names of picked files that could not be opened.
class UploadSelection {
  const UploadSelection({required this.sources, required this.unavailable});
  final List<FileUploadSource> sources;
  final List<String> unavailable;

  /// Nothing picked (the panel was cancelled).
  bool get isEmpty => sources.isEmpty && unavailable.isEmpty;
}

/// Lets the user pick files to upload.
abstract interface class UploadSourcePicker {
  Future<UploadSelection> pick();
}

/// The platform's file panel through `file_selector` (multiple files, no
/// type filter: the server probes the content; names are hints).
class NativeUploadSourcePicker implements UploadSourcePicker {
  NativeUploadSourcePicker({Future<List<fs.XFile>> Function()? openFiles})
      : _openFiles = openFiles ?? (() => fs.openFiles());

  final Future<List<fs.XFile>> Function() _openFiles;

  @override
  Future<UploadSelection> pick() async {
    final files = await _openFiles();
    final sources = <FileUploadSource>[];
    final unavailable = <String>[];
    for (final file in files) {
      try {
        sources.add(await FileUploadSource.open(file.path, displayName: file.name));
      } on UploadSourceUnavailable {
        unavailable.add(file.name);
      }
    }
    return UploadSelection(sources: sources, unavailable: unavailable);
  }
}

/// A FAKE picker: answers queued real file paths instead of a native panel.
/// For tests and the live gate's injected runs only (plan §5: the real panel
/// is not driven in this run); never the default.
class FakeUploadSourcePicker implements UploadSourcePicker {
  /// Queues one selection: the next [pick] answers these files.
  void enqueue(List<String> paths) => _queue.add(List.of(paths));

  final _queue = <List<String>>[];
  int _picks = 0;

  /// Picks made so far.
  int get picks => _picks;

  @override
  Future<UploadSelection> pick() async {
    _picks++;
    final paths = _queue.isEmpty ? const <String>[] : _queue.removeAt(0);
    final sources = <FileUploadSource>[];
    final unavailable = <String>[];
    for (final path in paths) {
      try {
        sources.add(await FileUploadSource.open(path));
      } on UploadSourceUnavailable {
        unavailable.add(p.basename(path));
      }
    }
    return UploadSelection(sources: sources, unavailable: unavailable);
  }
}

/// The scope's picker; override with [FakeUploadSourcePicker] to inject.
final uploadSourcePickerProvider = Provider<UploadSourcePicker>(
  (ref) => NativeUploadSourcePicker(),
);
