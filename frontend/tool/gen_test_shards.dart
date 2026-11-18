// Generates aggregated test entry points for a faster, optional test command.
//
// Usage (from frontend/):
//   dart run tool/gen_test_shards.dart --shards N [--timings <csv>] [--inject-duplicate]
//
// Writes test_shards/shard_<kk>_of_<nn>.dart (gitignored, outside test/, not
// named *_test.dart, so a plain `flutter test` never discovers them) and
// test_shards/excluded.txt (files that must be run per-file). Exits non-zero
// if any test file is unassigned or assigned more than once.
//
// --timings: optional baseline CSV with header columns `file` and `sum_test_s`
// (rows may be prefixed `frontend/`; non-frontend rows are ignored). Without it,
// files are balanced by byte size. Both modes are deterministic.
// --inject-duplicate: self-check only; assigns one file twice to prove the
// validation fails loudly.
// --inject-corrupt-write: self-check only; after writing, drops one import line
// from a written shard to prove the post-write validation fails loudly.
//
// Refuses --shards N larger than the number of included files (would write
// empty shards). After writing, re-reads every written shard and excluded.txt
// and checks them against the discovered set; exits non-zero on any mismatch.
import 'dart:io';

/// Files NOT aggregated, as `path relative to frontend/` -> reason.
/// Initially empty. Excluded files go to test_shards/excluded.txt and the fast
/// command runs them per-file, so every test is still covered.
const Map<String, String> excluded = <String, String>{
  // 'test/example_test.dart': 'reason it cannot share an isolate',
};

/// Escapes text for use inside a single-quoted Dart string literal.
String dartEscape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll("'", r"\'")
    .replaceAll(r'$', r'\$');

String dartUnescape(String s) => s.replaceAllMapped(
      RegExp(r'\\(.)'),
      (m) => m[1]!,
    );

Never fail(String msg) {
  stderr.writeln('gen_test_shards: ERROR: $msg');
  exit(1);
}

