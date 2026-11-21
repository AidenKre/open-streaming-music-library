// 8B.3 S7: the Possible duplicates page renders DuplicatesControls and
// forwards every input to it (SC-26).
//  * Spec §6 Header / List / Row actions / Rules (quoted in the controller
//    and model tests). Exit proof: the header's wording for each coverage
//    state; the order of the bands; Undo restores; Delete is hidden when the
//    switch is off.
//  * Brief: a null field is unknown, shown as unknown, never highlighted;
//    "Delete this copy" opens 8B.1c's single-track review naming the copy;
//    no bulk action, no suggested winner; leaving stops the preview from the
//    pop event.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/duplicates/duplicates_header.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/duplicates/duplicates_page.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/deletion_review_sheet.dart';
import 'package:frontend/ui/widgets/list_status_message.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../../helpers/fake_library_tools_api.dart';
import '../browse_harness.dart' show teardownTree;
import '../manage_library/fake_manage_library_controls.dart';
import 'fake_duplicates_controls.dart';

const _tool =
    'Fingerprint tool not installed on the server — only exact copies are '
    'found';

void main() {
  late FakeDuplicatesControls fake;

  setUp(() => fake = FakeDuplicatesControls());

  Future<void> open(WidgetTester tester, {Size size = const Size(900, 1600)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          duplicatesControllerFactoryProvider.overrideWithValue(() => fake),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const DuplicatesPage()),
                ),
                child: const Text('open duplicates'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open duplicates'));
    await tester.pumpAndSettle();
  }

  Finder header() => find.byKey(const Key('duplicates-header'));
  Finder inHeader(String text) =>
      find.descendant(of: header(), matching: find.text(text));
  Finder row(String key) => find.byKey(Key('pair-$key'));

  group('header wording per coverage state', () {
    testWidgets('full coverage with the tool and nothing open: No duplicates',
        (tester) async {
      fake.header = duplicatesHeader(dupSummary(total: 12));
      await open(tester);
      expect(inHeader('No duplicates'), findsOne);
      expect(inHeader('Checked 12 of 12 tracks'), findsOne);
      expect(find.text(_tool), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a scan in progress shows its progress and no claim',
        (tester) async {
      fake.header = duplicatesHeader(dupSummary(total: 50000, exactPending: 37660));
      await open(tester);
      expect(inHeader('Checked 12,340 of 50,000 tracks'), findsOne);
      expect(find.textContaining('No duplicates'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('no fingerprint tool: the spec sentence, exact-only wording',
        (tester) async {
      fake.header = duplicatesHeader(dupSummary(fingerprinter: null));
      await open(tester);
      expect(inHeader(_tool), findsOne);
      expect(inHeader('No exact copies found'), findsOne);
      expect(find.textContaining('No duplicates'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('notes are shown', (tester) async {
      fake.header = const DuplicatesHeader(
        scanLine: 'Checked 1 of 2 tracks',
        notes: ["3 tracks couldn't be checked for exact copies"],
      );
      await open(tester);
      expect(inHeader("3 tracks couldn't be checked for exact copies"), findsOne);
      await teardownTree(tester);
    });

    testWidgets('loading, offline and a failed summary say so; Retry refreshes',
        (tester) async {
      await open(tester);
      // An indeterminate spinner never settles: switch to loading after open.
      fake.summaryLoad = DuplicatesLoad.loading;
      fake.notify();
      await tester.pump();
      expect(
        find.descendant(of: header(), matching: find.byType(CircularProgressIndicator)),
        findsOne,
      );
      fake.summaryLoad = DuplicatesLoad.needsConnection;
      fake.notify();
      await tester.pump();
      expect(inHeader('Possible duplicates needs a connection'), findsOne);
      fake.summaryLoad = DuplicatesLoad.failed;
      fake.notify();
      await tester.pump();
      expect(inHeader("Couldn't load the scan status"), findsOne);
      expect(find.textContaining('No duplicates'), findsNothing);
      await tester.tap(find.byKey(const Key('retry-summary')));
      expect(fake.calls, contains('refresh'));
      await teardownTree(tester);
    });
  });

  group('the list', () {
    final exact = pairView(dupPair('a1', 'b1'));
    final strong = pairView(dupPair('a2', 'b2', band: 'strong', score: 0.93));
    final possible = pairView(dupPair('a3', 'b3', band: 'possible', score: 0.71));

    testWidgets('rows follow the controller order: exact, strong, possible, '
        'each with its badge', (tester) async {
      fake.pairs = [exact, strong, possible];
      await open(tester);
      final ys = [
        for (final k in ['a1|b1', 'a2|b2', 'a3|b3']) tester.getTopLeft(row(k)).dy,
      ];
      expect(ys[0], lessThan(ys[1]));
      expect(ys[1], lessThan(ys[2]));
      expect(find.descendant(of: row('a1|b1'), matching: find.text('Exact copy')), findsOne);
      expect(
        find.descendant(of: row('a2|b2'), matching: find.text('Very likely same recording')),
        findsOne,
      );
      expect(
        find.descendant(of: row('a3|b3'), matching: find.text('Possibly same song')),
        findsOne,
      );
      expect(find.text('Possible duplicates'), findsOne); // the title
      await teardownTree(tester);
    });

    testWidgets('no badge calls a pair a duplicate as a fact', (tester) async {
      fake.pairs = [exact, strong, possible];
      await open(tester);
      // The row's own action is "Not duplicates"; nothing else in a row may
      // call the pair a duplicate.
      final claims = find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.data ?? '').toLowerCase().contains('duplicate') &&
            w.data != 'Not duplicates',
      );
      for (final k in ['a1|b1', 'a2|b2', 'a3|b3']) {
        expect(find.descendant(of: row(k), matching: claims), findsNothing);
      }
      await teardownTree(tester);
    });

    testWidgets('differing fields are highlighted; unknown reads Unknown and '
        'is never highlighted', (tester) async {
      fake.pairs = [
        pairView(
          dupPair(
            'a',
            'b',
            trackA: dupTrack('a', codec: 'flac', album: null, bitrateKbps: 900),
            trackB: dupTrack('b', codec: 'mp3', album: 'Live', bitrateKbps: 320),
          ),
        ),
      ];
      await open(tester);
      expect(find.byKey(const Key('differs-a-format')), findsOne);
      expect(find.byKey(const Key('differs-b-format')), findsOne);
      expect(find.byKey(const Key('differs-a-bitrate')), findsOne);
      expect(find.byKey(const Key('differs-a-album')), findsNothing);
      expect(find.byKey(const Key('differs-b-album')), findsNothing);
      expect(find.byKey(const Key('differs-a-duration')), findsNothing);
      expect(
        find.descendant(of: row('a|b'), matching: find.textContaining('Unknown')),
        findsOne,
      );
      await teardownTree(tester);
    });

    // The same words as the deletion screens for a track with no
    // title; an empty title is no title.
    testWidgets('a copy with no title or an empty title reads Unknown track',
        (tester) async {
      fake.pairs = [
        pairView(
          dupPair(
            'a',
            'b',
            trackA: dupTrack('a', title: null),
            trackB: dupTrack('b', title: ''),
          ),
        ),
      ];
      await open(tester);
      expect(
        find.descendant(of: row('a|b'), matching: find.text('Unknown track')),
        findsNWidgets(2),
      );
      expect(find.text('Unknown title'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a copy whose file is missing on the server says so',
        (tester) async {
      fake.pairs = [
        pairView(dupPair('a', 'b', trackB: dupTrack('b', masterPresent: false))),
      ];
      await open(tester);
      expect(find.text('File missing on the server'), findsOne);
      expect(find.text('File status unknown'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a copy whose file the server could not check says the status '
        'is unknown, never missing (sign-off OPEN-A-11)', (tester) async {
      fake.pairs = [
        pairView(dupPair('a', 'b', trackB: dupTrack('b', masterPresent: null))),
      ];
      await open(tester);
      expect(
        find.descendant(of: row('a|b'), matching: find.text('File status unknown')),
        findsOne,
      );
      expect(find.text('File missing on the server'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a copy whose file is present shows no file status line',
        (tester) async {
      fake.pairs = [pairView(dupPair('a', 'b'))];
      await open(tester);
      expect(find.text('File missing on the server'), findsNothing);
      expect(find.text('File status unknown'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('chips forward the filter; Load more forwards', (tester) async {
      fake.pairs = [exact];
      fake.hasMore = true;
      await open(tester);
      await tester.tap(find.byKey(const Key('chip-dismissed')));
      await tester.tap(find.byKey(const Key('chip-open')));
      await tester.ensureVisible(find.byKey(const Key('load-more')));
      await tester.tap(find.byKey(const Key('load-more')));
      expect(fake.calls, containsAllInOrder([
        'setFilter dismissed',
        'setFilter open',
        'loadMore',
      ]));
      await teardownTree(tester);
    });

    testWidgets('empty lists never claim No duplicates', (tester) async {
      await open(tester);
      expect(find.text('No pairs to review'), findsOne);
      expect(find.textContaining('No duplicates'), findsNothing);
      fake.filter = DuplicatesFilter.dismissed;
      fake.notify();
      await tester.pump();
      expect(find.text('No dismissed pairs'), findsOne);
      await teardownTree(tester);
    });

    testWidgets('a failed list says so and Retry refreshes', (tester) async {
      fake.listLoad = DuplicatesLoad.failed;
      await open(tester);
      expect(find.text("Couldn't load the pairs"), findsOne);
      await tester.tap(find.byKey(const Key('retry-list')));
      expect(fake.calls, contains('refresh'));
      await teardownTree(tester);
    });

    testWidgets('a failed action shows its message, which can be closed',
        (tester) async {
      fake.message = "Couldn't mark these as not duplicates. Nothing changed.";
      await open(tester);
      expect(find.text(fake.message!), findsOne);
      await tester.tap(find.byKey(const Key('close-message')));
      expect(fake.calls, contains('clearMessage'));
      await teardownTree(tester);
    });

    testWidgets('there is no bulk action and no suggested copy to keep',
        (tester) async {
      fake.pairs = [exact, strong];
      fake.canDeleteCopy = true;
      await open(tester);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.textContaining(RegExp('all', caseSensitive: false)), findsNothing);
      expect(find.textContaining(RegExp('keep|recommended|best', caseSensitive: false)),
          findsNothing);
      await teardownTree(tester);
    });
  });

  group('Not duplicates and Undo', () {
    final exact = pairView(dupPair('a1', 'b1'));

    testWidgets('Not duplicates forwards the row and offers Undo, which '
        'forwards the same row', (tester) async {
      fake.pairs = [exact];
      await open(tester);
      await tester.tap(find.byKey(const Key('aside-a1|b1')));
      await tester.pump();
      expect(fake.asideRows.single, same(exact));
      expect(find.text('Marked as not duplicates'), findsOne);
      await tester.pump(const Duration(milliseconds: 750));
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pump();
      expect(fake.undoRows.single, same(exact));
      await tester.pumpAndSettle();
      await teardownTree(tester);
    });

    testWidgets('on the Dismissed chip the action is Restore', (tester) async {
      final dismissed = pairView(dupPair('d', 'e', status: 'dismissed'));
      fake.filter = DuplicatesFilter.dismissed;
      fake.pairs = [dismissed];
      await open(tester);
      expect(find.text('Not duplicates'), findsNothing);
      await tester.tap(find.byKey(const Key('aside-d|e')));
      await tester.pump();
      expect(fake.asideRows.single, same(dismissed));
      expect(find.text('Restored to Open'), findsOne);
      await tester.pump(const Duration(milliseconds: 750));
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await tester.pump();
      expect(fake.undoRows.single, same(dismissed));
      await tester.pumpAndSettle();
      await teardownTree(tester);
    });
  });

  group('Play', () {
    final exact = pairView(dupPair('a1', 'b1'));

    testWidgets('each copy plays through the controller', (tester) async {
      fake.pairs = [exact];
      await open(tester);
      await tester.tap(find.byKey(const Key('play-b1')));
      await tester.tap(find.byKey(const Key('play-a1')));
      expect(fake.calls, containsAllInOrder(['togglePlay b1', 'togglePlay a1']));
      await teardownTree(tester);
    });

    testWidgets('disabled when the controller says it cannot play',
        (tester) async {
      fake.pairs = [exact];
      fake.canPlay = false;
      await open(tester);
      final button = tester.widget<IconButton>(find.byKey(const Key('play-a1')));
      expect(button.onPressed, isNull);
      await teardownTree(tester);
    });

    testWidgets('the playing copy shows Pause, and a preview message shows',
        (tester) async {
      fake.pairs = [exact];
      fake.previewingUuid = 'a1';
      fake.previewStatus = PreviewStatus.playing;
      fake.previewMessage = "Preview couldn't play";
      await open(tester);
      expect(
        find.descendant(of: find.byKey(const Key('play-a1')), matching: find.byIcon(Icons.pause)),
        findsOne,
      );
      expect(
        find.descendant(of: find.byKey(const Key('play-b1')), matching: find.byIcon(Icons.play_arrow)),
        findsOne,
      );
      expect(find.text("Preview couldn't play"), findsOne);
      await teardownTree(tester);
    });

    testWidgets('leaving the page tells the controller once, then disposes it',
        (tester) async {
      fake.pairs = [exact];
      await open(tester);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(fake.calls.where((c) => c == 'leave'), hasLength(1));
      expect(fake.disposed, isTrue);
      expect(fake.calls.indexOf('leave'), lessThan(fake.calls.indexOf('dispose')));
      await teardownTree(tester);
    });
  });

  group('Delete this copy', () {
    final pair = pairView(
      dupPair(
        'a1',
        'b1',
        trackA: dupTrack('a1', codec: 'flac'),
        trackB: dupTrack('b1', codec: 'mp3', bitrateKbps: 320),
      ),
    );

    testWidgets('hidden when the switch is off', (tester) async {
      fake.pairs = [pair];
      fake.canDeleteCopy = false;
      await open(tester);
      expect(find.byKey(const Key('delete-a1')), findsNothing);
      expect(find.byKey(const Key('delete-b1')), findsNothing);
      expect(find.text('Delete this copy'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('opens the single-track review for the tapped copy, naming '
        'it, and ends it when the sheet closes', (tester) async {
      fake.pairs = [pair];
      fake.canDeleteCopy = true;
      final review = FakeDeletionReviewControls()
        ..stage = ReviewStage.ready
        ..preview = DeletionPreview.fromServer(
          [const DeletionCandidate('b1', 1)],
          DeletionPreviewDto.fromJson({
            'targets': [previewTargetJson('b1', 1)],
          }),
        );
      addTearDown(review.dispose);
      fake.reviewToStart = review;
      await open(tester);
      expect(find.byKey(const Key('delete-a1')), findsOne);
      await tester.tap(find.byKey(const Key('delete-b1')));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('startDeleteCopy a1|b1 b1'));
      expect(find.byType(DeletionReviewSheet), findsOne);
      final sheet = find.byType(DeletionReviewSheet);
      expect(find.descendant(of: sheet, matching: find.text('Format: MP3')), findsOne);
      expect(find.descendant(of: sheet, matching: find.text('Bitrate: 320 kbps')), findsOne);
      expect(find.descendant(of: sheet, matching: find.text('Format: FLAC')), findsNothing);
      expect(fake.calls, isNot(contains('endDeleteCopy')));
      await tester.tap(find.byKey(const Key('close-review')));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('endDeleteCopy'));
      await teardownTree(tester);
    });

    testWidgets('nothing opens when the controller refuses to start',
        (tester) async {
      fake.pairs = [pair];
      fake.canDeleteCopy = true;
      await open(tester);
      await tester.tap(find.byKey(const Key('delete-a1')));
      await tester.pumpAndSettle();
      expect(find.byType(DeletionReviewSheet), findsNothing);
      await teardownTree(tester);
    });
  });

  // Refactor APP-DUP (SP-UX-01(b), guide B.14): the page's "Couldn't load"
  // notices are the shared LoadFailureNotice (its look: spacing and text
  // style), with the page's own words and Retry.
  group('the shared load-failure notice', () {
    Finder notice(String text) => find.ancestor(
      of: find.text(text),
      matching: find.byType(LoadFailureNotice),
    );

    testWidgets('a failed summary: in the header, Retry refreshes',
        (tester) async {
      fake.summaryLoad = DuplicatesLoad.failed;
      await open(tester);
      expect(notice("Couldn't load the scan status"), findsOne);
      expect(
        find.descendant(of: header(), matching: find.byType(LoadFailureNotice)),
        findsOne,
      );
      await tester.tap(find.descendant(
        of: notice("Couldn't load the scan status"),
        matching: find.text('Retry'),
      ));
      expect(fake.calls, contains('refresh'));
      await teardownTree(tester);
    });

    testWidgets('a failed first page: full size in place of the list',
        (tester) async {
      fake.listLoad = DuplicatesLoad.failed;
      await open(tester);
      expect(notice("Couldn't load the pairs"), findsOne);
      expect(tester.widget<LoadFailureNotice>(find.byType(LoadFailureNotice)).compact,
          isFalse);
      await tester.tap(find.descendant(
        of: notice("Couldn't load the pairs"),
        matching: find.text('Retry'),
      ));
      expect(fake.calls, contains('refresh'));
      await teardownTree(tester);
    });

    testWidgets('a failed later page with rows kept: compact', (tester) async {
      fake.pairs = [pairView(dupPair('a1', 'b1'))];
      fake.listLoad = DuplicatesLoad.failed;
      await open(tester);
      expect(notice("Couldn't load the pairs"), findsOne);
      expect(tester.widget<LoadFailureNotice>(find.byType(LoadFailureNotice)).compact,
          isTrue);
      await teardownTree(tester);
    });
  });

  // U33-B-02: "needs a connection" (offline, or the binding unverified)
  // offers one Retry, which refreshes, and never spins.
  testWidgets('needs a connection offers Retry, which refreshes',
      (tester) async {
    fake.summaryLoad = DuplicatesLoad.needsConnection;
    fake.listLoad = DuplicatesLoad.needsConnection;
    await open(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('No pairs'), findsNothing);
    expect(find.byKey(const Key('retry-connection')), findsOne);
    await tester.tap(find.byKey(const Key('retry-connection')));
    await tester.pump();
    expect(fake.calls, contains('refresh'));
    await teardownTree(tester);
  });

  // Refactor APP-DUP (section 6 #11): the page says the controller's reason
  // at both sites, the header and the list.
  testWidgets('needs a connection says the controller\'s reason at both sites',
      (tester) async {
    fake.unreachableText = 'Reason words.';
    fake.summaryLoad = DuplicatesLoad.needsConnection;
    fake.listLoad = DuplicatesLoad.loaded;
    await open(tester);
    expect(inHeader('Reason words.'), findsOne);
    fake.summaryLoad = DuplicatesLoad.loaded;
    fake.listLoad = DuplicatesLoad.needsConnection;
    fake.notify();
    await tester.pump();
    expect(find.text('Reason words.'), findsOne);
    expect(inHeader('Reason words.'), findsNothing);
    expect(find.text('Possible duplicates needs a connection'), findsNothing);
    await teardownTree(tester);
  });

  // Where Retry cannot help (a different server, signed out), the
  // reason shows without a Retry, in the header and in the list.
  testWidgets('a reason Retry cannot help: the reason, no Retry, at both sites',
      (tester) async {
    fake.unreachableText = 'Reason words.';
    fake.connectionRetryHelps = false;
    fake.summaryLoad = DuplicatesLoad.needsConnection;
    fake.listLoad = DuplicatesLoad.loaded;
    await open(tester);
    expect(inHeader('Reason words.'), findsOne);
    expect(find.byKey(const Key('retry-connection')), findsNothing);

    fake.summaryLoad = DuplicatesLoad.loaded;
    fake.listLoad = DuplicatesLoad.needsConnection;
    fake.notify();
    await tester.pump();
    expect(find.text('Reason words.'), findsOne);
    expect(find.byKey(const Key('retry-connection')), findsNothing);

    fake.summaryLoad = DuplicatesLoad.needsConnection;
    fake.notify();
    await tester.pump();
    expect(find.text('Reason words.'), findsNWidgets(2));
    expect(find.byKey(const Key('retry-connection')), findsNothing);
    await teardownTree(tester);
  });

  // Review r1 R6: an empty loaded page with more pages to come is not "no
  // pairs" (the rest are unknown until loaded).
  testWidgets('no rows but more pages: no empty claim, Load more offered',
      (tester) async {
    fake.listLoad = DuplicatesLoad.loaded;
    fake.hasMore = true;
    await open(tester);
    expect(find.text('No pairs to review'), findsNothing);
    expect(find.byKey(const Key('load-more')), findsOne);
    await teardownTree(tester);
  });

  testWidgets('a narrow screen with large text renders', (tester) async {
    fake.pairs = [
      pairView(dupPair('a1', 'b1', trackA: dupTrack('a1', title: 'A very long title ' * 4))),
    ];
    fake.canDeleteCopy = true;
    fake.header = duplicatesHeader(dupSummary(fingerprinter: null));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, size: const Size(320, 640));
    expect(tester.takeException(), isNull);
    await teardownTree(tester);
  });
}
