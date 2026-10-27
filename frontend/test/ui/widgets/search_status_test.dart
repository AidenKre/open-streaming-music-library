import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/widgets/search_status.dart';

void main() {
  group('noSearchResultsMessage', () {
    String msg({required bool downloadedOnly, required bool isOffline}) =>
        noSearchResultsMessage(
          noun: 'artists',
          query: 'Blue',
          downloadedOnly: downloadedOnly,
          isOffline: isOffline,
        );

    test('online, unfiltered', () {
      expect(
        msg(downloadedOnly: false, isOffline: false),
        'No artists match "Blue".',
      );
    });

    test('online, Downloaded chip on', () {
      expect(
        msg(downloadedOnly: true, isOffline: false),
        'No downloaded artists match "Blue".',
      );
    });

    test('offline adds the reconnect hint', () {
      expect(
        msg(downloadedOnly: true, isOffline: true),
        'No downloaded artists match "Blue". '
        'Reconnect to the server to search the full library.',
      );
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