void main(List<String> args) {
  int? shards;
  String? timingsPath;
  var injectDuplicate = false;
  var injectCorruptWrite = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--shards':
        if (i + 1 >= args.length) fail('--shards needs a value');
        shards = int.tryParse(args[++i]);
      case '--timings':
        if (i + 1 >= args.length) fail('--timings needs a value');
        timingsPath = args[++i];
      case '--inject-duplicate':
        injectDuplicate = true;
      case '--inject-corrupt-write':
        injectCorruptWrite = true;
      default:
        fail('unknown argument ${args[i]}');
    }
  }
  if (shards == null || shards < 1 || shards > 99) {
    fail('--shards N (1..99) is required');
  }
  if (!File('pubspec.yaml').existsSync() || !Directory('test').existsSync()) {
    fail('run from the frontend/ directory');
  }

  // Discover.
  final all = Directory('test')
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .map((f) => f.path.replaceAll('\\', '/'))
      .where((p) => p.endsWith('_test.dart'))
      .toList()
    ..sort();
  if (all.isEmpty) fail('no test files found');
  for (final e in excluded.keys) {
    if (!all.contains(e)) fail('excluded file not found: $e');
  }
  final included = all.where((p) => !excluded.containsKey(p)).toList();

  if (shards > included.length) {
    fail('--shards $shards exceeds the ${included.length} included files '
        '(would write empty shards); nothing written');
  }

  // Weights.
  final weight = <String, double>{};
  if (timingsPath != null) {
    final lines = File(timingsPath).readAsLinesSync();
    final header = lines.first.split(',');
    final fi = header.indexOf('file');
    final ti = header.indexOf('sum_test_s');
    final si = header.indexOf('stack');
    if (fi < 0 || ti < 0) fail('timings csv needs `file` and `sum_test_s`');
    for (final l in lines.skip(1)) {
      final c = l.split(',');
      if (c.length <= ti || c.length <= fi) continue;
      if (si >= 0 && c[si] != 'frontend') continue;
      final f = c[fi].startsWith('frontend/') ? c[fi].substring(9) : c[fi];
      weight[f] = double.tryParse(c[ti]) ?? 0;
    }
  }
  // Each file costs a fixed overhead plus its measured time (or size).
  double w(String p) => timingsPath != null
      ? 0.4 + (weight[p] ?? 1.0)
      : File(p).lengthSync() / 1024.0 + 1.0;

  // Greedy longest-first; ties broken by path, bins by lowest load then index.
  final order = [...included]..sort((a, b) {
      final c = w(b).compareTo(w(a));
      return c != 0 ? c : a.compareTo(b);
    });
  final bins = List.generate(shards, (_) => <String>[]);
  final load = List<double>.filled(shards, 0);
  for (final p in order) {
    var best = 0;
    for (var k = 1; k < shards; k++) {
      if (load[k] < load[best]) best = k;
    }
    bins[best].add(p);
    load[best] += w(p);
  }
  if (injectDuplicate && bins.isNotEmpty && included.isNotEmpty) {
    bins[bins.length - 1].add(included.first);
  }
  for (final b in bins) {
    b.sort();
  }

  // Validate: every file exactly once, nothing unknown.
  final seen = <String, int>{};
  for (final b in bins) {
    for (final p in b) {
      seen[p] = (seen[p] ?? 0) + 1;
    }
  }
  final problems = <String>[];
  for (final p in included) {
    final n = seen[p] ?? 0;
    if (n == 0) problems.add('unassigned: $p');
    if (n > 1) problems.add('assigned $n times: $p');
  }
  for (final p in seen.keys) {
    if (!included.contains(p)) problems.add('unknown file assigned: $p');
  }
  if (problems.isNotEmpty) fail(problems.join('\n'));

  // Write.
  final out = Directory('test_shards');
  if (out.existsSync()) {
    for (final f in out.listSync().whereType<File>()) {
      final n = f.uri.pathSegments.last;
      if (n.startsWith('shard_') || n == 'excluded.txt') f.deleteSync();
    }
  } else {
    out.createSync();
  }
  final nn = shards.toString().padLeft(2, '0');
  for (var k = 0; k < shards; k++) {
    final kk = (k + 1).toString().padLeft(2, '0');
    final b = StringBuffer()
      ..writeln('// GENERATED by tool/gen_test_shards.dart; do not edit or commit.')
      ..writeln('// ignore_for_file: unused_import, directives_ordering')
      ..writeln("import 'package:flutter_test/flutter_test.dart';");
    for (var i = 0; i < bins[k].length; i++) {
      final rel = bins[k][i].substring('test/'.length);
      b.writeln("import '../test/${dartEscape(rel)}' as f$i;");
    }
    b
      ..writeln()
      ..writeln('void main() {');
    for (var i = 0; i < bins[k].length; i++) {
      b.writeln("  group('${dartEscape(bins[k][i])}', f$i.main);");
    }
    b.writeln('}');
    File('test_shards/shard_${kk}_of_$nn.dart').writeAsStringSync(b.toString());
  }
  File('test_shards/excluded.txt').writeAsStringSync(
    excluded.keys.map((e) => '$e\n').join(),
  );

  if (injectCorruptWrite) {
    final f = File('test_shards/shard_01_of_$nn.dart');
    final ls = f.readAsLinesSync();
    final idx = ls.indexWhere((l) => l.startsWith("import '../test/"));
    if (idx >= 0) {
      ls.removeAt(idx);
      f.writeAsStringSync('${ls.join('\n')}\n');
    }
  }

  // Post-write validation: re-read what is on disk.
  final wp = <String>[];
  final onDisk = <String, int>{};
  final shardFiles = Directory('test_shards')
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'shard_\d+_of_\d+\.dart$').hasMatch(f.path))
      .toList();
  if (shardFiles.length != shards) {
    wp.add('expected $shards shard files, found ${shardFiles.length}');
  }
  final importRe = RegExp(r"^import '\.\./test/(.*)' as f\d+;$");
  for (final f in shardFiles) {
    for (final l in f.readAsLinesSync()) {
      final m = importRe.firstMatch(l);
      if (m == null) continue;
      final p = 'test/${dartUnescape(m[1]!)}';
      onDisk[p] = (onDisk[p] ?? 0) + 1;
    }
  }
  for (final p in included) {
    final n = onDisk[p] ?? 0;
    if (n == 0) wp.add('written shards miss: $p');
    if (n > 1) wp.add('written shards contain $n times: $p');
  }
  for (final p in onDisk.keys) {
    if (!included.contains(p)) wp.add('written shards contain unknown: $p');
  }
  final exOnDisk = File('test_shards/excluded.txt')
      .readAsLinesSync()
      .where((l) => l.isNotEmpty)
      .toList();
  if (exOnDisk.length != excluded.length ||
      exOnDisk.toSet().length != exOnDisk.length ||
      !exOnDisk.every(excluded.containsKey)) {
    wp.add('excluded.txt does not match the exclusion map');
  }
  if (wp.isNotEmpty) fail('post-write validation failed:\n${wp.join('\n')}');

  stdout.writeln(
    'gen_test_shards: ${included.length} files in $shards shards, '
    '${excluded.length} excluded (of ${all.length}).',
  );
}
