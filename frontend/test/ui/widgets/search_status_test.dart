import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/widgets/search_status.dart';

void main() {
  group('noSearchResultsMessage', () {
    String msg({required bool downloadedOnly}) => noSearchResultsMessage(
      noun: 'artists',
      query: 'Blue',
      downloadedOnly: downloadedOnly,
    );

    test('unfiltered', () {
      expect(msg(downloadedOnly: false), 'No artists match "Blue".');
    });

    test('Downloaded chip on (online or offline)', () {
      expect(msg(downloadedOnly: true), 'No downloaded artists match "Blue".');
    });
  });

  // 4A.3: the hint names the capped type (SC-19, reused by Phase 8's
  // Manage library). Was the type-less "Showing the first 100 matches —
  // refine your search to narrow them down."; changed deliberately.
  group('SearchCappedHint', () {
    for (final noun in ['artists', 'albums', 'songs', 'tracks']) {
      testWidgets('names the cap and the type: $noun', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: SearchCappedHint(cap: 100, noun: noun)),
          ),
        );
        expect(
          find.text('Showing the first 100 $noun — refine your search.'),
          findsOneWidget,
        );
      });
    }
  });

  group('SearchFailedNotice', () {
    for (final compact in [false, true]) {
      testWidgets('says the search failed and Retry calls back '
          '(compact: $compact)', (tester) async {
        var retries = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SearchFailedNotice(
                compact: compact,
                onRetry: () => retries++,
              ),
            ),
          ),
        );
        expect(find.text(searchFailedMessage), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'Retry'));
        expect(retries, 1);
      });
    }
  });
}
