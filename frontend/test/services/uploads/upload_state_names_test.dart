// The owner's rule for a value used in several places (2026-11-20): "make
// sure that this becomes a data type, and is not manually copied across
// every place that uses it". Every upload item state name is
// written once, as a constant in upload_item_rules.dart, and the server's
// names there are exactly the server's own list. The expected names are
// written here by hand, never taken from production code.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The server's item states, by hand.
const _serverStates = {
  'allocated', 'receiving', 'validating', 'review_ready', 'committing',
  'imported', 'duplicate', 'expanded', 'failed', 'duplicate_conflict',
  'expired', 'cancelled',
};

/// The local states an upload intent holds besides the server's, by hand.
const _localStates = {
  'allocating', 'transferring', 'source_changed', 'needs_reselect',
  'rejected', 'cancelling', 'review_submitted', 'on_other_device',
};

const _rulesPath = 'lib/services/uploads/upload_item_rules.dart';

/// Where a state name may not be written as a string literal.
const _folders = ['lib/services/uploads', 'lib/ui/uploads'];

/// A state name's own definition, `static const name = 'value';`.
final _definition = RegExp(r"^static const \w+ = '[a-z_]+';$");

/// Lines that spell an error code, not a state, the same as a state: the
/// local source check's `source_changed` code (stored in `last_error_code`,
/// beside `source_unavailable`). Matched as the whole trimmed line.
const _errorCodeLines = {
  'lib/services/uploads/upload_manager.dart': {
    "UploadSourceChanged() => const SubmissionTerminal('source_changed'),",
    "case SubmissionRejected(code: 'source_changed' || 'source_unavailable'):",
    "final changed = outcome.code == 'source_changed';",
  },
};

/// The string values of the `static const` names of [className] in the
/// rules file (sets are not strings, so not matched).
Set<String> _constantValues(String className) {
  final source = File(_rulesPath).readAsStringSync();
  final body = RegExp(
    'abstract final class $className \\{([\\s\\S]*?)\\n\\}',
  ).firstMatch(source);
  expect(body, isNotNull, reason: className);
  return {
    for (final m in RegExp(
      r"static const \w+ = '([a-z_]+)';",
    ).allMatches(body!.group(1)!))
      m.group(1)!,
  };
}

void main() {
  test('the rules file names exactly the server and the local states', () {
    expect(_constantValues('ServerItemState'), _serverStates);
    expect(
      _constantValues('UploadIntentState'),
      {..._localStates, 'allocated'},
    );
  });

  test("the server item states are the server's CHECK list, both ways", () {
    final sql = File('../backend/app/database/init.sql').readAsStringSync();
    final table = RegExp(
      r'CREATE TABLE IF NOT EXISTS upload_items \(([\s\S]*?)\n\);',
    ).firstMatch(sql);
    expect(table, isNotNull);
    final check = RegExp(
      r'\n\s*state\s+TEXT NOT NULL CHECK \(state IN \(([^)]*)\)\)',
    ).firstMatch(table!.group(1)!);
    expect(check, isNotNull);
    final listed = {
      for (final m in RegExp(r"'([a-z_]+)'").allMatches(check!.group(1)!))
        m.group(1)!,
    };
    expect(listed, _serverStates);
    expect(_constantValues('ServerItemState'), listed);
  });

  test('no upload state name is written as a string literal except as its '
      'constant in the rules file', () {
    final names = {..._serverStates, ..._localStates};
    // A whole single- or double-quoted literal that is exactly a state name.
    final literal = RegExp(
      '([\'"])(${names.join('|')})\\1',
    );
    final found = <String>[];
    var files = 0;
    for (final folder in _folders) {
      for (final f in Directory(folder)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final path = f.path.replaceAll(r'\', '/');
        files++;
        final allowed = _errorCodeLines[path] ?? const <String>{};
        final lines = f.readAsLinesSync();
        for (var n = 0; n < lines.length; n++) {
          final line = lines[n].trim();
          if (line.startsWith('//')) continue; // comments, docs
          if (allowed.contains(line)) continue;
          // The one place a name is written: its constant in the rules file.
          if (path == _rulesPath && _definition.hasMatch(line)) continue;
          for (final m in literal.allMatches(line)) {
            found.add('$path:${n + 1}: ${m.group(0)}');
          }
        }
      }
    }
    expect(files, greaterThan(20), reason: 'the folders were read');
    expect(found, isEmpty);
  });

  test('every allowed error-code line still exists, so the list cannot '
      'go stale', () {
    for (final MapEntry(key: path, value: lines) in _errorCodeLines.entries) {
      final present = {
        for (final l in File(path).readAsLinesSync()) l.trim(),
      };
      for (final l in lines) {
        expect(present, contains(l), reason: '$path: $l');
      }
    }
  });
}
