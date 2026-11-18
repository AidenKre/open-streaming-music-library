// 8B.3 S3: the Possible duplicates controller's listing.
//  * Spec §6: "Scan status from /tracks/duplicates/summary"; "Filter chips:
//    Open / Dismissed"; "A server-paged keyset list (not the local mirror)";
//    "When the job completes and sync applies the tombstone, the FK cascade
//    removes the pair, and the list refreshes from the server."
//  * 8A.4 hand-over: "Pass next_after back verbatim as after with the same
//    status (a cursor is only meaningful for the status that issued it;
//    restart from no cursor when the Open/Dismissed chip changes)." Order:
//    band exact -> strong -> possible, then score descending, then uuids.
//  * Offline: the server is not asked (the page says it needs a connection).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/duplicates/duplicates_review.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/preview_controller.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../../helpers/fake_library_tools_api.dart';
import 'duplicates_test_support.dart';
import '../../helpers/run_once_track_sync.dart';
import '../../helpers/test_offline.dart';

void main() {
  late FakeLibraryToolsApi api;
  late RunOnceTrackSync sync;
  late TestOffline offline;
  late RecordingPreviewControls preview;
  late ProviderContainer c;
  late DuplicatesControls dup;

  /// Pages the fake server answers, by status then cursor (null = first).
  late Map<String, Map<String?, DuplicatePairPageDto>> pages;
  late DuplicateSummaryDto summary;

  setUp(() {
    api = FakeLibraryToolsApi();
    pages = {
      'open': {null: dupPage(const [])},
      'dismissed': {null: dupPage(const [])},
    };
    summary = dupSummary();
    api.onListDuplicates = (status, after, limit) async =>
        pages[status]![after] ?? (throw StateError('no page $status $after'));
    api.onDuplicateSummary = () async => summary;
    preview = RecordingPreviewControls();
  });

  Future<void> open({bool isOffline = false, bool serverDelete = true}) async {
    offline = TestOffline(isOffline);
    c = ProviderContainer(
      overrides: [
        libraryToolsApiProvider.overrideWithValue(api),
        trackSyncProvider.overrideWith(() => sync = RunOnceTrackSync()),
        offlineModeProvider.overrideWith(() => offline),
        previewControlsProvider.overrideWithValue(preview),
        libraryToolsFeatureProvider.overrideWith(
          (ref) async => AdvertisedFeature(
            LibraryToolsFeature(
              version: 1,
              serverDelete: serverDelete,
              duplicateReview: true,
            ),
            fromCache: false,
          ),
        ),
      ],
    );
    c.listen(trackSyncProvider, (_, _) {});
    c.listen(offlineModeProvider, (_, _) {});
    c.listen(libraryToolsFeatureProvider, (_, _) {});
    await c.read(trackSyncProvider.future);
    await c.read(libraryToolsFeatureProvider.future);
    dup = c.read(duplicatesControllerFactoryProvider)();
    await pumpEventQueue();
  }

  tearDown(() {
    dup.dispose();
    c.dispose();
  });

  List<String> keys() => [for (final p in dup.pairs) p.key];

  group('opening', () {
    test('loads the summary and the first Open page, in the server order',
        () async {
      summary = dupSummary(open: 3);
      pages['open']![null] = dupPage([
        dupPair('a1', 'b1'),
        dupPair('a2', 'b2', band: 'strong', score: 0.95),
        dupPair('a3', 'b3', band: 'possible', score: 0.7),
      ]);
      await open();
      expect(api.calls, containsAll(['duplicateSummary ', 'listDuplicates open null']));
      expect(dup.filter, DuplicatesFilter.open);
      expect(dup.summaryLoad, DuplicatesLoad.loaded);
      expect(dup.header!.scanLine, 'Checked 10 of 10 tracks');
      expect(dup.listLoad, DuplicatesLoad.loaded);
      expect(keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      expect([for (final p in dup.pairs) p.badge], [
        'Exact copy',
        'Very likely same recording',
        'Possibly same song',
      ]);
      expect([for (final p in dup.pairs) p.isExact], [true, false, false]);
      expect(dup.hasMore, isFalse);
    });

    test('a row compares its copies by the model rule', () async {
      pages['open']![null] = dupPage([
        dupPair(
          'a',
          'b',
          trackA: dupTrack('a', codec: 'flac', album: null),
          trackB: dupTrack('b', codec: 'mp3', album: 'Live'),
        ),
      ]);
      await open();
      final row = dup.pairs.single;
      expect(row.differing, {DuplicateField.format});
      expect(row.a.uuid, 'a');
      expect(row.b.uuid, 'b');
      expect(row.a.fields[DuplicateField.album], 'Unknown');
      expect(row.b.fields[DuplicateField.format], 'MP3');
      expect(row.a.identityLines, isNot(contains(startsWith('Album:'))));
      expect(row.b.identityLines, contains('Album: Live'));
    });

    test('a failed list is retried by refresh', () async {
      var fail = true;
      api.onListDuplicates = (status, after, limit) async {
        if (fail) throw apiError(500, 'internal', retryable: true);
        return dupPage([dupPair('a', 'b')]);
      };
      await open();
      expect(dup.listLoad, DuplicatesLoad.failed);
      expect(dup.pairs, isEmpty);
      fail = false;
      await dup.refresh();
      await pumpEventQueue();
      expect(dup.listLoad, DuplicatesLoad.loaded);
      expect(keys(), ['a|b']);
    });

    test('a failed summary leaves no header; the list still loads', () async {
      api.onDuplicateSummary = () async =>
          throw apiError(500, 'internal', retryable: true);
      pages['open']![null] = dupPage([dupPair('a', 'b')]);
      await open();
      expect(dup.summaryLoad, DuplicatesLoad.failed);
      expect(dup.header, isNull);
      expect(dup.listLoad, DuplicatesLoad.loaded);
    });
  });

  group('keyset paging', () {
    test('the next page is asked for with the cursor and the same status',
        () async {
      pages['open']![null] = dupPage([dupPair('a1', 'b1')], next: 'c1');
      pages['open']!['c1'] = dupPage([dupPair('a2', 'b2')], next: 'c2');
      pages['open']!['c2'] = dupPage([dupPair('a3', 'b3')]);
      await open();
      expect(dup.hasMore, isTrue);
      await dup.loadMore();
      await dup.loadMore();
      await pumpEventQueue();
      expect(keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      expect(api.callsOf('listDuplicates'), [
        'listDuplicates open null',
        'listDuplicates open c1',
        'listDuplicates open c2',
      ]);
      expect(dup.hasMore, isFalse);
      await dup.loadMore();
      expect(api.callsOf('listDuplicates'), hasLength(3));
    });

    test('a second loadMore while one is in flight asks only once', () async {
      pages['open']![null] = dupPage([dupPair('a1', 'b1')], next: 'c1');
      await open();
      final held = Completer<DuplicatePairPageDto>();
      api.onListDuplicates = (status, after, limit) => held.future;
      unawaited(dup.loadMore());
      unawaited(dup.loadMore());
      await pumpEventQueue();
      expect(api.callsOf('listDuplicates'), [
        'listDuplicates open null',
        'listDuplicates open c1',
      ]);
      held.complete(dupPage([dupPair('a2', 'b2')]));
      await pumpEventQueue();
      expect(keys(), ['a1|b1', 'a2|b2']);
    });
  });

  group('chips', () {
    test('a chip change starts a new listing, never with the old cursor',
        () async {
      pages['open']![null] = dupPage([dupPair('a1', 'b1')], next: 'open-c');
      pages['dismissed']![null] = dupPage(
        [dupPair('d1', 'e1', status: 'dismissed')],
        next: 'dis-c',
      );
      pages['dismissed']!['dis-c'] =
          dupPage([dupPair('d2', 'e2', status: 'dismissed')]);
      await open();
      dup.setFilter(DuplicatesFilter.dismissed);
      await pumpEventQueue();
      expect(dup.filter, DuplicatesFilter.dismissed);
      expect(keys(), ['d1|e1']);
      await dup.loadMore();
      await pumpEventQueue();
      expect(keys(), ['d1|e1', 'd2|e2']);
      expect(api.callsOf('listDuplicates'), [
        'listDuplicates open null',
        'listDuplicates dismissed null',
        'listDuplicates dismissed dis-c',
      ]);
      dup.setFilter(DuplicatesFilter.open);
      await pumpEventQueue();
      expect(keys(), ['a1|b1']);
      expect(api.callsOf('listDuplicates').last, 'listDuplicates open null');
    });

    test('a late page of the earlier chip is dropped', () async {
      pages['open']![null] = dupPage([dupPair('a1', 'b1')], next: 'open-c');
      await open();
      final late = Completer<DuplicatePairPageDto>();
      api.onListDuplicates = (status, after, limit) async =>
          status == 'open' ? late.future : dupPage([dupPair('d1', 'e1', status: 'dismissed')]);
      unawaited(dup.loadMore());
      await pumpEventQueue();
      dup.setFilter(DuplicatesFilter.dismissed);
      await pumpEventQueue();
      late.complete(dupPage([dupPair('a2', 'b2')]));
      await pumpEventQueue();
      expect(keys(), ['d1|e1']);
    });

    test('choosing the current chip again asks nothing', () async {
      await open();
      dup.setFilter(DuplicatesFilter.open);
      await pumpEventQueue();
      expect(api.callsOf('listDuplicates'), ['listDuplicates open null']);
    });
  });

  group('refresh after the tombstone sync', () {
    // U33-B-01 / 8-R1-25: a sync changes the list only where it touched it.
    test("a sync that deleted a member removes its pair, keeps the place in "
        'the list and reloads the counts', () async {
      summary = dupSummary(open: 3);
      pages['open']![null] = dupPage(
        [dupPair('a1', 'b1'), dupPair('a2', 'b2')],
        next: 'c1',
      );
      pages['open']!['c1'] = dupPage([dupPair('a3', 'b3', band: 'strong')]);
      await open();
      await dup.loadMore();
      expect(keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      // The server no longer counts the pair once b1 is deleted.
      summary = dupSummary(open: 2, total: 9);
      sync.runOnce(deleted: {'b1'});
      await pumpEventQueue();
      expect(keys(), ['a2|b2', 'a3|b3']);
      expect(dup.header!.scanLine, 'Checked 9 of 9 tracks');
      expect(api.callsOf('duplicateSummary'), hasLength(2));
      expect(api.callsOf('listDuplicates'), [
        'listDuplicates open null',
        'listDuplicates open c1',
      ]);
    });

    // Review r2 8-R2-03: deliberately changed from "asks nothing". A sync
    // that deleted nothing may still have added tracks elsewhere, so the
    // header's counts are read again; the list, its place and the cursor
    // stay (fe-b's rule for the list is unchanged).
    test('a sync that deleted nothing re-reads only the summary and keeps '
        'the list (every resume, every macOS refocus)', () async {
      pages['open']![null] = dupPage(
        [dupPair('a1', 'b1'), dupPair('a2', 'b2')],
        next: 'c1',
      );
      pages['open']!['c1'] = dupPage([dupPair('a3', 'b3', band: 'strong')]);
      await open();
      await dup.loadMore();
      final calls = api.calls.length;
      expect(dup.header!.scanLine, 'Checked 10 of 10 tracks');
      // Another device added tracks: the server counts them.
      summary = dupSummary(total: 12, exactPending: 1);
      sync.runOnce();
      await pumpEventQueue();
      expect(keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      expect(dup.hasMore, isFalse);
      expect(dup.listLoad, DuplicatesLoad.loaded);
      expect(dup.summaryLoad, DuplicatesLoad.loaded);
      expect(api.calls.sublist(calls), ['duplicateSummary ']);
      expect(dup.header!.scanLine, 'Checked 11 of 12 tracks');
    });

    test('while a sync re-reads the summary, the old header stays on show',
        () async {
      pages['open']![null] = dupPage([dupPair('a1', 'b1')]);
      await open();
      final held = Completer<DuplicateSummaryDto>();
      api.onDuplicateSummary = () => held.future;
      sync.runOnce();
      await pumpEventQueue();
      expect(api.callsOf('duplicateSummary'), hasLength(2));
      expect(dup.summaryLoad, DuplicatesLoad.loaded, reason: 'no spinner');
      expect(dup.header!.scanLine, 'Checked 10 of 10 tracks');
      held.complete(dupSummary(total: 12, exactPending: 1));
      await pumpEventQueue();
      expect(dup.header!.scanLine, 'Checked 11 of 12 tracks');
      expect(keys(), ['a1|b1']);
    });

    // In-piece review #2: a sync that finishes after the app went offline
    // asks the server nothing, so no failed read replaces the header with
    // "couldn't load".
    test('a sync finishing while offline asks nothing', () async {
      pages['open']![null] = dupPage([dupPair('a1', 'b1')]);
      await open();
      offline.set(true);
      await pumpEventQueue();
      final calls = api.calls.length;
      sync.runOnce();
      await pumpEventQueue();
      expect(api.calls, hasLength(calls));
      expect(dup.summaryLoad, isNot(DuplicatesLoad.failed));
      expect(dup.header, isNotNull);
    });

    test('a sync that deleted a track outside the listed pairs reloads only '
        'the counts', () async {
      pages['open']![null] = dupPage([dupPair('a1', 'b1')]);
      await open();
      sync.runOnce(deleted: {'zz'});
      await pumpEventQueue();
      expect(keys(), ['a1|b1']);
      expect(api.callsOf('duplicateSummary'), hasLength(2));
      expect(api.callsOf('listDuplicates'), hasLength(1));
    });
  });

  group('offline', () {
    test('asks the server nothing and says it needs a connection', () async {
      await open(isOffline: true);
      expect(api.calls, isEmpty);
      expect(dup.listLoad, DuplicatesLoad.needsConnection);
      expect(dup.summaryLoad, DuplicatesLoad.needsConnection);
    });

    test('coming back online loads', () async {
      pages['open']![null] = dupPage([dupPair('a', 'b')]);
      await open(isOffline: true);
      offline.set(false);
      await pumpEventQueue();
      expect(dup.listLoad, DuplicatesLoad.loaded);
      expect(keys(), ['a|b']);
    });
  });

  // Sign-off OPEN-M-11 (E8): the app goes offline while a read is on its way;
  // the token client withholds it and the read answers "not connected" with
  // the binding still verified. The page says it needs a connection, does
  // not repeat the read in a loop, and loads once back online.
  test('a read withheld because the app went offline: needs a connection, '
      'no repeat, loads when back online', () async {
    pages['open']![null] = dupPage([dupPair('a', 'b')]);
    var withhold = true;
    final list = api.onListDuplicates;
    api.onListDuplicates = (status, after, limit) async {
      if (withhold) {
        offline.set(true);
        throw const LibraryToolsNotConnected();
      }
      return list(status, after, limit);
    };
    await open();
    await pumpEventQueue(times: 50);
    expect(dup.listLoad, DuplicatesLoad.needsConnection);
    expect(api.callsOf('listDuplicates'), hasLength(1), reason: 'no loop');

    withhold = false;
    offline.set(false);
    await pumpEventQueue(times: 50);
    expect(dup.listLoad, DuplicatesLoad.loaded);
    expect(keys(), ['a|b']);
  });

  // U33-B-02: with the binding unverified (after a connection edge, a
  // different server, signed out) the page does not wait at the gate with a
  // spinner: it says it needs a connection at once, and Retry loads.
  group('binding unverified', () {
    test('summary and list fail fast as needing a connection; refresh '
        'after verification loads', () async {
      pages['open']![null] = dupPage([dupPair('a', 'b')]);
      api.bindingVerified = false;
      await open();
      expect(dup.summaryLoad, DuplicatesLoad.needsConnection);
      expect(dup.listLoad, DuplicatesLoad.needsConnection);
      expect(dup.pairs, isEmpty);

      api.bindingVerified = true;
      await dup.refresh();
      await pumpEventQueue();
      expect(dup.summaryLoad, DuplicatesLoad.loaded);
      expect(dup.listLoad, DuplicatesLoad.loaded);
      expect(keys(), ['a|b']);
    });

    // Review r1 RC-1 / R7: a reconnect clears the verification at once;
    // the page then loads by itself when the binding verifies, without a
    // Retry tap.
    test('loads by itself once the binding verifies', () async {
      pages['open']![null] = dupPage([dupPair('a', 'b')]);
      api.bindingVerified = false;
      await open();
      expect(dup.listLoad, DuplicatesLoad.needsConnection);
      api.bindingVerified = true;
      await pumpEventQueue();
      expect(dup.summaryLoad, DuplicatesLoad.loaded);
      expect(dup.listLoad, DuplicatesLoad.loaded);
      expect(keys(), ['a|b']);
    });

    test('a disposed page asks nothing when the binding verifies later',
        () async {
      api.bindingVerified = false;
      await open();
      final calls = api.calls.length;
      dup.dispose();
      api.bindingVerified = true;
      await pumpEventQueue();
      expect(api.calls, hasLength(calls));
    });
  });
}
