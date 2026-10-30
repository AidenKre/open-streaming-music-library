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

  testWidgets('SearchCappedHint names the cap', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SearchCappedHint(cap: 100))),
    );
    expect(
      find.text(
        'Showing the first 100 matches — refine your search to narrow them '
        'down.',
      ),
      findsOneWidget,
    );
  });
}
