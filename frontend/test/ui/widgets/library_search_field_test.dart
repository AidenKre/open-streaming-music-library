import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/widgets/library_search_field.dart';

void main() {
  late List<String> changes;
  late int clears;

  setUp(() {
    changes = [];
    clears = 0;
  });

  Widget harness({bool autofocus = false}) => MaterialApp(
    home: Scaffold(
      body: LibrarySearchField(
        hintText: 'Search artists',
        autofocus: autofocus,
        onChanged: changes.add,
        onCleared: () => clears++,
      ),
    ),
  );

  testWidgets('shows the hint and a search icon', (tester) async {
    await tester.pumpWidget(harness());
    expect(find.text('Search artists'), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });

  testWidgets('typing reports each change', (tester) async {
    await tester.pumpWidget(harness());
    await tester.enterText(find.byType(TextField), 'Blu');
    expect(changes, ['Blu']);
  });

  testWidgets('clear button appears only with text and empties the field', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    expect(find.byIcon(Icons.clear), findsNothing);

    await tester.enterText(find.byType(TextField), 'Blue');
    await tester.pump();
    expect(find.byIcon(Icons.clear), findsOneWidget);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(clears, 1);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.byIcon(Icons.clear), findsNothing);
  });

  testWidgets('passes autofocus through', (tester) async {
    await tester.pumpWidget(harness(autofocus: true));
    expect(tester.widget<TextField>(find.byType(TextField)).autofocus, isTrue);
  });
}
