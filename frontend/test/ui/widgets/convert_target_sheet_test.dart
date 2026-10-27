import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/models/app_info.dart';
import 'package:frontend/ui/widgets/convert_target_sheet.dart';

const _targets = [
  ConversionTargetInfo(codec: 'aac', isLossless: false),
  ConversionTargetInfo(codec: 'alac', isLossless: true),
  ConversionTargetInfo(codec: 'flac', isLossless: true),
  ConversionTargetInfo(codec: 'mp3', isLossless: false),
];
const _bitratePresets = [320, 256, 192, 128];

Widget _harness(void Function(ConvertTargetChoice? choice) onResult) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            final choice = await showConvertTargetSheet(
              context,
              allowedTargets: _targets,
              bitratePresets: _bitratePresets,
            );
            onResult(choice);
          },
          child: const Text('Convert'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('picking a lossy codec then a bitrate returns both', (tester) async {
    ConvertTargetChoice? result;
    await tester.pumpWidget(_harness((c) => result = c));

    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();

    expect(find.text('AAC'), findsOneWidget);
    await tester.tap(find.text('AAC'));
    await tester.pumpAndSettle();

    // Lossy codec chosen -> bitrate step shown next.
    expect(find.text('192 kbps'), findsOneWidget);
    await tester.tap(find.text('192 kbps'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.codec, 'aac');
    expect(result!.bitrateKbps, 192);
  });

  testWidgets('picking a lossless codec skips the bitrate step', (tester) async {
    ConvertTargetChoice? result;
    await tester.pumpWidget(_harness((c) => result = c));

    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('FLAC'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.codec, 'flac');
    expect(result!.bitrateKbps, isNull);
  });

  testWidgets('dismissing the codec step returns null', (tester) async {
    ConvertTargetChoice? result = const ConvertTargetChoice(codec: 'unset', bitrateKbps: null);
    await tester.pumpWidget(_harness((c) => result = c));

    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();

    // Tap outside the sheet to dismiss it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('dismissing the bitrate step returns null (not a partial choice)', (tester) async {
    ConvertTargetChoice? result = const ConvertTargetChoice(codec: 'unset', bitrateKbps: null);
    await tester.pumpWidget(_harness((c) => result = c));

    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AAC'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('lossless targets show a "Lossless" subtitle', (tester) async {
    await tester.pumpWidget(_harness((_) {}));
    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();

    expect(find.text('Lossless'), findsNWidgets(2)); // alac + flac
  });
}
