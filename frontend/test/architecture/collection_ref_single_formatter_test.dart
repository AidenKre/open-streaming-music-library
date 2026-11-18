// Phase 6 §4 / SC-06 (6-U02): `CollectionRef` is the only code that formats
// or parses collection history refs (`<instance_id>:<id>`). Any other file
// that interpolates an instance id before a colon, splits or searches a
// string on ':', or builds a `HistoryIntent` by hand would be a second
// formatter or parser.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _formatter = 'lib/models/collection_ref.dart';
const _intent = 'lib/models/history_intent.dart';

Iterable<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));

/// `file:line: text` for every line of lib/ (outside [except]) matching
/// [pattern].
List<String> _offenders(RegExp pattern, {required Set<String> except}) => [
      for (final file in _dartFiles('lib'))
        if (!except.contains(file.path))
          for (final (i, line) in file.readAsLinesSync().indexed)
            if (pattern.hasMatch(line)) '${file.path}:${i + 1}: ${line.trim()}',
    ];

/// An instance id (or a bound prefix) interpolated right before a colon:
/// `'$instanceId:'`, `'${binding.instanceId!}:'`, `'${b.instanceId ?? ''}:'`,
/// `'$bound:'`, `'$boundInstanceId:'`.
final _prefixFormat = RegExp(r'\$(\{[^}]*([iI]nstance|[bB]ound)[^}]*\}'
    r'|[A-Za-z_]*([iI]nstance|[bB]ound)[A-Za-z0-9_]*):');

/// A string split or searched on a colon, literal or RegExp.
final _colonParse = RegExp(
    r'''\b(split|indexOf|lastIndexOf|contains)\(\s*(RegExp\(\s*r?)?['"]:['"]''');

/// Any `HistoryIntent(...)` construction: outside the model file only
/// `HistoryIntent.track` and `HistoryIntent.forScope` build intents.
final _intentCtor = RegExp(r'\bHistoryIntent\(');

void main() {
  test('the guard patterns catch the hand-written forms they target', () {
    for (final line in [
      r"""final ref = '$instanceId:$id';""",
      r"""final ref = '${binding.instanceId!}:$id';""",
      r"""final ref = '${b.instanceId ?? ''}:${scope.albumId}';""",
      r"""if (ref.startsWith('$bound:')) {""",
      r"""final p = '$boundInstanceId:';""",
    ]) {
      expect(_prefixFormat.hasMatch(line), isTrue, reason: line);
    }
    expect(_prefixFormat.hasMatch(r"""return '$minutes:$ss';"""), isFalse);
    for (final line in [
      r"""ref.split(':')""",
      r"""ref.split(RegExp(':'))""",
      r"""ref.split(RegExp(r':'))""",
      r"""ref.indexOf(':')""",
      r"""ref.contains(':')""",
    ]) {
      expect(_colonParse.hasMatch(line), isTrue, reason: line);
    }
    for (final line in [
      r"""HistoryIntent('album', ref)""",
      r"""HistoryIntent(type, ref.format())""",
      r"""const HistoryIntent('artist', 'x')""",
    ]) {
      expect(_intentCtor.hasMatch(line), isTrue, reason: line);
    }
    expect(_intentCtor.hasMatch('HistoryIntent.track(uuid)'), isFalse);
  });

  test('the formatter exists where this guard expects it', () {
    final source = File(_formatter).readAsStringSync();
    expect(source, contains('final class CollectionRef'));
    expect(source, contains('static CollectionRef? tryParse('));
    expect(source, contains('static CollectionRef? fromScope('));
  });

  test('no other file interpolates an instance id before a colon', () {
    expect(_offenders(_prefixFormat, except: {_formatter}), isEmpty);
  });

  test('no other file splits or searches a string on a colon', () {
    expect(_offenders(_colonParse, except: {_formatter}), isEmpty);
  });

  test('intents are built only in the HistoryIntent model file', () {
    expect(_offenders(_intentCtor, except: {_intent}), isEmpty);
  });
}
