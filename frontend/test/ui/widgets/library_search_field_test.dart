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

  testWidgets('autofocus focuses the field; without it, it stays '
      'unfocused', (tester) async {
    bool hasFocus() => tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode
        .hasFocus;
    await tester.pumpWidget(harness(autofocus: true));
    await tester.pump();
    expect(hasFocus(), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(hasFocus(), isFalse);
  });

  testWidgets('the keyboard search action reports the text', (tester) async {
    final submitted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibrarySearchField(
            hintText: 'Search',
            onChanged: (_) {},
            onSubmitted: submitted.add,
            onCleared: () {},
          ),
        ),
      ),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).textInputAction,
      TextInputAction.search,
    );
    await tester.enterText(find.byType(TextField), 'Blue');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(submitted, ['Blue']);
  });

  group('page-owned controller and focus', () {
    late TextEditingController controller;
    late List<int> cleared;

    setUp(() {
      controller = TextEditingController();
      cleared = [];
    });
    tearDown(() => controller.dispose());

    Widget field({TextEditingController? c, FocusNode? focusNode}) =>
        MaterialApp(
          home: Scaffold(
            body: LibrarySearchField(
              hintText: 'Search',
              controller: c,
              focusNode: focusNode,
              onChanged: (_) {},
              onCleared: () => cleared.add(1),
            ),
          ),
        );

    testWidgets('the clear button follows text the page sets or clears', (
      tester,
    ) async {
      await tester.pumpWidget(field(c: controller));
      expect(find.byTooltip('Clear search'), findsNothing);

      controller.text = 'abc';
      await tester.pump();
      expect(find.byTooltip('Clear search'), findsOneWidget);

      controller.clear();
      await tester.pump();
      expect(find.byTooltip('Clear search'), findsNothing);
    });

    testWidgets('the clear button empties the page\'s controller', (
      tester,
    ) async {
      await tester.pumpWidget(field(c: controller));
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(controller.text, isEmpty);
      expect(cleared, [1]);
    });

    testWidgets('dropping the page\'s controller keeps the text it showed', (
      tester,
    ) async {
      await tester.pumpWidget(field(c: controller));
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pumpWidget(field());
      expect(find.text('abc'), findsOneWidget);
      expect(find.byTooltip('Clear search'), findsOneWidget);

      // And handing over to a page controller shows its text instead.
      controller.text = 'xyz';
      await tester.pumpWidget(field(c: controller));
      expect(find.text('xyz'), findsOneWidget);
    });

    testWidgets('uses the page\'s focus node', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(field(focusNode: node));
      node.requestFocus();
      await tester.pump();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).focusNode,
        same(node),
      );
      expect(node.hasFocus, isTrue);
    });
  });

  testWidgets('an external controller keeps the text across a remount and is '
      'not disposed by the field', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Widget field({Key? key}) => MaterialApp(
      home: Scaffold(
        body: LibrarySearchField(
          key: key,
          hintText: 'Search',
          controller: controller,
          onChanged: (_) {},
          onCleared: () {},
        ),
      ),
    );

    await tester.pumpWidget(field(key: const ValueKey(1)));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    // A different key disposes the old field state and builds a new one.
    await tester.pumpWidget(field(key: const ValueKey(2)));
    expect(find.text('abc'), findsOneWidget);
    expect(find.byTooltip('Clear search'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.text = 'still usable'; // throws if the field disposed it
  });
}
