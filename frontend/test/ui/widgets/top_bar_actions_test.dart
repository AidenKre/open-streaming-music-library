import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';
import 'package:frontend/ui/uploads/uploads_page.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';
import '../fake_uploads_controls.dart';

/// SC-08: the top bar renders the derived TopBarAction list and navigates
/// through the session host.
void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
  });
  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Widget shell({List<Object> overrides = const []}) => harness.wrap(
    SessionHost(
      root: Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => Consumer(
            builder: (context, ref, _) => Scaffold(
              appBar: AppBar(actions: buildTopBarActions(context, ref)),
              body: const Text('tab root'),
            ),
          ),
        ),
      ),
    ),
    overrides: overrides.cast(),
  );

  testWidgets('Phase 4 shows Downloads and Settings only', (tester) async {
    await tester.pumpWidget(shell());
    final tooltips = [
      for (final b in tester.widgetList<IconButton>(find.byType(IconButton)))
        b.tooltip,
    ];
    expect(tooltips, ['Downloads', 'Settings']);
    expect(find.byTooltip('Conversions'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('an unavailable action is not shown (no dead buttons)', (
    tester,
  ) async {
    final off = StateProvider<bool>((ref) => false);
    await tester.pumpWidget(
      shell(
        overrides: [
          topBarActionsProvider.overrideWithValue([
            TopBarAction(
              destination: SessionDestination.downloadProgress,
              icon: Icons.download,
              tooltip: 'Downloads',
              isAvailable: off,
            ),
            const TopBarAction(
              destination: SessionDestination.settings,
              icon: Icons.settings,
              tooltip: 'Settings',
            ),
          ]),
        ],
      ),
    );
    expect(find.byTooltip('Downloads'), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);
    // Audit 4A(c): the action appears as soon as it becomes available.
    ProviderScope.containerOf(
      tester.element(find.byTooltip('Settings')),
    ).read(off.notifier).state = true;
    await tester.pump();
    expect(find.byTooltip('Downloads'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('Downloads opens the Downloading page above the shell', (
    tester,
  ) async {
    await tester.pumpWidget(shell());
    await tester.tap(find.byTooltip('Downloads'));
    await tester.pumpAndSettle();
    expect(find.byType(DownloadingPage), findsOneWidget);
    expect(find.text('tab root'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('tab root'), findsOneWidget);
    await teardownTree(tester);
  });

  // ---- Phase 7 (SC-08): the Uploads action, gated by the uploads block ----

  const uploads = FeatureBlocks(uploads: UploadsFeature(version: 1));

  Widget uploadsShell({AppInfo appInfo = const AppInfo()}) {
    final fake = FakeUploadsControls(overview: fakeUploadsOverview(const []));
    return harness.wrap(
      SessionHost(
        root: Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Consumer(
              builder: (context, ref, _) => Scaffold(
                appBar: AppBar(actions: buildTopBarActions(context, ref)),
                body: const Text('tab root'),
              ),
            ),
          ),
        ),
      ),
      appInfo: appInfo,
      overrides: [
        uploadsControllerFactoryProvider.overrideWithValue(() => fake),
        sessionControlsProvider.overrideWithValue(FakeSessionControls()),
      ],
    );
  }

  List<String?> tooltips(WidgetTester tester) => [
    for (final b in tester.widgetList<IconButton>(find.byType(IconButton)))
      b.tooltip,
  ];

  testWidgets('no uploads block: no Uploads action', (tester) async {
    await tester.pumpWidget(uploadsShell());
    await tester.pump();
    expect(tooltips(tester), ['Downloads', 'Settings']);
    await teardownTree(tester);
  });

  testWidgets('a live uploads block shows the Uploads action', (tester) async {
    await tester.pumpWidget(
      uploadsShell(appInfo: const AppInfo(features: uploads)),
    );
    await tester.pump();
    expect(tooltips(tester), ['Downloads', 'Uploads', 'Settings']);
    await teardownTree(tester);
  });

  testWidgets('a cached block (offline) still shows it: cached statuses',
      (tester) async {
    await tester.pumpWidget(
      uploadsShell(appInfo: const AppInfo(features: uploads, fromCache: true)),
    );
    await tester.pump();
    expect(find.byTooltip('Uploads'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('Uploads opens the Uploads page above the shell; back returns',
      (tester) async {
    await tester.pumpWidget(
      uploadsShell(appInfo: const AppInfo(features: uploads)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Uploads'));
    await tester.pumpAndSettle();
    expect(find.byType(UploadsPage), findsOneWidget);
    expect(find.text('tab root'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('tab root'), findsOneWidget);
    await teardownTree(tester);
  });

  test('the uploads destination is the Uploads page', () {
    expect(
      sessionDestinationPage(SessionDestination.uploads),
      isA<UploadsPage>(),
    );
  });
}
