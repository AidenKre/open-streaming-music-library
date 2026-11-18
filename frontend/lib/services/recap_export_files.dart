/// Phase 9 §6: saving and sharing a recap export through an owned temporary
/// file. Model code: nothing from `ui/`.
library;

import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/recap_export_platform.dart';
import 'package:path/path.dart' as p;

/// The file name offered for the export of [year]'s recap: the year only,
/// nothing personal.
String recapExportFileName(int year, RecapExportType type) =>
    'osml-year-in-music-$year.${type.extension}';

/// What a save did.
enum RecapSaveOutcome {
  /// The file was written where the user chose.
  saved,

  /// The user cancelled the save panel; nothing was written.
  cancelled,

  /// A file already exists at the chosen place and the platform did not
  /// confirm replacing it; it was left untouched.
  destinationExists,

  /// This platform has no save panel.
  unavailable,

  /// Writing failed. Nothing is left behind, except that a confirmed
  /// replace whose in-place write failed part-way (only reached when the
  /// atomic move was refused) may have damaged the file that was replaced.
  failed,
}

/// What a share did.
enum RecapShareOutcome { shared, dismissed, unknown, unavailable, failed }

/// Writes recap exports to owned temporary files under
/// `<temporary directory>/[folderName]` and hands them to the platform.
class RecapExportFiles {
  RecapExportFiles({
    required RecapExportPlatform platform,
    void Function(String message)? log,
  }) : _platform = platform,
       _log = log ?? _defaultLog;

  final RecapExportPlatform _platform;
  final void Function(String message) _log;

  /// Per-export folders currently in use; the sweep never removes these.
  final _inFlight = <String>{};

  /// The folder kept for the last share, until released or swept.
  String? _held;

  /// Bumped by [release]; a share started before it does not hold its file.
  int _releaseEpoch = 0;

  static void _defaultLog(String message) =>
      developer.log(message, name: 'recap-export');

  /// The folder (under the platform's temporary directory) this service
  /// owns; nothing outside it is ever removed.
  static const folderName = 'osml-recap-export';

  /// The platform has a save panel.
  bool get canSave => _platform.canSave;

  /// The platform can share a file.
  bool get canShare => _platform.canShare;

  /// Saves [bytes] where the user chooses, offering [suggestedName].
  Future<RecapSaveOutcome> save(
    Uint8List bytes, {
    required String suggestedName,
    required RecapExportType type,
  }) async {
    if (!_platform.canSave) return RecapSaveOutcome.unavailable;
    String? exportDir;
    try {
      exportDir = await _begin();
      final temp = File(p.join(exportDir, suggestedName));
      try {
        await temp.writeAsBytes(bytes, flush: true);
      } on Object {
        return RecapSaveOutcome.failed;
      }
      final String? location;
      try {
        location = await _platform.chooseSaveLocation(
          suggestedName: suggestedName,
          type: type,
        );
      } on Object {
        return RecapSaveOutcome.failed;
      }
      if (location == null) return RecapSaveOutcome.cancelled;
      final existed = File(location).existsSync();
      if (existed && !_platform.confirmsReplace) {
        return RecapSaveOutcome.destinationExists;
      }
      return await _place(temp, bytes, location, existed);
    } on Object {
      return RecapSaveOutcome.failed;
    } finally {
      if (exportDir != null) await _remove(exportDir);
    }
  }

  /// Sweeps old exports, then makes a fresh per-export folder (in flight).
  Future<String> _begin() async {
    final owned = await _ownedFolder();
    _held = null; // the sweep removes it: it is not in flight
    await _sweep(owned);
    final dir = (await owned.createTemp('export-')).path;
    _inFlight.add(dir);
    return dir;
  }

  /// Removes a per-export folder; a failure is logged (without the path) and
  /// left for the next export's sweep.
  Future<void> _remove(String dir) async {
    try {
      await Directory(dir).delete(recursive: true);
    } on Object {
      _log(
        'could not remove a temporary recap export; it will be removed '
        'by the next export',
      );
    }
    _inFlight.remove(dir);
  }

  Future<Directory> _ownedFolder() async {
    final root = await _platform.temporaryDirectory();
    final path = p.join(root.path, folderName);
    // Never work through a link: its target is not ours to sweep.
    if (FileSystemEntity.isLinkSync(path)) {
      throw StateError('the recap export folder is a link');
    }
    return Directory(path).create(recursive: true);
  }

  Future<void> _sweep(Directory owned) async {
    var failed = false;
    try {
      await for (final entry in owned.list(followLinks: false)) {
        if (_inFlight.contains(entry.path)) continue;
        try {
          if (entry is Link) {
            await entry.delete(); // the link only, never its target
          } else {
            await entry.delete(recursive: true);
          }
        } on Object {
          failed = true;
        }
      }
    } on Object {
      failed = true;
    }
    if (failed) _log('could not clear old temporary recap exports');
  }

  Future<RecapSaveOutcome> _place(
    File temp,
    Uint8List bytes,
    String location,
    bool existed,
  ) async {
    final dest = File(location);
    var created = false;
    try {
      if (!existed) {
        try {
          await dest.create(exclusive: true);
          created = true;
        } on PathExistsException {
          return RecapSaveOutcome.destinationExists;
        }
      }
      try {
        await temp.rename(location);
      } on FileSystemException {
        // In place: if this fails part-way a replaced file may be damaged.
        await dest.writeAsBytes(bytes, flush: true);
      }
      return RecapSaveOutcome.saved;
    } on Object {
      if (created) {
        try {
          await dest.delete();
        } on Object {
          // Best effort: we created it, nothing more to do.
        }
      }
      return RecapSaveOutcome.failed;
    }
  }

  /// Shares [bytes] as a file named [suggestedName] through the share sheet.
  Future<RecapShareOutcome> share(
    Uint8List bytes, {
    required String suggestedName,
    required RecapExportType type,
    Rect? origin,
  }) async {
    if (!_platform.canShare) return RecapShareOutcome.unavailable;
    final epoch = _releaseEpoch;
    String? exportDir;
    var keep = false;
    try {
      exportDir = await _begin();
      final temp = File(p.join(exportDir, suggestedName));
      await temp.writeAsBytes(bytes, flush: true);
      final status = await _platform.share(
        path: temp.path,
        type: type,
        origin: origin,
      );
      if (epoch == _releaseEpoch) {
        // A chosen target may still be reading the file: hold it.
        _inFlight.remove(exportDir);
        _held = exportDir;
        keep = true;
      }
      return switch (status) {
        RecapShareStatus.shared => RecapShareOutcome.shared,
        RecapShareStatus.dismissed => RecapShareOutcome.dismissed,
        RecapShareStatus.unknown => RecapShareOutcome.unknown,
      };
    } on Object {
      return RecapShareOutcome.failed;
    } finally {
      if (exportDir != null) {
        if (!keep) await _remove(exportDir);
      }
    }
  }

  /// Removes the file kept for the last share.
  Future<void> release() async {
    _releaseEpoch++;
    final held = _held;
    _held = null;
    if (held != null) await _remove(held);
  }
}

final recapExportFilesProvider = Provider<RecapExportFiles>(
  (ref) => RecapExportFiles(platform: ref.read(recapExportPlatformProvider)),
);
