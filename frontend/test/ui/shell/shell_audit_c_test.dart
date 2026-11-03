import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/stale_downloads_provider.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';
import 'package:frontend/ui/shell/glass.dart';
import 'package:frontend/ui/widgets/convert_confirm_sheet.dart';
import 'package:frontend/ui/widgets/convert_target_sheet.dart';
import 'package:frontend/ui/widgets/download_quality_sheet.dart';
import 'package:frontend/ui/widgets/full_player.dart';
import 'package:frontend/ui/widgets/library_card.dart';
import 'package:frontend/ui/widgets/mini_player.dart';
import 'package:frontend/ui/widgets/offline_banner.dart';
import 'package:frontend/ui/widgets/pending_edits_banner.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

/// Audit 4B(c): keyboard reserve and state, every tab-content sheet above
/// the chrome, Home/Search feeds' ends, the notifications count and its
/// transitions, a strict stack order, the full player above the chrome,
/// the opaque reduced-effects tint, the Downloaded empty state.
void main() {
  late AppDatabase db;
  late BrowseHarness h;

  setUpAll(() => ApiClient.init('http://localhost:8000'));

  setUp(() async {
    initCoverArtCache(CoverArtCacheManager.noop());
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, [
      const SeedTrack(
        uuid: 'd1',
        title: 'Kept Song',
        artistId: 1,
        artist: 'Ann',
        albumId: 10,
        album: 'Air',
        downloaded: true,
      ),
      for (var i = 1; i <= 12; i++)
        SeedTrack(
          uuid: 'z$i',
          title: 'Zed Song $i',
          artistId: 100 + i,
          artist: 'Zed Artist $i',
          albumId: 100 + i,
          album: 'Zed Album $i',
        ),
    ]);
    h = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  Future<void> pumpShell(
    WidgetTester tester, {
    Size? size,
    List<dynamic> overrides = const [],
    bool offline = false,
  }) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      h.wrap(
        const SessionHost(root: AppShell()),
        offline: offline,
        overrides: [
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
          ...overrides.cast(),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<TrackUI> track(WidgetTester tester) async =>
      (await tester.runAsync(() => BrowseRepository(db).getTrack('d1')))!;

  Future<void> typeSearch(WidgetTester tester, String q) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Search'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(TextField),
      ),
      q,
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  testWidgets('#1 keyboard: the inset is reserved once; the stack returns '
      'with the tab, query and results kept', (tester) async {
    await pumpShell(tester, size: const Size(800, 600));
    await typeSearch(tester, 'Zed');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(find.byKey(AppShell.bottomStackKey), findsNothing);
    final feed = tester.getRect(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(CustomScrollView),
      ),
    );
    // Reserved exactly once: the feed ends AT the keyboard, not above it.
    expect(feed.bottom, closeTo(300, 0.5));
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    expect(find.byKey(AppShell.bottomStackKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(AppShell.topBarKey),
        matching: find.text('Search'),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byType(SearchPage),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      'Zed',
    );
    expect(find.byType(LibraryCard), findsWidgets);
    await teardownTree(tester);
  });

  for (final (name, open) in <(String, Future<Object?> Function(BuildContext))>[
    ('download quality', (c) => showDownloadQualitySheet(c)),
    (
      'convert target',
      (c) => showConvertTargetSheet(
        c,
        allowedTargets: const [
          ConversionTargetInfo(codec: 'flac', isLossless: true),
        ],
        bitratePresets: const [192, 320],
      ),
    ),
    (
      'convert confirm',
      (c) => showConvertConfirmSheet(
        c,
        sourceCodec: 'mp3',
        sourceBitrateKbps: 320,
        targetCodec: 'flac',
        targetIsLossless: true,
        targetBitrateKbps: null,
      ),
    ),
  ]) {
    testWidgets('#2 the $name sheet from tab content sits above the chrome', (
      tester,
    ) async {
      await pumpShell(tester);
      unawaited(open(tester.element(find.byType(HomePage))));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(NavigationBar).hitTestable(), findsNothing);
      final sheet = tester.getRect(find.byType(BottomSheet));
      expect(find.byType(BottomSheet).hitTestable(), findsOneWidget);
      expect(sheet.bottom, 600);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await teardownTree(tester);
    });
  }

  testWidgets('#3 Home and Search feeds end above the chrome', (tester) async {
    await pumpShell(tester, size: const Size(800, 420));
    h.audio.showTrack(await track(tester));
    await tester.pumpAndSettle();
    Future<void> lastAbove(Finder within, Finder items) async {
      final scrollable = find
          .descendant(of: within, matching: find.byType(Scrollable))
          .first;
      final pos = tester.state<ScrollableState>(scrollable).position;
      pos.jumpTo(pos.maxScrollExtent);
      await tester.pumpAndSettle();
      final last = tester.getRect(
        find.descendant(of: within, matching: items).last,
      );
      final chromeTop = tester
          .getTopLeft(find.byKey(AppShell.bottomStackKey))
          .dy;
      expect(last.bottom, lessThanOrEqualTo(chromeTop + 0.5));
    }

    await lastAbove(find.byType(HomePage), find.byType(Card));
    await typeSearch(tester, 'Zed');
    await lastAbove(
      find.descendant(
        of: find.byType(SearchPage),
        matching: find.byType(CustomScrollView),
      ),
      find.byType(LibraryCard),
    );
    await teardownTree(tester);
  });

  testWidgets('#4 notifications count follows the banners shown; the label '
      'goes when they do', (tester) async {
    final stale = StreamController<List<TrackUI>>.broadcast();
    addTearDown(stale.close);
    await pumpShell(
      tester,
      size: const Size(800, 300),
      offline: true,
      overrides: [staleDownloadsProvider.overrideWith((ref) => stale.stream)],
    );
    stale.add([await track(tester)]);
    await tester.pumpAndSettle();
    expect(
      find.text('Notifications (2)'),
      findsOneWidget,
      reason: 'offline + stale; pending hidden',
    );
    stale.add(const []);
    h.offline.set(false);
    await tester.pumpAndSettle();
    expect(find.textContaining('Notifications ('), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('#5 stack order with every surface shown (strict)', (
    tester,
  ) async {
    final t = await track(tester);
    await pumpShell(
      tester,
      size: const Size(800, 1200),
      offline: true,
      overrides: [
        pendingEditCountsProvider.overrideWith(
          (ref) => Stream.value((pending: 1, conflicted: 0, rejected: 0)),
        ),
        staleDownloadsProvider.overrideWith((ref) => Stream.value([t])),
      ],
    );
    h.audio.showTrack(t);
    await tester.pumpAndSettle();
    final stack = find.byKey(AppShell.bottomStackKey);
    double top(Type type) => tester
        .getTopLeft(find.descendant(of: stack, matching: find.byType(type)))
        .dy;
    for (final type in [
      PendingEditsBanner,
      StaleDownloadsBanner,
      OfflineBanner,
      MiniPlayer,
    ]) {
      expect(
        tester
            .getSize(find.descendant(of: stack, matching: find.byType(type)))
            .height,
        greaterThan(0),
        reason: '$type shown',
      );
    }
    expect(top(PendingEditsBanner), lessThan(top(StaleDownloadsBanner)));
    expect(top(StaleDownloadsBanner), lessThan(top(OfflineBanner)));
    expect(top(OfflineBanner), lessThan(top(MiniPlayer)));
    expect(top(MiniPlayer), lessThan(top(NavigationBar)));
    await teardownTree(tester);
  });

  testWidgets('the full player covers the chrome', (tester) async {
    await pumpShell(tester);
    h.audio.showTrack(await track(tester));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MiniPlayer));
    await tester.pumpAndSettle();
    expect(find.byType(FullPlayer), findsOneWidget);
    expect(find.byType(NavigationBar).hitTestable(), findsNothing);
    expect(find.byKey(AppShell.topBarKey).hitTestable(), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await teardownTree(tester);
  });

  testWidgets('reduced effects: the tint is opaque', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(highContrast: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpShell(tester);
    final tints = tester.widgetList<ColoredBox>(
      find.descendant(
        of: find.byType(GlassSurface),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(tints, isNotEmpty);
    expect(tints.every((c) => c.color.a == 1.0), isTrue);
    await teardownTree(tester);
  });

  testWidgets('the Downloaded empty state sits above the chrome', (
    tester,
  ) async {
    await tester.runAsync(() => h.manager.deleteDownload('d1'));
    // Short enough that an unpadded, full-height-centred message would sit
    // under the chrome.
    await pumpShell(tester, size: const Size(800, 330));
    h.audio.showTrack(await track(tester));
    await tester.pumpAndSettle();
    // (Its entry card sits under the chrome at this height; open directly.)
    openBrowse(
      tester.element(find.byType(HomePage)),
      BrowseDestination.downloaded,
    );
    await tester.pumpAndSettle();
    final msg = tester.getRect(find.text('No downloaded tracks yet.'));
    final chromeTop = tester.getTopLeft(find.byKey(AppShell.bottomStackKey)).dy;
    expect(msg.bottom, lessThanOrEqualTo(chromeTop));
    await teardownTree(tester);
  });
}
