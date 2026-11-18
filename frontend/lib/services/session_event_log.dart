import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:path/path.dart' as p;

/// The session event lines kept in a small file in the app's support folder,
/// so a release build keeps them too: one line per event, a UTC timestamp, a
/// space and the message (never a path or a secret), the newest [maxLines]
/// lines. A failing write never affects the app; a local reset removes the
/// file, best effort.
class SessionEventLogFile implements LocalResettable {
  SessionEventLogFile(this.directory, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final Directory directory;
  final DateTime Function() _now;

  static const maxLines = 200;

  /// Appends and resets run one after another, in the order they were asked.
  Future<void> _chain = Future<void>.value();

  File get file => File(p.join(directory.path, 'session_events.log'));

  /// Adds one line for [message]. Never throws, and its future never
  /// completes with an error.
  Future<void> append(String message) => _enqueue(() async {
        try {
          final line = '${_now().toUtc().toIso8601String()} '
              '${message.replaceAll(RegExp(r'\r\n|\n|\r'), ' ')}';
          final f = file;
          var lines = <String>[];
          try {
            if (await f.exists()) lines = await f.readAsLines();
          } catch (_) {
            lines = <String>[]; // unreadable as text: start over
          }
          lines.add(line);
          if (lines.length > maxLines) {
            lines = lines.sublist(lines.length - maxLines);
          }
          await directory.create(recursive: true);
          await f.writeAsString('${lines.join('\n')}\n', flush: true);
        } catch (_) {
          // A failing write (a folder in the way, a full disk) is ignored.
        }
      });

  /// Completes once every append and reset queued so far has finished.
  Future<void> idle() => _chain;

  @override
  int get resetPriority => ResetPriority.deleteFiles;

  /// Deletes the file after the queued appends. Best effort: the file names
  /// no user, and a failed wipe step would keep the pending-reset marker and
  /// block every connect until it could be deleted (review r1 #6).
  @override
  Future<void> resetLocalState() => _enqueue(() async {
        try {
          final f = file;
          if (await f.exists()) await f.delete();
        } catch (e) {
          developer.log(
            'The session log file was not removed: ${e.runtimeType}',
            name: 'SessionEventLogFile',
          );
        }
      });

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _chain.then((_) => op());
    _chain = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}

/// The app's session log file; null in tests and previews (no file).
final sessionEventLogFileProvider = Provider<SessionEventLogFile?>(
  (ref) => null,
);
