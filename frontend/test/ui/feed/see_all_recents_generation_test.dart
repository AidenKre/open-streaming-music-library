// Phase 6 §7 / 6-U08 (late completions, disposal, filter refresh), 6-G03
// (final generation wins): the See all controller against a pager and a
// freshness watcher whose every result the test releases by hand.
//
//  * Every new snapshot (chip change, Refresh) bumps a generation; a capture,
//    page, live emission or freshness value from an older one is ignored.
//  * Retry repeats the failed request and keeps the loaded rows.
//  * Dispose cancels the live watch and the freshness watch; a request that
//    completes afterwards changes nothing.
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show ValueKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/repositories/recently_played_repository.dart';
import 'package:frontend/repositories/recents_snapshot_pager.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/feed/see_all_recents_controller.dart';

import '../../helpers/fake_recents_pager.dart';
import '../../helpers/test_offline.dart';

List<String>? keysOf(SeeAllRecentsControls c) =>
    c.entities?.map((e) => (e.key as ValueKey<String>).value).toList();

void main() {
  late AppDatabase db;
  late FakePager pager;
  late FakeFreshness freshness;
  late ProviderContainer container;
  late SeeAllRecentsControls c;
  var disposed = false;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    pager = FakePager();
    freshness = FakeFreshness();
    pager.freshness = freshness;
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        offlineModeProvider.overrideWith(() => TestOffline(false)),
        recentsSnapshotPagerProvider.overrideWithValue(pager),
        snapshotFreshnessProvider.overrideWithValue(freshness),
      ],
    );
    disposed = false;
    c = container.read(seeAllRecentsControllerFactoryProvider)(
      initialDownloaded: false,
    );
  });

  tearDown(() async {
    if (!disposed) c.dispose();
    container.dispose();
    await db.close();
  });

  /// Captures and answers the first page of the entry snapshot.
  Future<HistorySnapshotToken> enter(List<String> uuids, {bool more = true}) async {
    final t = await pager.grant(0);
    await pager.answer(0, pageOf(uuids, more: more));
    return t;
  }

  group('final generation wins', () {
    test('a chip flip during hydration: the newer page lands, the older one '
        'arriving later is ignored', () async {
      await pager.grant(0);
      expect(pager.pages, hasLength(1));
      c.setDownloaded(true);
      expect(pager.captures.last.downloadedOnly, isTrue);
      await pager.grant(1);
      expect(pager.pages, hasLength(2));
      await pager.answer(1, pageOf(['on']));
      expect(keysOf(c), ['track:on']);
      await pager.answer(0, pageOf(['off-1', 'off-2']));
      expect(keysOf(c), ['track:on']);
    });

    test('a chip flip during hydration: the older page arriving first is '
        'ignored and the snapshot stays loading', () async {
      await pager.grant(0);
      c.setDownloaded(true);
      await pager.grant(1);
      await pager.answer(0, pageOf(['off']));
      expect(c.entities, isNull);
      await pager.answer(1, pageOf(['on']));
      expect(keysOf(c), ['track:on']);
    });

    test('a capture that completes after a chip flip requests no page',
        () async {
      c.setDownloaded(true);
      await pager.grant(1);
      await pager.grant(0);
      expect(pager.pages, hasLength(1));
      expect(pager.pages.single.token.filterKey, (downloadedOnly: true));
    });

    test('a next page that completes after Refresh is not appended; the new '
        'snapshot starts from no cursor', () async {
      await enter(['a', 'b']);
      c.loadMore();
      expect(pager.pages, hasLength(2));
      expect(pager.pages[1].after, recent('b').ref);
      final epoch = c.snapshotEpoch;
      c.refresh();
      expect(c.snapshotEpoch, isNot(epoch));
      await pager.grant(1);
      expect(pager.pages[2].after, isNull);
      await pager.answer(2, pageOf(['n']));
      await pager.answer(1, pageOf(['stale']));
      expect(keysOf(c), ['track:n']);
      expect(c.hasMore, isFalse);
    });

    test('a live emission from the previous watch is ignored', () async {
      await enter(['a', 'b']);
      expect(pager.watches, hasLength(1));
      expect(pager.watches[0].refs, [recent('a').ref, recent('b').ref]);
      c.loadMore();
      await pager.answer(1, pageOf(['c']));
      expect(keysOf(c), ['track:a', 'track:b', 'track:c']);
      expect(pager.watches, hasLength(2));
      expect(pager.watches[0].stream.cancelled, isTrue);
      expect(pager.watches[1].refs, [
        recent('a').ref,
        recent('b').ref,
        recent('c').ref,
      ]);
      pager.watches[0].stream.emit([recent('a')]);
      expect(keysOf(c), ['track:a', 'track:b', 'track:c']);
    });

    test('a freshness value for the previous token is ignored', () async {
      await enter(['a']);
      expect(freshness.calls, hasLength(1));
      c.refresh();
      await pumpEventQueue();
      expect(freshness.calls.first.cancelled, isTrue);
      freshness.calls.first.controller.add(SnapshotStaleness.newActivity);
      await pumpEventQueue();
      expect(c.notice, SnapshotStaleness.fresh);
    });
  });

  group('live and notices', () {
    test('a live emission updates rows in place and keeps hasMore', () async {
      await enter(['a', 'b']);
      pager.watches.single.stream.emit([
        recent('a', title: 'Renamed'),
        recent('b'),
      ]);
      expect((c.entities!.first as TrackEntity).track.title, 'Renamed');
      expect(c.hasMore, isTrue);
      pager.watches.single.stream.emit([recent('b')]);
      expect(keysOf(c), ['track:b']);
    });

    test('freshness for the current token drives the notice', () async {
      final t = await enter(['a']);
      expect(freshness.calls.single.token, t);
      freshness.calls.single.controller.add(SnapshotStaleness.newActivity);
      await pumpEventQueue();
      expect(c.notice, SnapshotStaleness.newActivity);
      freshness.calls.single.controller.add(SnapshotStaleness.historyChanged);
      await pumpEventQueue();
      expect(c.notice, SnapshotStaleness.historyChanged);
    });

    // Review r1 #3: a freshness stream error is not an uncaught error and
    // changes nothing on screen.
    test('a freshness error is handled and leaves the notice alone', () async {
      await enter(['a']);
      freshness.calls.single.controller.addError(StateError('closed'));
      await pumpEventQueue();
      expect(c.notice, SnapshotStaleness.fresh);
      expect(keysOf(c), ['track:a']);
      expect(c.failed, isFalse);
    });

    test('an expired page stops the continuation, keeps the rows, and its '
        'History changed is not undone by a later freshness value', () async {
      await enter(['a', 'b']);
      c.loadMore();
      await pager.answer(1, const SnapshotExpired<ResolvedRecent, RecentRef>());
      expect(c.notice, SnapshotStaleness.historyChanged);
      expect(c.hasMore, isFalse);
      expect(c.failed, isFalse);
      expect(keysOf(c), ['track:a', 'track:b']);
      freshness.calls.single.controller.add(SnapshotStaleness.newActivity);
      await pumpEventQueue();
      expect(c.notice, SnapshotStaleness.historyChanged);
      c.loadMore();
      expect(pager.pages, hasLength(2));
    });
  });

  group('paging guards and retry', () {
    test('loadMore is a no-op before the first page, while a page is in '
        'flight, and after the last page', () async {
      c.loadMore();
      expect(pager.pages, isEmpty);
      await enter(['a'], more: true);
      c.loadMore();
      c.loadMore();
      expect(pager.pages, hasLength(2));
      expect(pager.pages[1].limit, 50);
      await pager.answer(1, pageOf(['b']));
      c.loadMore();
      expect(pager.pages, hasLength(2));
    });

    test('a failed first page: failed, then Retry repeats it', () async {
      await pager.grant(0);
      pager.pages[0].done.completeError(StateError('db'));
      await pumpEventQueue();
      expect(c.failed, isTrue);
      expect(c.entities, isNull);
      c.retry();
      expect(pager.pages, hasLength(2));
      expect(pager.pages[1].token, pager.pages[0].token);
      expect(pager.pages[1].after, isNull);
      await pager.answer(1, pageOf(['a']));
      expect(c.failed, isFalse);
      expect(keysOf(c), ['track:a']);
    });

    test('a failed next page keeps the loaded rows; Retry asks for the same '
        'cursor', () async {
      await enter(['a', 'b']);
      c.loadMore();
      pager.pages[1].done.completeError(StateError('db'));
      await pumpEventQueue();
      expect(c.failed, isTrue);
      expect(keysOf(c), ['track:a', 'track:b']);
      expect(c.hasMore, isTrue);
      c.retry();
      expect(pager.pages, hasLength(3));
      expect(pager.pages[2].after, recent('b').ref);
      await pager.answer(2, pageOf(['c']));
      expect(c.failed, isFalse);
      expect(keysOf(c), ['track:a', 'track:b', 'track:c']);
    });

    test('a failed capture: failed, then Retry captures again', () async {
      pager.captures[0].done.completeError(StateError('db'));
      await pumpEventQueue();
      expect(c.failed, isTrue);
      c.retry();
      expect(pager.captures, hasLength(2));
      await pager.grant(1);
      await pager.answer(0, pageOf(['a']));
      expect(keysOf(c), ['track:a']);
    });
  });

  test('dispose cancels the watches; late results change nothing', () async {
    await enter(['a', 'b']);
    c.loadMore();
    var notified = 0;
    c.addListener(() => notified++);
    c.dispose();
    disposed = true;
    await pumpEventQueue();
    expect(pager.watches.single.stream.cancelled, isTrue);
    expect(freshness.calls.single.cancelled, isTrue);
    await pager.answer(1, pageOf(['c']));
    pager.watches.single.stream.emit([recent('a')]);
    freshness.calls.single.controller.add(SnapshotStaleness.newActivity);
    await pumpEventQueue();
    expect(notified, 0);
  });

  // B-332-08 (owner's answer to worklist question 4 (b)): Retry after the
  // page was closed does nothing.
  test('Retry after dispose does nothing', () async {
    await pager.grant(0);
    pager.pages[0].done.completeError(StateError('db'));
    await pumpEventQueue();
    expect(c.failed, isTrue);
    c.dispose();
    disposed = true;
    expect(() => c.retry(), returnsNormally);
    expect(pager.pages, hasLength(1));
  });

  test('dispose during the entry capture: nothing is requested afterwards',
      () async {
    c.dispose();
    disposed = true;
    await pager.grant(0);
    expect(pager.pages, isEmpty);
  });
}
