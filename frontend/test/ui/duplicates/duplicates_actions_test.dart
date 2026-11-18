// 8B.3 S4: "Not duplicates", Restore and Undo.
//  * Spec §6: "Not duplicates dismisses with an Undo snackbar (restore)."
//  * 8A.4 hand-over: dismiss/restore take {uuid_a, uuid_b}; idempotent 200;
//    404 pair_not_found for an unknown pair, another user's pair, or a pair
//    with a member pending deletion.
//  * Brief: the row leaves the list at once and comes back on Undo or on a
//    failure; say what the user sees when the server refuses.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../../helpers/fake_library_tools_api.dart';
import 'duplicates_test_support.dart';

void main() {
  late DupHarness h;

  setUp(() {
    h = DupHarness();
    h.pages['open']![null] = dupPage([
      dupPair('a1', 'b1'),
      dupPair('a2', 'b2'),
      dupPair('a3', 'b3', band: 'strong'),
    ]);
    h.api.onDismissPair = (a, b) async => dupStatus(a, b, 'dismissed');
    h.api.onRestorePair = (a, b) async => dupStatus(a, b, 'open');
  });

  tearDown(() => h.dispose());

  group('Not duplicates', () {
    test('the row leaves the Open list at once, before the server answers',
        () async {
      await h.open();
      final held = Completer<DuplicatePairStatusDto>();
      h.api.onDismissPair = (a, b) => held.future;
      h.dup.setAside(h.row('a2|b2'));
      expect(h.keys(), ['a1|b1', 'a3|b3']);
      await pumpEventQueue();
      expect(h.api.callsOf('dismissPair'), ['dismissPair a2,b2']);
      held.complete(dupStatus('a2', 'b2', 'dismissed'));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3']);
      expect(h.dup.message, isNull);
    });

    test('a settled dismissal refreshes the counts', () async {
      await h.open();
      h.dup.setAside(h.row('a1|b1'));
      await pumpEventQueue();
      expect(h.api.callsOf('duplicateSummary'), hasLength(2));
    });

    test('Undo restores the row in its place and asks the server to restore',
        () async {
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      h.dup.undo(row);
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      await pumpEventQueue();
      expect(h.api.calls.where((c) => c.contains('Pair ')), [
        'dismissPair a2,b2',
        'restorePair a2,b2',
      ]);
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      expect(h.dup.message, isNull);
    });

    test('Undo while the dismissal is in flight: the restore is sent after '
        'its answer', () async {
      await h.open();
      final held = Completer<DuplicatePairStatusDto>();
      h.api.onDismissPair = (a, b) => held.future;
      final row = h.row('a1|b1');
      h.dup.setAside(row);
      await pumpEventQueue();
      h.dup.undo(row);
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      await pumpEventQueue();
      expect(h.api.callsOf('restorePair'), isEmpty);
      held.complete(dupStatus('a1', 'b1', 'dismissed'));
      await pumpEventQueue();
      expect(h.api.callsOf('restorePair'), ['restorePair a1,b1']);
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    });

    test('a failed dismissal puts the row back and says nothing changed',
        () async {
      await h.open();
      h.api.onDismissPair = (a, b) async =>
          throw apiError(500, 'internal', retryable: true);
      h.dup.setAside(h.row('a2|b2'));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      expect(
        h.dup.message,
        "Couldn't mark these as not duplicates. Nothing changed.",
      );
      h.dup.clearMessage();
      expect(h.dup.message, isNull);
    });

    test('a pair the server no longer has stays gone and says so', () async {
      await h.open();
      h.api.onDismissPair = (a, b) async =>
          throw apiError(404, 'pair_not_found', retryable: false);
      h.dup.setAside(h.row('a2|b2'));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3']);
      expect(h.dup.message, 'This pair is no longer in your library.');
    });

    test('a failed Undo takes the row out again and says where it is',
        () async {
      await h.open();
      h.api.onRestorePair = (a, b) async =>
          throw apiError(500, 'internal', retryable: true);
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      h.dup.undo(row);
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3']);
      expect(h.dup.message, "Couldn't undo. The pair stays under Dismissed.");
    });

    test('Undo of a dismissal that already failed does nothing more',
        () async {
      await h.open();
      h.api.onDismissPair = (a, b) async =>
          throw apiError(500, 'internal', retryable: true);
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      h.dup.undo(row);
      await pumpEventQueue();
      expect(h.api.callsOf('restorePair'), isEmpty);
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    });

    test('a row that is no longer listed is not acted on', () async {
      await h.open();
      final stale = h.row('a2|b2');
      h.pages['open']![null] = dupPage([dupPair('a1', 'b1')]);
      await h.dup.refresh();
      await pumpEventQueue();
      h.dup.setAside(stale);
      await pumpEventQueue();
      expect(h.api.callsOf('dismissPair'), isEmpty);
    });
  });

  group('Restore (Dismissed chip)', () {
    test('restores, and Undo dismisses again', () async {
      h.pages['dismissed']![null] = dupPage([
        dupPair('d1', 'e1', status: 'dismissed'),
      ]);
      await h.open();
      h.dup.setFilter(DuplicatesFilter.dismissed);
      await pumpEventQueue();
      final row = h.row('d1|e1');
      h.dup.setAside(row);
      expect(h.keys(), isEmpty);
      await pumpEventQueue();
      h.dup.undo(row);
      expect(h.keys(), ['d1|e1']);
      await pumpEventQueue();
      expect(h.api.calls.where((c) => c.contains('Pair ')), [
        'restorePair d1,e1',
        'dismissPair d1,e1',
      ]);
    });

    test('a failed restore puts the row back and says nothing changed',
        () async {
      h.pages['dismissed']![null] = dupPage([
        dupPair('d1', 'e1', status: 'dismissed'),
      ]);
      h.api.onRestorePair = (a, b) async =>
          throw apiError(500, 'internal', retryable: true);
      await h.open();
      h.dup.setFilter(DuplicatesFilter.dismissed);
      await pumpEventQueue();
      h.dup.setAside(h.row('d1|e1'));
      await pumpEventQueue();
      expect(h.keys(), ['d1|e1']);
      expect(h.dup.message, "Couldn't restore this pair. Nothing changed.");
    });
  });

  // 8-R1-20: a list reload racing an Undo must not lose the restored pair.
  group('Undo racing a reload', () {
    test('a reload that lands while the restore is in flight keeps the '
        'pair once the restore succeeds', () async {
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      final restore = Completer<DuplicatePairStatusDto>();
      h.api.onRestorePair = (a, b) => restore.future;
      h.dup.undo(row);
      await pumpEventQueue();
      // The server still holds the pair as dismissed: the reload omits it.
      h.pages['open']![null] = dupPage([
        dupPair('a1', 'b1'),
        dupPair('a3', 'b3', band: 'strong'),
      ]);
      await h.dup.refresh();
      await pumpEventQueue();
      restore.complete(dupStatus('a2', 'b2', 'open'));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      expect(h.dup.message, isNull);
    });

    test('a reload asked while the restore was in flight and answered after '
        'it succeeded keeps the pair', () async {
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      final restore = Completer<DuplicatePairStatusDto>();
      h.api.onRestorePair = (a, b) => restore.future;
      h.dup.undo(row);
      await pumpEventQueue();
      final page = Completer<DuplicatePairPageDto>();
      h.api.onListDuplicates = (status, after, limit) => page.future;
      final reload = h.dup.refresh();
      await pumpEventQueue();
      restore.complete(dupStatus('a2', 'b2', 'open'));
      await pumpEventQueue();
      // Answered from before the restore committed.
      page.complete(dupPage([
        dupPair('a1', 'b1'),
        dupPair('a3', 'b3', band: 'strong'),
      ]));
      await reload;
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    });

    // Review r1 RC-2: a page answered after the server restored the pair
    // shows the server's row (fresh revisions), not the stale undone one.
    test('a reload that lists the restored pair shows the server row',
        () async {
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      final restore = Completer<DuplicatePairStatusDto>();
      h.api.onRestorePair = (a, b) => restore.future;
      h.dup.undo(row);
      await pumpEventQueue();
      h.pages['open']![null] = dupPage([
        dupPair('a1', 'b1'),
        dupPair('a2', 'b2', trackB: dupTrack('b2', revision: 9)),
        dupPair('a3', 'b3', band: 'strong'),
      ]);
      await h.dup.refresh();
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
      expect(h.row('a2|b2').pair.trackB.revision, 9);
      restore.complete(dupStatus('a2', 'b2', 'open'));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a2|b2', 'a3|b3']);
    });

    test('a failed restore after a reload leaves the pair out and says so',
        () async {
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      final restore = Completer<DuplicatePairStatusDto>();
      h.api.onRestorePair = (a, b) => restore.future;
      h.dup.undo(row);
      await pumpEventQueue();
      h.pages['open']![null] = dupPage([
        dupPair('a1', 'b1'),
        dupPair('a3', 'b3', band: 'strong'),
      ]);
      await h.dup.refresh();
      await pumpEventQueue();
      restore.completeError(apiError(503, 'unavailable', retryable: true));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3']);
      expect(h.dup.message, "Couldn't undo. The pair stays under Dismissed.");
    });

    // Review r1 R1: a failed Undo never brings the pair back on a later
    // page load (Load more, Retry, back online).
    test('after a failed restore, a later page load does not bring the '
        'pair back', () async {
      h.pages['open']![null] = dupPage(
        [dupPair('a1', 'b1'), dupPair('a2', 'b2')],
        next: 'c1',
      );
      h.pages['open']!['c1'] = dupPage([dupPair('a3', 'b3', band: 'strong')]);
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      h.api.onRestorePair =
          (a, b) async => throw apiError(503, 'unavailable', retryable: true);
      h.dup.undo(row);
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1']);
      await h.dup.loadMore();
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3']);
    });
  });

  // Review r1 R3: a pair is never listed twice, and an Undo of a pair that
  // sorts past the loaded pages does not jump it to the end of the list.
  group('no pair twice', () {
    test('an Undo after a reload to page 1 (the pair now sorts past it) '
        'then Load more: listed once, in order', () async {
      h.pages['open']![null] = dupPage(
        [dupPair('a1', 'b1'), dupPair('a3', 'b3', band: 'strong')],
      );
      await h.open();
      final row = h.row('a3|b3');
      h.dup.setAside(row);
      await pumpEventQueue();
      // Reload: the first page now ends before the pair.
      h.pages['open']![null] = dupPage([dupPair('a1', 'b1')], next: 'c1');
      h.pages['open']!['c1'] = dupPage([
        dupPair('a3', 'b3', band: 'strong'),
        dupPair('a4', 'b4', band: 'possible', score: 0.6),
      ]);
      await h.dup.refresh();
      await pumpEventQueue();
      h.dup.undo(row);
      await pumpEventQueue();
      await h.dup.loadMore();
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3', 'a4|b4']);
    });
  });

  // Review r1 R4: a pair whose member a sync deleted never comes back from
  // a late restore answer or from a page answered before the deletion.
  group('a deletion during an Undo or a page load', () {
    test('a restore that succeeds after the sync deleted a member does not '
        'bring the pair back', () async {
      await h.open();
      final row = h.row('a2|b2');
      h.dup.setAside(row);
      await pumpEventQueue();
      final restore = Completer<DuplicatePairStatusDto>();
      h.api.onRestorePair = (a, b) => restore.future;
      h.dup.undo(row);
      await pumpEventQueue();
      h.sync.runOnce(deleted: {'b2'});
      await pumpEventQueue();
      restore.complete(dupStatus('a2', 'b2', 'open'));
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3']);
    });

    test('a page answered before the deletion does not list its pair',
        () async {
      h.pages['open']![null] = dupPage([dupPair('a1', 'b1')], next: 'c1');
      await h.open();
      final page = Completer<DuplicatePairPageDto>();
      h.api.onListDuplicates = (status, after, limit) => page.future;
      final more = h.dup.loadMore();
      await pumpEventQueue();
      h.sync.runOnce(deleted: {'b2'});
      await pumpEventQueue();
      page.complete(dupPage([
        dupPair('a2', 'b2'),
        dupPair('a3', 'b3', band: 'strong'),
      ]));
      await more;
      await pumpEventQueue();
      expect(h.keys(), ['a1|b1', 'a3|b3']);
    });
  });
}
