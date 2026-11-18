// Fix 9-fix-r4-fe (live defect 9-L-03; spec §5 "must not block Home", §3
// performance fixture; plan O3/O14): the Home suggestion pools must not walk
// history_events once per candidate track.
//
// Always run: the query plan of every pool statement reads history_events
// only in uncorrelated passes (no history_events access under a CORRELATED
// subquery), so the cost cannot grow as candidates x history.
//
// Evidence (opt-in, like stats_perf_test.dart):
//   OSML_PERF_EVIDENCE=1 [OSML_PERF_EVENTS=<n>] [OSML_PERF_LEGACY=1] \
//     flutter test --concurrency=1 --timeout 200s \
//     test/repositories/suggestion_pools_perf_test.dart
// seeds the 9A.1c PerfFixture (seed 20261112; its first <n> events, default
// all 100,000, over the 10,000-track catalog), prints the plans and the
// timings, and asserts the budget below on the pools load (median of 3).
// OSML_PERF_LEGACY=1 also times the statement candidate aa5d50bd shipped,
// once (keep <n> small: it is the stall).
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/suggestion_pools_repository.dart';

import 'stats_perf_fixture.dart';
import 'suggestion_pools_legacy.dart';

/// Budget for one pools load at 100,000 events (debug-mode `flutter test`,
/// in-memory database, shared machine): spec §3 asks statistics refreshes
/// under 500 ms at this size; the pools are one more Home read of the same
/// history, so they get the same order of magnitude with headroom for
/// debug mode and load (the shipped statement took minutes).
const _budgetMs = 1500;

final _env = Platform.environment;
final _evidence = _env['OSML_PERF_EVIDENCE'] == '1';

class _Recorder extends QueryInterceptor {
  final selects = <({String sql, List<Object?> args})>[];
  final elapsedMs = <int>[];
  bool on = false;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (!on) return super.runSelect(executor, statement, args);
    selects.add((sql: statement, args: args));
    final sw = Stopwatch()..start();
    final rows = await super.runSelect(executor, statement, args);
    elapsedMs.add(sw.elapsedMilliseconds);
    return rows;
  }
}

typedef _PlanRow = ({int id, int parent, String detail});

Future<List<_PlanRow>> _plan(
  AppDatabase db,
  String sql,
  List<Object?> args,
) async => [
  for (final r in await db
      .customSelect(
        'EXPLAIN QUERY PLAN $sql',
        variables: [for (final a in args) Variable(a)],
      )
      .get())
    (
      id: r.read<int>('id'),
      parent: r.read<int>('parent'),
      detail: r.read<String>('detail'),
    ),
];

/// Plan lines below a CORRELATED subquery node that read history_events
/// (by name or through one of its `idx_history_events_*` indexes, which an
/// alias does not hide) or SCAN any table (an aliased full scan would print
/// only the alias).
List<String> _correlatedHistoryReads(List<_PlanRow> plan) {
  final byId = {for (final r in plan) r.id: r};
  final found = <String>[];
  for (final r in plan) {
    if (!r.detail.contains('history_events') &&
        !r.detail.startsWith('SCAN ')) {
      continue;
    }
    for (var p = byId[r.parent]; p != null; p = byId[p.parent]) {
      if (p.detail.contains('CORRELATED')) {
        found.add('${p.detail} > ${r.detail}');
        break;
      }
    }
  }
  return found;
}

String _render(List<_PlanRow> plan) =>
    [for (final r in plan) '${r.id}<-${r.parent} ${r.detail}'].join('\n  ');

void main() {
  test('no pool statement reads history_events once per candidate '
      '(no history read under a correlated subquery)', () async {
    final recorder = _Recorder();
    final db = AppDatabase(NativeDatabase.memory().interceptWith(recorder));
    addTearDown(db.close);
    recorder.on = true;
    await SuggestionPoolsRepository(db).load(1000, perfNowMs);
    recorder.on = false;
    final pools = recorder.selects
        .where((s) => s.sql.contains('history_events'))
        .toList();
    expect(pools, hasLength(3), reason: 'rediscover, recent artists, '
        'artist candidates');
    for (final s in pools) {
      final plan = await _plan(db, s.sql, s.args);
      expect(_correlatedHistoryReads(plan), isEmpty,
          reason: '${s.sql}\n  ${_render(plan)}');
    }
    // The check itself: the shipped statement is caught.
    final legacy = await _plan(db, legacyArtistCandidatesSql,
        [for (final v in legacyVars(1000, perfNowMs)) v.value]);
    expect(_correlatedHistoryReads(legacy), isNotEmpty);
  });

  test('timings at the performance fixture (evidence; budget '
      '$_budgetMs ms)', skip: _evidence ? false :
      'set OSML_PERF_EVIDENCE=1 to measure', () async {
    final n = int.parse(_env['OSML_PERF_EVENTS'] ?? '$perfEventCount');
    final recorder = _Recorder();
    final db = AppDatabase(NativeDatabase.memory().interceptWith(recorder));
    addTearDown(db.close);
    final sw = Stopwatch()..start();
    final fixture = PerfFixture.generate();
    await fixture.seed(db, eventLimit: n);
    final boundary = n;
    // ignore: avoid_print
    print('PERF pools fixture: $n events, ${fixture.tracks.length} tracks, '
        'seeded in ${sw.elapsedMilliseconds} ms');
    final repo = SuggestionPoolsRepository(db);

    recorder
      ..selects.clear()
      ..elapsedMs.clear()
      ..on = true;
    final pools = await repo.load(boundary, perfNowMs);
    recorder.on = false;
    for (var i = 0; i < recorder.selects.length; i++) {
      final s = recorder.selects[i];
      if (!s.sql.contains('history_events')) continue;
      // ignore: avoid_print
      print('PERF pools stmt ${recorder.elapsedMs[i]} ms: '
          '${s.sql.substring(0, 80)}\n  '
          '${_render(await _plan(db, s.sql, s.args))}');
    }
    final candidates =
        pools.artists.fold<int>(0, (a, p) => a + p.candidates.length);
    // ignore: avoid_print
    print('PERF pools sizes: rediscover ${pools.rediscover.length}, '
        'artists ${pools.artists.length}, candidates $candidates');

    final ms = <int>[];
    for (var i = 0; i < 3; i++) {
      final t = Stopwatch()..start();
      await repo.load(boundary, perfNowMs);
      ms.add(t.elapsedMilliseconds);
    }
    ms.sort();
    // ignore: avoid_print
    print('PERF pools load (median of 3, ms) ${ms[1]} (runs $ms)');

    if (_env['OSML_PERF_LEGACY'] == '1') {
      final t = Stopwatch()..start();
      await legacyArtistPools(db, boundary, perfNowMs);
      // ignore: avoid_print
      print('PERF legacy artist pools (once, ms) ${t.elapsedMilliseconds}\n  '
          '${_render(await _plan(db, legacyArtistCandidatesSql,
              [for (final v in legacyVars(boundary, perfNowMs)) v.value]))}');
    }
    expect(ms[1], lessThan(_budgetMs));
  }, timeout: const Timeout(Duration(seconds: 200)));
}
