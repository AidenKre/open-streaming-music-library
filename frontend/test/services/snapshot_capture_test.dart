// Phase 9 review r1, 9-R1-09 / 9-R1-14: a snapshot token and the reads
// made under it come from ONE read transaction (SC-10). A writer that
// commits right after the token's counters were read must not land between
// the capture and the reads: otherwise the surface shows current numbers
// under an older token, and the freshness notice ("History changed —
// Refresh") appears at once although nothing changed after the load.
//
// How: an interceptor starts the writer as soon as the capture SELECT has
// returned. Drift runs statements in order, so a writer queued while one
// transaction is open waits for it to end; with capture and reads in two
// transactions it would run between them.
//
// Real in-memory SQLite; expected values from the independent workbook
// (stats) or from a load taken before the write (recap, Home).
import 'dart:async';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/suggestions.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/listening_rank_pagers.dart';
import 'package:frontend/repositories/home_suggestions_service.dart';
import 'package:frontend/repositories/listening_stats_repository.dart';
import 'package:frontend/repositories/suggestion_pools_repository.dart';
import 'package:frontend/services/annual_recap_service.dart';
import 'package:frontend/services/listening_stats_service.dart';

import '../helpers/fake_clock.dart';
import '../repositories/listening_stats_workbook.dart';

const _eps = 1e-6;

/// Runs [after] once, right after the [at]-th SELECT has returned.
class _AfterSelect extends QueryInterceptor {
  int selects = 0;
  int? at;
  void Function()? after;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    selects++;
    if (selects == at) after?.call();
    return rows;
  }
}

/// Pools that record the counters their own read sees.
class _CounterPools implements SuggestionPoolsRepository {
  _CounterPools(this.db);
  final AppDatabase db;
  int? seenHistoryContent;

