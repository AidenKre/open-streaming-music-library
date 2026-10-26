import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/ui/widgets/convert_confirm_sheet.dart';

Widget _harness(
  void Function(bool confirmed) onResult, {
  String? sourceCodec = 'flac',
  double? sourceBitrateKbps = 900,
  String targetCodec = 'aac',
  bool targetIsLossless = false,
  int? targetBitrateKbps = 192,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            final confirmed = await showConvertConfirmSheet(
              context,
              sourceCodec: sourceCodec,
              sourceBitrateKbps: sourceBitrateKbps,
              targetCodec: targetCodec,
              targetIsLossless: targetIsLossless,
              targetBitrateKbps: targetBitrateKbps,
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

  group('format-matrix warning text', () {
    Future<void> open(WidgetTester tester, Widget harness) async {
      await tester.pumpWidget(harness);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('lossless -> lossy: strong irreversible quality-loss warning',
        (tester) async {
      await open(tester, _harness((_) {}));

      expect(find.text('Permanent quality loss'), findsOneWidget);
      expect(find.textContaining('lossless FLAC original to lossy AAC'),
          findsOneWidget);
      expect(find.textContaining('never be recovered'), findsOneWidget);
    });

    testWidgets('lossy -> lossless: no quality gained, much larger',
        (tester) async {
      await open(
        tester,
        _harness(
          (_) {},
          sourceCodec: 'mp3',
          sourceBitrateKbps: 320,
          targetCodec: 'flac',
          targetIsLossless: true,
          targetBitrateKbps: null,
        ),
      );

      expect(find.text('Convert to FLAC?'), findsOneWidget);
      expect(find.text('No quality is gained'), findsOneWidget);
      expect(find.textContaining('much larger'), findsOneWidget);
      expect(find.text('Permanent quality loss'), findsNothing);
    });

    testWidgets('lossy same codec at >= current bitrate: pointless',
        (tester) async {
      await open(
        tester,
        _harness(
          (_) {},
          sourceCodec: 'aac',
          sourceBitrateKbps: 255.6, // rounds to 256
          targetBitrateKbps: 256,
        ),
      );

      expect(find.text('Pointless conversion'), findsOneWidget);
      expect(find.textContaining('gains no quality'), findsOneWidget);
    });

    testWidgets('lossy same codec at a lower bitrate: generation loss',
        (tester) async {
      await open(
        tester,
        _harness((_) {}, sourceCodec: 'aac', sourceBitrateKbps: 320),
      );

      expect(find.text('Additional quality loss'), findsOneWidget);
      expect(find.textContaining('generation loss'), findsOneWidget);
    });

    testWidgets('lossy -> different lossy codec: generation loss',
        (tester) async {
      await open(
        tester,
        _harness(
          (_) {},
          sourceCodec: 'opus',
          sourceBitrateKbps: 160,
          targetCodec: 'mp3',
          targetBitrateKbps: 320,
        ),
      );

      expect(find.text('Additional quality loss'), findsOneWidget);
      expect(find.textContaining('lossy OPUS to lossy MP3'), findsOneWidget);
    });

    testWidgets('lossless -> other lossless: neutral, still checkbox-gated',
        (tester) async {
      await open(
        tester,
        _harness(
          (_) {},
          sourceCodec: 'pcm_s16le',
          targetCodec: 'flac',
          targetIsLossless: true,
          targetBitrateKbps: null,
        ),
      );

      expect(find.text('Lossless to lossless'), findsOneWidget);
      expect(find.textContaining('No audio quality is lost'), findsOneWidget);
      final confirm = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(confirm.onPressed, isNull, reason: 'checkbox gates every convert');
    });
  });

  group('conversionWarning (pure)', () {
    ConversionWarning warn({
      required String? source,
      double? sourceBitrate,
      String target = 'aac',
      bool lossless = false,
      int? targetBitrate = 192,
    }) => conversionWarning(
      sourceCodec: source,
      sourceBitrateKbps: sourceBitrate,
      targetCodec: target,
      targetIsLossless: lossless,
      targetBitrateKbps: lossless ? null : targetBitrate,
    );

    test('unknown / null source codec -> lossy target: cautious + severe', () {
      for (final source in [null, 'weirdcodec']) {
        final w = warn(source: source);
        expect(w.title, 'This replaces the original file');
        expect(w.body, contains('may permanently lose audio quality'));
        expect(w.severe, isTrue);
      }
    });

    test('unknown / null source codec -> lossless target: neutral', () {
      for (final source in [null, 'weirdcodec']) {
        final w = warn(source: source, target: 'flac', lossless: true);
        expect(w.title, 'This replaces the original file');
        expect(w.body, isNot(contains('lose audio quality')));
        expect(w.body, contains('cannot be restored'));
        expect(w.severe, isFalse);
      }
    });

    test('same lossy codec, unknown source bitrate: no "lower bitrate" claim',
        () {
      final w = warn(source: 'aac', sourceBitrate: null, targetBitrate: 320);
      expect(w.title, 'Additional quality loss');
      expect(w.body, isNot(contains('lower bitrate')));
      expect(w.body, isNot(contains('shrinks')));
      expect(w.body, contains('generation loss'));
      expect(w.severe, isTrue);
    });

    test('same lossy codec, known higher source bitrate: "lower bitrate"', () {
      final w = warn(source: 'aac', sourceBitrate: 320, targetBitrate: 128);
      expect(w.body, contains('at a lower bitrate shrinks the file'));
    });

    test('wav and pcm_* sources are lossless', () {
      for (final source in ['wav', 'WAV', 'pcm_s16le', 'pcm_s24le']) {
        expect(warn(source: source).title, 'Permanent quality loss',
            reason: '$source -> lossy');
        expect(
          warn(source: source, target: 'flac', lossless: true).title,
          'Lossless to lossless',
          reason: '$source -> lossless',
        );
      }
    });
  });
}
