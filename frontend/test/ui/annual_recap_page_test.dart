// Phase 9C.1 S7 (spec §6 paragraph 1; review 9-U06 labels and "accessible
// equivalent chart data"; SC-26: the page only observes the controller and
// forwards input). The controller is a fake.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/annual_recap_controller.dart';
import 'package:frontend/ui/annual_recap_export_image.dart';
import 'package:frontend/ui/annual_recap_page.dart';
import 'package:frontend/ui/shell/shell_chrome.dart';

import 'browse_harness.dart' show teardownTree;

int utc(int y, [int m = 1, int d = 1, int h = 0]) =>
    DateTime.utc(y, m, d, h).millisecondsSinceEpoch;

final now = utc(2026, 3, 15, 12);

HistorySnapshotToken tokenAt(int nowMs) => HistorySnapshotToken(
  boundaryLocalId: 19,
  historyContentVersion: 0,
  capturedNowUtcMs: nowMs,
  filterKey: 'k',
);

TrackUI track(String uuid, String? title) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title,
  duration: 200,
  bitrateKbps: null,
  sampleRateHz: null,
  channels: null,
  hasAlbumArt: false,
);

AnnualRecap recapOf(
  int year, {
  double seconds = 0,
  int qualified = 0,
  int unique = 0,
  int days = 0,
  double unavailable = 0,
  List<double> monthly = const [],
  List<RankedEntry<TrackUI>> tracks = const [],
  List<RankedEntry<ArtistUI>> artists = const [],
  List<RankedEntry<AlbumUI>> albums = const [],
}) {
  final range = StatsRange.year(year);
  return AnnualRecap.fromStats(
    ListeningStats(
      range: range,
      window: range.resolve(now),
      boundaryLocalId: 19,
      totals: ListeningTotals(
        listeningSeconds: seconds,
        qualifiedPlays: qualified,
        uniqueTracks: unique,
        activeDays: days,
      ),
      unavailable: ListeningSubtotal(
        listeningSeconds: unavailable,
        qualifiedPlays: 0,
      ),
      futureTimestampCount: 0,
      overlongListenCount: 0,
      buckets: [
        for (var i = 0; i < monthly.length; i++)
          ListeningBucket(
            startUtcMs: utc(year, i + 1),
            endUtcMs: utc(year, i + 2),
            listeningSeconds: monthly[i],
          ),
      ],
      chartCapped: false,
      topTracks: tracks,
      topArtists: artists,
      topAlbums: albums,
    ),
    tokenAt(now),
  );
}

/// 2025 as in the recap fixture, with 2 h added in March.
AnnualRecap prior() => recapOf(
  2025,
  seconds: 9220.5,
  qualified: 9,
  unique: 7,
  days: 11,
  unavailable: 100,
  monthly: [120.5, 0, 7800, 0, 250, 0, 600, 0, 300, 0, 100, 50],
  tracks: [
    for (final (u, t, s) in [
      ('t-a', 'Alpha', 420.5),
      ('t-c', 'Gamma', 400.0),
      ('t-b', 'Beta', 300.0),
      ('t-d', null, 280.0),
      ('t-e', 'Epsilon', 250.0),
    ])
      RankedEntry(entity: track(u, t), listeningSeconds: s, qualifiedPlays: 1),
  ],
  artists: const [
    RankedEntry(
      entity: ArtistUI(id: 1, name: 'Aria'),
      listeningSeconds: 720.5,
      qualifiedPlays: 3,
    ),
  ],
  albums: const [
    RankedEntry(
      entity: AlbumUI(id: 10, artistId: 1, name: 'First Light', artist: 'Aria'),
      listeningSeconds: 720.5,
      qualifiedPlays: 3,
    ),
  ],
);

class FakeRecapControls extends ChangeNotifier implements AnnualRecapControls {
  FakeRecapControls({this.year, this.recap, this.years = const []});

  @override
  int? year;
  @override
  List<int> years;
  @override
  AnnualRecap? recap;
  @override
  bool loading = false;
  @override
  bool failed = false;

  final calls = <String>[];
  bool disposed = false;

