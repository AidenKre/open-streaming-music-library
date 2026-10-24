import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/ui/widgets/convert_confirm_sheet.dart';

Widget _harness(void Function(bool confirmed) onResult) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            final confirmed = await showConvertConfirmSheet(
              context,
              targetCodec: 'aac',
              targetBitrateKbps: 192,
            );
            onResult(confirmed);
          },
          child: const Text('Open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('confirm button starts disabled until the checkbox is checked', (tester) async {
    await tester.pumpWidget(_harness((_) {}));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final confirmButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(confirmButton.onPressed, isNull);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    final confirmButtonAfter = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(confirmButtonAfter.onPressed, isNotNull);
  });

  testWidgets('checking the box then confirming returns true', (tester) async {
    bool? result;
    await tester.pumpWidget(_harness((c) => result = c));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('cancel returns false without requiring the checkbox', (tester) async {
    bool? result;
    await tester.pumpWidget(_harness((c) => result = c));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('dismissing without choosing returns false', (tester) async {
    bool? result;
    await tester.pumpWidget(_harness((c) => result = c));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  testWidgets('shows the target codec and bitrate in the description', (tester) async {
    await tester.pumpWidget(_harness((_) {}));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('AAC', findRichText: true), findsWidgets);
    expect(find.textContaining('192', findRichText: true), findsWidgets);
  });
}