  @override
  Future<SuggestionPools> load(int boundaryLocalId, int capturedNowUtcMs) async {
    final row = await db
        .customSelect(
          "SELECT COALESCE((SELECT value FROM local_counters WHERE key = "
          "'history_content'), 0) AS h",
          readsFrom: {db.localCounters},
        )
        .getSingle();
    seenHistoryContent = row.read<int>('h');
    return SuggestionPools(
      boundaryLocalId: boundaryLocalId,
      capturedNowUtcMs: capturedNowUtcMs,
      rediscover: const [],
      artists: const [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<int> _counter(AppDatabase db, String key) async {
  final row = await db
      .customSelect(
        'SELECT COALESCE((SELECT value FROM local_counters WHERE key = ?), 0) '
        'AS v',
        variables: [Variable.withString(key)],
        readsFrom: {db.localCounters},
      )
      .getSingle();
  return row.read<int>('v');
}

void main() {
  final workbook = Workbook.load();
  final seven = workbook.cases.firstWhere((c) => c.name == '7 days');
  late AppDatabase db;
  late _AfterSelect interceptor;
  late FakeClock clock;
  late ListeningStatsRepository repo;
  late HistorySnapshotService snapshots;
  Future<void>? writing;

  /// A history edit and a catalog tombstone: bumps both counters and
  /// changes the 7-day totals.
  Future<void> write() async {
    await db.customUpdate(
      'UPDATE history_events SET seconds_played = 9000 '
      "WHERE event_uuid = 'e-rewind'",
      updates: {db.historyEvents},
      updateKind: UpdateKind.update,
    );
    await db.customUpdate(
      "DELETE FROM trackmetadata WHERE uuid_id = 't-b'",
      updates: {db.trackmetadata},
      updateKind: UpdateKind.delete,
    );
  }

  /// The writer starts right after the next SELECT (the capture's) returns.
  /// It is registered here, in the test's zone, so it is an ordinary
  /// statement outside any transaction (the interceptor runs inside one).
  void writeAfterCapture() {
    final reached = Completer<void>();
    interceptor.at = interceptor.selects + 1;
    interceptor.after = reached.complete;
    writing = reached.future.then((_) => write());
  }

  setUp(() async {
    interceptor = _AfterSelect();
    db = AppDatabase(NativeDatabase.memory().interceptWith(interceptor));
    await workbook.seed(db);
    clock = FakeClock(startUtcMs: seven.capturedNowMs);
    repo = ListeningStatsRepository(db, BrowseRepository(db));
    snapshots = HistorySnapshotService(db, clock: clock);
    writing = null;
  });

  tearDown(() async {
    await writing;
    await db.close();
  });

  test('captureWith: the read sees exactly the token counters', () async {
    final before = await _counter(db, 'history_content');
    writeAfterCapture();
    final (token, seen) = await snapshots.captureWith(
      'probe',
      (_) => _counter(db, 'history_content'),
      attribution: true,
    );
    await writing;
    expect(token.historyContentVersion, before);
    expect(seen, before);
    expect(await _counter(db, 'history_content'), before + 1);
  });

  test('statistics: numbers and token from one snapshot', () async {
    final hBefore = await _counter(db, 'history_content');
    final aBefore = await _counter(db, 'catalog_attribution');
    writeAfterCapture();
    final snap = await ListeningStatsService(repo, snapshots)
        .snapshot(seven.range);
    await writing;
    expect(snap.token.historyContentVersion, hBefore);
    expect(snap.token.catalogAttributionVersion, aBefore);
    expect(snap.stats.totals.listeningSeconds,
        closeTo(seven.listeningSeconds, _eps));
    expect(
      [for (final e in snap.stats.topTracks) e.entity.uuidId],
      [for (final w in seven.ranked('topTracks')) w.$1],
    );
    expect(snap.hasHistory, isTrue);
    expect(snap.stats.boundaryLocalId, snap.token.boundaryLocalId);
    expect(snap.stats.capturedNowUtcMs, snap.token.capturedNowUtcMs);
    // The writer did change the numbers (after the snapshot).
    final after = await repo.load(
      seven.range,
      workbook.maxLocalId,
      seven.capturedNowMs,
    );
    expect(after.totals.listeningSeconds,
        isNot(closeTo(seven.listeningSeconds, _eps)));
  });

  test('annual recap: recap, years and token from one snapshot', () async {
    const year = 2025; // the UTC year of the edited e-rewind (workbook)
    final expected = await repo.load(
      StatsRange.year(year),
      workbook.maxLocalId,
      seven.capturedNowMs,
    );
    final hBefore = await _counter(db, 'history_content');
    writeAfterCapture();
    final snap = await AnnualRecapService(repo, snapshots).snapshot(year: year);
    await writing;
    expect(snap.recap.year, year);
    expect(snap.recap.token.historyContentVersion, hBefore);
    expect(snap.recap.totals.listeningSeconds,
        closeTo(expected.totals.listeningSeconds, _eps));
    expect(snap.years, contains(year));
    final after = await repo.load(
      StatsRange.year(year),
      workbook.maxLocalId,
      seven.capturedNowMs,
    );
    expect(after.totals.listeningSeconds,
        isNot(closeTo(expected.totals.listeningSeconds, _eps)),
        reason: 'the writer changes this year');
  });

  // Review R2-FE-01: See all's Refresh captures a token and reads the first
  // page in one transaction, so that page is never expired at once.
  test('See all: the first page after a capture is never expired', () async {
    final pager = TopTracksPager(snapshots, repo);
    writeAfterCapture();
    final (token, page) = await pager.first(seven.range, 50);
    await writing;
    expect(page, isA<SnapshotPage<RankedPageEntry<Object, String>, Object>>()
        .having((p) => p.items, 'items', isNotEmpty));
    expect(token.filterKey, seven.range);
  });

  test('Home suggestions: pools read under the token counters', () async {
    final pools = _CounterPools(db);
    final service = HomeSuggestionsService(
      snapshots: snapshots,
      freshness: SnapshotFreshness(db),
      pools: pools,
      browse: BrowseRepository(db),
    );
    final before = await _counter(db, 'history_content');
    writeAfterCapture();
    final snapshot = await service.capture();
    await writing;
    expect(snapshot.token.historyContentVersion, before);
    expect(pools.seenHistoryContent, before);
  });
}
