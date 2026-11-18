// Phase 9 §6 (9C.2): the recap's PNG comes from a fixed export layout,
// rendered apart from the viewport, so a short window or large text never
// crops it. Exit proof "the layout is not cropped at a short viewport or
// with large text (golden dimensions)"; 9-Y02/9-Y03 unit halves; the image
// carries only the recap's own content (privacy line). Dimensions and
// layout positions are checked, never pixels (host fonts differ).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/ui/annual_recap_export_image.dart';

import 'annual_recap_page_test.dart' show prior, recapOf, track;
import 'browse_harness.dart' show teardownTree;

/// Width and height from a PNG's IHDR chunk.
(int, int) pngSize(Uint8List png) {
  expect(png.sublist(1, 4), 'PNG'.codeUnits);
  final data = ByteData.sublistView(png);
  return (data.getUint32(16), data.getUint32(20));
}

final _long = List.filled(40, 'Longname').join(' ');

/// The fullest recap there can be: five entries in every list, very long
/// labels, twelve months and very large numbers.
AnnualRecap fullest() => recapOf(
  2025,
  seconds: 359999999.5,
  qualified: 999999999,
  unique: 999999999,
  days: 365,
  unavailable: 359999999,
  monthly: List.generate(12, (i) => 29999999.0 - i),
  tracks: [
    for (var i = 0; i < 5; i++)
      RankedEntry(
        entity: track('t-$i', '$i $_long'),
        listeningSeconds: 1000.0 - i,
        qualifiedPlays: 1,
      ),
  ],
  artists: [
    for (var i = 0; i < 5; i++)
      RankedEntry(
        entity: ArtistUI(id: i, name: '$i $_long'),
        listeningSeconds: 1000.0 - i,
        qualifiedPlays: 1,
      ),
  ],
  albums: [
    for (var i = 0; i < 5; i++)
      RankedEntry(
        entity: AlbumUI(id: i, artistId: i, name: '$i $_long', artist: _long),
        listeningSeconds: 1000.0 - i,
        qualifiedPlays: 1,
      ),
  ],
);

