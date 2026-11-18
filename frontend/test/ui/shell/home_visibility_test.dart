// Phase 9 §5 para 3 (user decision 2026-10-31): the rails re-snapshot when
// Home becomes visible — tab activation, popping back to the Home root, app
// resume. The shell (a view) knows which tab and route are showing and
// forwards "Home's root is / is not what the user sees" to the suggestions
// controller (SC-26); the controller decides what that means.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/repositories/home_suggestions_service.dart';
import 'package:frontend/ui/browse/browse_pages.dart';
import 'package:frontend/ui/browse_controller.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/home/home_suggestions_controller.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/shell/app_shell.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';

class _NoBrowse implements BrowseControls {
  @override
  Future<void> refreshLibrary() async {}
}

class _VisibilityLog extends ChangeNotifier implements HomeSuggestionsControls {
  final visible = <bool>[];

  @override
  void setHomeVisible(bool v) => visible.add(v);
  @override
  SuggestionRailState stateOf(SuggestionRail rail) =>
      const SuggestionRailReady(
        tracks: [],
        emptiedByFilter: false,
        resetToken: 0,
        showNotice: false,
      );
  @override
  void setRailEngagement(SuggestionRail rail, RailEngagement e) {}
  @override
  void refreshRail(SuggestionRail rail) {}
  @override
  void retry(SuggestionRail rail) {}
  @override
  Future<PlaybackOutcome> playTrack(TrackUI track) async => const Accepted(1);
}

void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late _VisibilityLog log;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
    log = _VisibilityLog();
  });
  tearDown(() async {
    await h.dispose();
    await db.close();
  });

  Future<void> pumpShell(WidgetTester tester) async {
    await tester.pumpWidget(
      h.wrap(
        const SessionHost(root: AppShell()),
        overrides: [
          browseControlsProvider.overrideWithValue(_NoBrowse()),
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
          homeSuggestionsControlsProvider.overrideWithValue(log),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Only changes matter: collapse repeats.
  List<bool> transitions() => [
    for (var i = 0; i < log.visible.length; i++)
      if (i == 0 || log.visible[i] != log.visible[i - 1]) log.visible[i],
  ];

  testWidgets('leaving the Home tab hides it; selecting it again shows it', (
    tester,
  ) async {
    await pumpShell(tester);
    log.visible.clear();
    await tapTab(tester, 'Search');
    expect(transitions(), [false]);
    await tapTab(tester, 'Home');
    expect(transitions(), [false, true]);
    await teardownTree(tester);
  });

  testWidgets('a page pushed over Home hides it; back to the root shows it', (
    tester,
  ) async {
    await pumpShell(tester);
    log.visible.clear();
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsBrowsePage), findsOneWidget);
    expect(transitions(), [false]);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(transitions(), [false, true]);
    await teardownTree(tester);
  });

  testWidgets('re-tapping Home over a detail pops to the root and shows it', (
    tester,
  ) async {
    await pumpShell(tester);
    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    log.visible.clear();
    await tapTab(tester, 'Home');
    expect(find.byType(ArtistsBrowsePage), findsNothing);
    expect(transitions(), [true]);
    await teardownTree(tester);
  });

  testWidgets('the app going to the background hides Home; resuming shows it',
      (tester) async {
    await pumpShell(tester);
    log.visible.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(transitions(), [false]);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(transitions(), [false, true]);
    await teardownTree(tester);
  });

  testWidgets('resuming on the Search tab does not show Home', (tester) async {
    await pumpShell(tester);
    await tapTab(tester, 'Search');
    log.visible.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(log.visible, isNot(contains(true)));
    await teardownTree(tester);
  });

  // Review r1 F8: an app that starts in the background shows Home on resume.
  testWidgets('an app launched in the background shows Home when resumed', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await pumpShell(tester);
    expect(log.visible, isNot(contains(true)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(transitions().last, isTrue);
    await teardownTree(tester);
  });
}
