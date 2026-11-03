import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/downloading_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../browse_harness.dart';

/// SC-08: the top bar renders the derived TopBarAction list and navigates
/// through the session host.
void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    ApiClient.init('');
    initCoverArtCache(CoverArtCacheManager.noop());
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
}