void main() {
  const root = ValueKey('recap.export');
  const footer = ValueKey('recap.export.footer');
  final title = find.descendant(
    of: find.byKey(root),
    matching: find.text('Year in music'),
  );

  Future<GlobalKey> pumpFrame(
    WidgetTester tester,
    AnnualRecap recap, {
    required Size viewport,
    double textScale = 1,
  }) async {
    await tester.binding.setSurfaceSize(viewport);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundary = GlobalKey();
    // No ProviderScope: the export reads nothing but the recap it is given
    // (no account, server, device or file fact can reach it).
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              body: RecapExportFrame(recap: recap, boundaryKey: boundary),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return boundary;
  }

  /// The rectangle of [what] (a key or a finder) in the export's own
  /// logical coordinates.
  Rect inExport(WidgetTester tester, Object what) {
    final r = tester.getRect(find.byKey(root));
    final e = tester.getRect(what is Key ? find.byKey(what) : what as Finder);
    final scale = r.width / RecapExportImage.logicalSize.width;
    return Rect.fromLTRB(
      (e.left - r.left) / scale,
      (e.top - r.top) / scale,
      (e.right - r.left) / scale,
      (e.bottom - r.top) / scale,
    );
  }

  test('the export has fixed dimensions', () {
    expect(RecapExportImage.logicalSize, const Size(540, 675));
    expect(RecapExportImage.pixelRatio, 2);
  });

  for (final (label, viewport, scale) in [
    ('a short viewport with large text', const Size(400, 300), 3.0),
    ('a large viewport', const Size(1600, 1200), 1.0),
  ]) {
    testWidgets('the PNG is 1080 × 1350 at $label', (tester) async {
      final boundary = await pumpFrame(
        tester,
        fullest(),
        viewport: viewport,
        textScale: scale,
      );
      expect(tester.takeException(), isNull);

      final png = await tester.runAsync(() => captureRecapPng(boundary));

      expect(pngSize(png!), (1080, 1350));
      await teardownTree(tester);
    });
  }

  testWidgets('the layout is the same at any viewport and text scale, and '
      'its last line lies inside the image', (tester) async {
    await pumpFrame(
      tester,
      fullest(),
      viewport: const Size(1600, 1200),
    );
    final wide = inExport(tester, footer);
    final wideTitle = inExport(tester, title);
    expect(tester.getSize(find.byKey(root)).aspectRatio, closeTo(540 / 675, 1e-6));

    await pumpFrame(
      tester,
      fullest(),
      viewport: const Size(400, 300),
      textScale: 3,
    );
    expect(tester.takeException(), isNull);
    final short = inExport(tester, footer);
    // The user's text scale does not reach the export's text.
    final shortTitle = inExport(tester, title);
    expect(shortTitle.width, closeTo(wideTitle.width, 0.01));
    expect(shortTitle.height, closeTo(wideTitle.height, 0.01));

    expect(short.left, closeTo(wide.left, 0.01));
    expect(short.top, closeTo(wide.top, 0.01));
    expect(short.width, closeTo(wide.width, 0.01));
    expect(short.height, closeTo(wide.height, 0.01));
    expect(short.top, greaterThanOrEqualTo(0));
    expect(short.bottom, lessThanOrEqualTo(675));
    expect(short.right, lessThanOrEqualTo(540));
    await teardownTree(tester);
  });

  // 9-R1-28: the export does not inherit the ambient DefaultTextStyle (the
  // preview dialog's is taller): its text has the same style and size
  // wherever it is built.
  testWidgets('the ambient text style does not reach the export',
      (tester) async {
    Future<(TextStyle?, Size)> titleUnder(TextStyle ambient) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DefaultTextStyle(
              style: ambient,
              child: RecapExportFrame(recap: fullest(), boundaryKey: GlobalKey()),
            ),
          ),
        ),
      );
      await tester.pump();
      final rich = tester.widget<RichText>(
        find.descendant(of: title, matching: find.byType(RichText)),
      );
      return (rich.text.style, tester.getSize(title));
    }

    final (plainStyle, plainSize) = await titleUnder(const TextStyle());
    final (tallStyle, tallSize) = await titleUnder(
      const TextStyle(height: 3, letterSpacing: 4, fontStyle: FontStyle.italic),
    );
    expect(tallStyle?.height, plainStyle?.height);
    expect(tallStyle?.letterSpacing, plainStyle?.letterSpacing);
    expect(tallStyle?.fontStyle, plainStyle?.fontStyle);
    expect(tallSize.height, closeTo(plainSize.height, 0.01));
    expect(tallSize.width, closeTo(plainSize.width, 0.01));
    await teardownTree(tester);
  });

  group('contents', () {
    Finder inImage(Finder f) =>
        find.descendant(of: find.byKey(root), matching: f);

    testWidgets('a prior year: label, totals, unavailable time, busiest '
        'month, top entries and the generated time', (tester) async {
      await pumpFrame(tester, prior(), viewport: const Size(800, 1000));

      expect(inImage(find.textContaining('2025 · UTC')), findsOneWidget);
      expect(inImage(find.textContaining('Year so far')), findsNothing);
      expect(inImage(find.text('2 h 33 min')), findsOneWidget);
      expect(inImage(find.text('9')), findsOneWidget);
      expect(inImage(find.text('7')), findsOneWidget);
      expect(inImage(find.text('11')), findsOneWidget);
      expect(inImage(find.textContaining('Unavailable')), findsOneWidget);
      expect(inImage(find.text('1 min')), findsOneWidget);
      expect(inImage(find.textContaining('Busiest month')), findsOneWidget);
      expect(inImage(find.text('March')), findsOneWidget);
      expect(inImage(find.textContaining('Alpha')), findsOneWidget);
      expect(inImage(find.textContaining('Unknown title')), findsOneWidget);
      expect(inImage(find.textContaining('Epsilon')), findsOneWidget);
      expect(inImage(find.textContaining('Aria')), findsWidgets);
      expect(inImage(find.textContaining('First Light')), findsOneWidget);
      expect(
        inImage(find.textContaining('15 Mar 2026, 12:00 UTC')),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('the footer says the history is from all devices, as synced '
        'to this one, and that times are UTC (OPEN-9-08)', (tester) async {
      await pumpFrame(tester, prior(), viewport: const Size(800, 1000));
      Finder inFooter(Finder f) =>
          find.descendant(of: find.byKey(footer), matching: f);

      expect(
        inFooter(find.text('Generated 15 Mar 2026, 12:00 UTC. All times UTC.')),
        findsOneWidget,
      );
      expect(
        inFooter(find.text('From your listening history on all your devices, '
            'as synced to this one.')),
        findsOneWidget,
      );
      expect(inImage(find.textContaining('this device')), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('the current year says Year so far; an empty year has no '
        'busiest month and no invented entries', (tester) async {
      await pumpFrame(tester, recapOf(2026), viewport: const Size(800, 1000));

      expect(
        inImage(find.textContaining('2026 · Year so far · UTC')),
        findsOneWidget,
      );
      expect(inImage(find.textContaining('Busiest month')), findsNothing);
      expect(inImage(find.text('0 min')), findsWidgets);
      expect(tester.takeException(), isNull);
      await teardownTree(tester);
    });
  });
}