  void set({AnnualRecap? recap, bool loading = false, bool failed = false}) {
    this.recap = recap;
    this.loading = loading;
    this.failed = failed;
    notifyListeners();
  }

  @override
  void selectYear(int year) => calls.add('selectYear($year)');

  @override
  void refresh() => calls.add('refresh');

  @override
  void retry() => calls.add('retry');

  @override
  bool canSave = true;
  @override
  bool canShare = true;
  @override
  bool exporting = false;

  /// What each export intent answers.
  String? exportAnswer;

  /// Completed when the next export intent arrives.
  Completer<void>? nextExport;

  void _exported() {
    final c = nextExport;
    nextExport = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  void setExporting(bool value) {
    exporting = value;
    notifyListeners();
  }

  /// The PNG bytes each image intent received.
  final pngs = <Uint8List>[];

  @override
  Future<String?> savePng(Uint8List png) async {
    calls.add('savePng');
    pngs.add(png);
    _exported();
    return exportAnswer;
  }

  @override
  Future<String?> saveJson() async {
    calls.add('saveJson');
    _exported();
    return exportAnswer;
  }

  @override
  Future<String?> sharePng(Uint8List png, {Rect? origin}) async {
    calls.add('sharePng');
    pngs.add(png);
    shareOrigins.add(origin);
    _exported();
    return exportAnswer;
  }

  final shareOrigins = <Rect?>[];

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  late FakeRecapControls controls;
  final opened = <int>[];

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          annualRecapControllerFactoryProvider.overrideWithValue(() {
            opened.add(1);
            return controls;
          }),
        ],
        child: MaterialApp(home: AnnualRecapPage()),
      ),
    );
    await tester.pump();
  }

  Finder inKey(String key, String text) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.text(text),
  );

  setUp(() {
    opened.clear();
    controls = FakeRecapControls();
  });

  // 9-R1-19 (U30-A-11): the page is pushed on the Home tab navigator inside
  // the shell, so its last rows must end above the bottom chrome (mini
  // player / nav bar), like the statistics page.
  testWidgets('the last month row ends above the shell bottom chrome',
      (tester) async {
    const inset = 150.0;
    controls = FakeRecapControls(year: 2025, years: [2025], recap: prior());
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          annualRecapControllerFactoryProvider.overrideWithValue(
            () => controls,
          ),
        ],
        child: const MaterialApp(
          home: ShellChromeInsets(
            top: 0,
            bottom: inset,
            child: AnnualRecapPage(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
    await tester.pumpAndSettle();
    final december = tester.getRect(inKey('recap.months', 'December'));
    expect(december.bottom, lessThanOrEqualTo(800 - inset));
    await teardownTree(tester);
  });

  // 9-R1-15: the case asserting the page passes a year and token to the
  // factory was removed with those parameters; this keeps its disposal proof.
  testWidgets('opens one controller and disposes it on leaving',
      (tester) async {
    await pumpPage(tester);
    expect(opened, hasLength(1));
    await teardownTree(tester);
    expect(controls.disposed, isTrue);
  });

  testWidgets('loading shows progress, no numbers', (tester) async {
    controls.loading = true;
    await pumpPage(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byKey(const ValueKey('recap.listening_time')), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('a prior year: UTC label, totals rounded down, busiest month, '
      'unavailable time, top five and the generated time', (tester) async {
    controls = FakeRecapControls(
      year: 2025,
      years: [2026, 2025],
      recap: prior(),
    );
    await pumpPage(tester);

    expect(find.text('Year in music'), findsOneWidget);
    expect(find.text('2025 · UTC'), findsOneWidget);
    expect(find.textContaining('Year so far'), findsNothing);

    expect(inKey('recap.listening_time', '2 h 33 min'), findsOneWidget);
    expect(inKey('recap.qualified_plays', '9'), findsOneWidget);
    expect(inKey('recap.unique_tracks', '7'), findsOneWidget);
    expect(inKey('recap.active_days', '11'), findsOneWidget);
    expect(inKey('recap.unavailable', '1 min'), findsOneWidget);
    expect(inKey('recap.busiest_month', 'March'), findsOneWidget);
    // Review F2: the tile's label says "Generated"; the value is the time.
    expect(inKey('recap.generated', '15 Mar 2026, 12:00 UTC'), findsOneWidget);
    expect(find.textContaining('Generated Generated'), findsNothing);

    for (final title in ['Alpha', 'Gamma', 'Beta', 'Epsilon']) {
      expect(inKey('recap.top_tracks', title), findsOneWidget);
    }
    expect(inKey('recap.top_tracks', 'Unknown title'), findsOneWidget);
    expect(inKey('recap.top_artists', 'Aria'), findsOneWidget);
    expect(inKey('recap.top_albums', 'First Light'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('the monthly chart has a text table, one row per month',
      (tester) async {
    controls = FakeRecapControls(year: 2025, years: [2025], recap: prior());
    await pumpPage(tester);
    expect(inKey('recap.months', 'January'), findsOneWidget);
    expect(inKey('recap.months', 'December'), findsOneWidget);
    // March: 7800 s = 2 h 10 min; February: none.
    expect(inKey('recap.months', '2 h 10 min'), findsOneWidget);
    expect(inKey('recap.months', '0 min'), findsNWidgets(5));
    await teardownTree(tester);
  });

  testWidgets('the current year says "Year so far"', (tester) async {
    controls = FakeRecapControls(
      year: 2026,
      years: [2026, 2025],
      recap: recapOf(2026, seconds: 290, monthly: [60, 200, 30]),
    );
    await pumpPage(tester);
    expect(find.text('2026 · Year so far · UTC'), findsOneWidget);
    expect(inKey('recap.busiest_month', 'February'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('an empty year: zeros and a plain message, no busiest month '
      'and no top lists', (tester) async {
    controls = FakeRecapControls(
      year: 2023,
      years: [2026, 2023],
      recap: recapOf(2023, monthly: List.filled(12, 0)),
    );
    await pumpPage(tester);
    expect(find.text('No listening in 2023'), findsOneWidget);
    expect(inKey('recap.listening_time', '0 min'), findsOneWidget);
    expect(inKey('recap.qualified_plays', '0'), findsOneWidget);
    expect(find.byKey(const ValueKey('recap.busiest_month')), findsNothing);
    expect(find.byKey(const ValueKey('recap.top_tracks')), findsNothing);
    expect(find.byKey(const ValueKey('recap.top_artists')), findsNothing);
    expect(find.byKey(const ValueKey('recap.top_albums')), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('choosing a year and Refresh go to the controller',
      (tester) async {
    controls = FakeRecapControls(
      year: 2026,
      years: [2026, 2025, 2024],
      recap: recapOf(2026, seconds: 290, monthly: [60, 200, 30]),
    );
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('recap.year')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2024').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Refresh'));
    await tester.pump();
    expect(controls.calls, ['selectYear(2024)', 'refresh']);
    await teardownTree(tester);
  });

  testWidgets('a failure is an error with Retry, never zeros', (tester) async {
    controls = FakeRecapControls(year: 2025, years: [2025]);
    controls.failed = true;
    await pumpPage(tester);
    expect(find.text('Could not load your Year in music'), findsOneWidget);
    expect(find.byKey(const ValueKey('recap.listening_time')), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(controls.calls, ['retry']);
    await teardownTree(tester);
  });

  testWidgets('the page follows the controller\'s changes', (tester) async {
    controls = FakeRecapControls(year: 2025, years: [2025]);
    controls.loading = true;
    await pumpPage(tester);
    controls.set(recap: prior());
    await tester.pump();
    expect(inKey('recap.listening_time', '2 h 33 min'), findsOneWidget);
    await teardownTree(tester);
  });

  group('export (9C.2)', () {
    // Spec §6: "Export contains listening data, so preview it before
    // save/share"; the share sheet opens "only on explicit tap". 9-U06,
    // 9-Y02/9-Y03 unit halves. SC-26: the page renders the export image
    // and hands its bytes to the controller; it does no file work itself.
    const exportAction = ValueKey('recap.export.open');
    const savePng = ValueKey('recap.export.save_png');
    const sharePng = ValueKey('recap.export.share_png');
    const saveJson = ValueKey('recap.export.save_json');

    (int, int) pngSize(Uint8List png) {
      final data = ByteData.sublistView(png);
      return (data.getUint32(16), data.getUint32(20));
    }

    Future<void> openPreview(WidgetTester tester) async {
      controls = FakeRecapControls(year: 2025, years: [2025], recap: prior());
      await pumpPage(tester);
      await tester.tap(find.byKey(exportAction));
      await tester.pumpAndSettle();
    }

    /// Taps [key] and waits (in real async: the image is rasterised) for
    /// the controller to receive the export.
    Future<void> tapAndWait(WidgetTester tester, Key key) async {
      await tester.runAsync(() async {
        // Created in the real zone, so its completion is delivered there.
        final done = controls.nextExport = Completer<void>();
        await tester.tap(find.byKey(key));
        await done.future;
      });
      await tester.pump();
    }

    // 9-R1-27: reopening the preview while the previous one is still
    // leaving must not mount the export frame twice under one key.
    testWidgets('reopening the preview during its exit transition is fine',
        (tester) async {
      await openPreview(tester);
      Navigator.of(tester.element(find.byKey(savePng))).pop();
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tap(find.byKey(exportAction), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.byKey(savePng), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('the Export action waits for a recap', (tester) async {
      controls = FakeRecapControls(year: 2025, years: [2025]);
      controls.loading = true;
      await pumpPage(tester);

      expect(
        tester.widget<IconButton>(find.byKey(exportAction)).onPressed,
        isNull,
      );

      controls.set(recap: prior());
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byKey(exportAction)).onPressed,
        isNotNull,
      );
      await teardownTree(tester);
    });

    testWidgets('Export opens a preview of the image and exports nothing '
        'by itself', (tester) async {
      await openPreview(tester);

      expect(find.byType(RecapExportImage), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(RecapExportImage),
          matching: find.textContaining('2025 · UTC'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(savePng), findsOneWidget);
      expect(find.byKey(sharePng), findsOneWidget);
      expect(find.byKey(saveJson), findsOneWidget);
      expect(controls.calls, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('Save image hands the controller the rendered 1080 × 1350 '
        'PNG and shows its answer', (tester) async {
      await openPreview(tester);
      controls.exportAnswer = 'Image saved';

      await tapAndWait(tester, savePng);

      expect(controls.calls, ['savePng']);
      expect(pngSize(controls.pngs.single), (1080, 1350));
      await tester.pump();
      expect(find.text('Image saved'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('Share image hands over the PNG and where the sheet points '
        'from', (tester) async {
      await openPreview(tester);

      await tapAndWait(tester, sharePng);

      expect(controls.calls, ['sharePng']);
      expect(pngSize(controls.pngs.single), (1080, 1350));
      expect(controls.shareOrigins.single, isNotNull);
      await teardownTree(tester);
    });

    testWidgets('Save JSON asks the controller and shows its answer',
        (tester) async {
      await openPreview(tester);
      controls.exportAnswer = 'JSON saved';

      await tapAndWait(tester, saveJson);

      expect(controls.calls, ['saveJson']);
      await tester.pump();
      expect(find.text('JSON saved'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('a device without a save panel or file sharing says so and '
        'offers neither', (tester) async {
      controls = FakeRecapControls(year: 2025, years: [2025], recap: prior())
        ..canSave = false
        ..canShare = false;
      await pumpPage(tester);
      await tester.tap(find.byKey(exportAction));
      await tester.pumpAndSettle();

      for (final key in [savePng, sharePng, saveJson]) {
        expect(
          tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed,
          isNull,
        );
      }
      expect(
        find.text('Saving files is not available on this device'),
        findsOneWidget,
      );
      expect(
        find.text('Sharing files is not available on this device'),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('while an export runs, the export buttons wait',
        (tester) async {
      await openPreview(tester);
      controls.setExporting(true);
      await tester.pump();

      for (final key in [savePng, sharePng, saveJson]) {
        expect(
          tester.widget<ButtonStyleButton>(find.byKey(key)).onPressed,
          isNull,
        );
      }
      await teardownTree(tester);
    });
  });
}
