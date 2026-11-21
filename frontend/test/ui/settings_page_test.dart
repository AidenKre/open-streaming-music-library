import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings_controller.dart';
import 'package:frontend/ui/settings_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings/settings_registry.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';

import 'browse_harness.dart' show teardownTree;
import 'fake_session_controls.dart';
import '../helpers/test_credentials.dart';
import '../helpers/test_offline.dart';

/// A transport whose delegate each test swaps after the scope exists.
class _SwapClient extends http.BaseClient {
  http.Client inner = MockClient((_) async => http.Response('{}', 200));
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
}

final _transport = _SwapClient();
final _api = testApiClient('http://localhost:8000', _transport);

Widget _wrap(
  SharedPreferences prefs, {
  Future<void> Function()? onDisconnect,
  bool offline = false,
  List<String> losses = const [],
  FakeSessionControls? session,
}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(_api),
      sharedPreferencesProvider.overrideWith((_) async => prefs),
      credentialStoreTestOverride(),
      offlineModeProvider.overrideWith(() => TestOffline(offline)),
      if (session != null)
        sessionControlsProvider.overrideWithValue(session)
      else if (onDisconnect != null)
        sessionControlsProvider.overrideWithValue(
          FakeSessionControls(onDisconnect: onDisconnect)
            ..lossSummaries = losses,
        ),
    ],
    child: MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: const SettingsPage(),
    ),
  );
}

Widget _wrapNestedSettingsLauncher(
  SharedPreferences prefs, {
  required Future<void> Function() onDisconnect,
}) {
  return ProviderScope(
    overrides: [
      apiClientProvider.overrideWithValue(_api),
      sharedPreferencesProvider.overrideWith((_) async => prefs),
      credentialStoreTestOverride(),
      offlineModeProvider.overrideWith(() => TestOffline(false)),
      // One app scope, as in production (no nested override scope).
      sessionControlsProvider.overrideWithValue(
        FakeSessionControls(onDisconnect: onDisconnect),
      ),
    ],
    child: MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Builder(
        builder: (_) => SessionHost(
          root: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => Consumer(
                builder: (context, ref, _) => Scaffold(
                  appBar: AppBar(actions: buildTopBarActions(context, ref)),
                  body: const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Settings is a lazy list: bring [target] (a Connection / Library tools row)
/// into the tree. Without a target (the "hidden outside a live session"
/// cases) scroll to the very end instead, so a negative assert still looks at
/// the bottom of the list.
Future<void> _toBottom(WidgetTester tester, [Finder? target]) async {
  final list = find.byType(Scrollable).first;
  if (target != null) {
    await tester.scrollUntilVisible(target, 400, scrollable: list);
    await tester.pumpAndSettle();
    return;
  }
  final position = tester.state<ScrollableState>(list).position;
  for (var i = 0; i < 5; i++) {
    await tester.drag(list, const Offset(0, -2000));
    await tester.pumpAndSettle();
    if (position.pixels >= position.maxScrollExtent) break;
  }
}

void main() {
  setUp(() {
    final savedSyncTimeout = SettingsNotifier.backendSyncTimeout;
    addTearDown(() => SettingsNotifier.backendSyncTimeout = savedSyncTimeout);
    SharedPreferences.setMockInitialValues({});
    // The dialog calls into ApiClient via setStreamQualityFull. Default to a
    // 2xx PUT so persistence happens; individual tests can override.
    _transport.inner = MockClient((_) async => http.Response('{}', 200));
    // build()'s backend GET fires when ApiClient.baseUrl is non-empty —
    // tighten its timeout so tests don't hang on the default MockClient that
    // returns 2xx synchronously (which is fine here, but be defensive).
    SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 200);
  });

  // Other-issues row 66: a settings model that cannot load shows a fixed
  // sentence, never the error's own text.
  testWidgets("unreadable settings: a fixed sentence, not the error's text",
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(_api),
        sharedPreferencesProvider.overrideWith((_) async => prefs),
        credentialStoreTestOverride(),
        offlineModeProvider.overrideWith(() => TestOffline(false)),
        settingsProvider.overrideWith(_UnreadableSettings.new),
      ],
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.text("This device's saved settings could not be read."),
        findsWidgets);
    expect(find.textContaining('Failed to load settings'), findsNothing);
    expect(find.textContaining('/private/prefs.json'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('renders both quality dropdowns with the loaded values', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'settings.streamQuality': '256',
      'settings.downloadQuality': '192',
    });
    final prefs = await SharedPreferences.getInstance();
    // Backend GET returns the same quality — no state change at build().
    _transport.inner = MockClient(
      (_) async => http.Response(
        '{"quality":"256"}',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );

    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    expect(find.text('Stream quality'), findsOneWidget);
    expect(find.text('Download quality'), findsOneWidget);
    // Each dropdown shows its selected value as a label.
    expect(find.text('256 kbps'), findsOneWidget);
    expect(find.text('192 kbps'), findsOneWidget);
  });

  testWidgets('changing stream quality opens a choice bottom sheet', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    // Open the stream quality dropdown.
    await tester.tap(find.text('Original').first);
    await tester.pumpAndSettle();
    // Pick a new value.
    await tester.tap(find.text('320 kbps').last);
    await tester.pumpAndSettle();

    // The choice bottom sheet should appear.
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Set as default'), findsOneWidget);
    expect(find.text('This session only'), findsOneWidget);
  });

  testWidgets('choosing Set as default persists the quality to prefs', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    // Open the stream quality dropdown and pick 320.
    await tester.tap(find.text('Original').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('320 kbps').last);
    await tester.pumpAndSettle();

    // Tap "Set as default" in the choice bottom sheet.
    await tester.tap(find.text('Set as default'));
    await tester.pumpAndSettle();

    expect(prefs.getString('settings.streamQuality'), '320');
  });

  testWidgets('choosing This session only does not persist to prefs', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    // Open the stream quality dropdown and pick 192.
    await tester.tap(find.text('Original').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('192 kbps').last);
    await tester.pumpAndSettle();

    // Tap "This session only".
    await tester.tap(find.text('This session only'));
    await tester.pumpAndSettle();

    // SharedPreferences should not be written.
    expect(prefs.getString('settings.streamQuality'), isNull);
  });

  testWidgets('changing download quality writes directly to prefs', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    // Open the download quality dropdown.
    final downloadDropdown = find.byWidgetPredicate(
      (w) => w is DropdownButton<String>,
    );
    await tester.tap(downloadDropdown.last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('320 kbps').last);
    await tester.pumpAndSettle();

    expect(prefs.getString('settings.downloadQuality'), '320');
  });

  testWidgets('notify-stale-downloads switch defaults on and toggles prefs',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    // Phase 9 adds the Home toggles: pick the stale-downloads switch.
    final switchFinder = find.widgetWithText(
      SwitchListTile,
      'Notify about changed downloads',
    );
    expect(switchFinder, findsOneWidget);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();

    expect(prefs.getBool('settings.notifyStaleDownloads'), false);
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
  });

  testWidgets('Disconnect button is hidden outside a live session', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    await _toBottom(tester);
    expect(find.text('Connection'), findsNothing);
    expect(find.text('Disconnect'), findsNothing);
    // A page, not a dialog: no Close button; back is the AppBar's.
    expect(find.text('Close'), findsNothing);
  });

  // Phase M §7.1: Log out sits in Settings → Connection next to Disconnect.
  // It keeps the local data; with nothing unsent (signoff-8-logout-warning)
  // it asks nothing and goes to the controller.
  testWidgets('Log out sits next to Disconnect and is the controller\'s', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final session = FakeSessionControls(onDisconnect: () async {});
    await tester.pumpWidget(_wrap(prefs, session: session));
    await tester.pumpAndSettle();

    await _toBottom(tester, find.text('Disconnect'));
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    final logOut = tester.getTopLeft(find.text('Log out')).dy;
    final disconnect = tester.getTopLeft(find.text('Disconnect')).dy;
    expect(logOut, lessThan(disconnect), reason: 'Log out comes first');
    // Row 32 (owner, 2026-11-17): the row's own word, Log out.
    expect(
      find.text(
          'Log out of this account; downloads and library stay on this device'),
      findsOneWidget,
    );
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(session.calls, ['logout']);
    expect(find.byType(BottomSheet), findsNothing);
  });

  // signoff-8-logout-warning (DEV-7-22, DEV-8-14, user 2026-11-14 "warn
  // first"): with unsent work, Log out asks first and names it; the token
  // changes only after the user confirms.
  group('Log out with unsent work', () {
    Future<FakeSessionControls> openSheet(
      WidgetTester tester, {
      required LogoutLosses losses,
    }) async {
      final prefs = await SharedPreferences.getInstance();
      final session = FakeSessionControls(onDisconnect: () async {})
        ..logoutLosses = losses;
      await tester.pumpWidget(_wrap(prefs, session: session));
      await tester.pumpAndSettle();
      await _toBottom(tester, find.text('Disconnect'));
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      return session;
    }

    const unsent = LogoutLosses(
      unsentUploads: 2,
      reviewDrafts: 0,
      unsentReviews: 0,
      unsentCancels: 0,
      unsentDeletions: 1,
      unconfirmedDeletions: 0,
    );

    Finder inSheet(Pattern text) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.textContaining(text),
    );

    testWidgets('asks first, naming the unsent things',
        (tester) async {
      final session = await openSheet(tester, losses: unsent);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Log out and discard unsent changes?'), findsOneWidget);
      expect(
        inSheet(
          "This device hasn't finished sending these to the server. If you "
          'log out, this device stops trying.',
        ),
        findsOneWidget,
      );
      expect(
        inSheet("2 uploads that didn't finish"),
        findsOneWidget,
      );
      expect(inSheet('1 track deletion'), findsOneWidget);
      // Round 3 (user 2026-11-14): no instructions on the lines.
      expect(inSheet('again'), findsNothing);
      expect(
        inSheet('Downloads and your library stay on this device.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Log out and discard'),
          findsOneWidget);
      // Round 2 (user 2026-11-14): no vague "work", no list header.
      expect(inSheet(RegExp(r'\bwork\b', caseSensitive: false)), findsNothing);
      expect(inSheet('These will be lost'), findsNothing);
      expect(inSheet('Not sent after you log out'), findsNothing);
      expect(session.calls, isEmpty, reason: 'nothing changes while it asks');
      await teardownTree(tester);
    });

    testWidgets('Cancel changes nothing', (tester) async {
      final session = await openSheet(tester, losses: unsent);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(session.calls, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('dismissing the sheet counts as Cancel', (tester) async {
      final session = await openSheet(tester, losses: unsent);
      await tester.tapAt(const Offset(10, 10)); // the barrier
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(session.calls, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('confirming logs out', (tester) async {
      final session = await openSheet(tester, losses: unsent);
      await tester.tap(find.widgetWithText(FilledButton, 'Log out and discard'));
      await tester.pumpAndSettle();
      expect(session.calls, ['logout']);
      await teardownTree(tester);
    });

    testWidgets('a double tap while counting opens one sheet', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final gate = Completer<LogoutLosses>();
      final session = FakeSessionControls(onDisconnect: () async {})
        ..logoutLossesGate = gate;
      await tester.pumpWidget(_wrap(prefs, session: session));
      await tester.pumpAndSettle();
      await _toBottom(tester, find.text('Disconnect'));
      await tester.tap(find.text('Log out'));
      await tester.pump();
      await tester.tap(find.text('Log out'));
      await tester.pump();
      gate.complete(unsent);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(session.calls, isEmpty);
      await teardownTree(tester);
    });

    testWidgets('a count that could not be read still asks, saying so',
        (tester) async {
      final session = await openSheet(
        tester,
        losses: const LogoutLosses(
          unsentUploads: null,
          reviewDrafts: null,
          unsentReviews: null,
          unsentCancels: null,
          unsentDeletions: 0,
          unconfirmedDeletions: 0,
        ),
      );
      expect(find.text('Log out and discard unsent changes?'), findsOneWidget);
      expect(
        inSheet('Some unsent changes could not be counted.'),
        findsOneWidget,
      );
      expect(session.calls, isEmpty);
      await teardownTree(tester);
    });
  });

  testWidgets('Log out is hidden outside a live session', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();
    await _toBottom(tester);
    expect(find.text('Log out'), findsNothing);
  });

  testWidgets('Disconnect tap opens the confirmation bottom sheet', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs, onDisconnect: () async {}));
    await tester.pumpAndSettle();

    await _toBottom(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Reset and disconnect?'), findsOneWidget);
  });

  // One sheet per tap. A second tap while the losses are read
  // does nothing; once the sheet is closed, a tap asks again.
  testWidgets('a double tap on Disconnect while the losses are read opens '
      'one sheet', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final gate = Completer<List<String>>();
    final session = FakeSessionControls(onDisconnect: () async {})
      ..lossSummariesGate = gate;
    await tester.pumpWidget(_wrap(prefs, session: session));
    await tester.pumpAndSettle();
    await _toBottom(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    await tester.tap(find.text('Disconnect'));
    await tester.pump();
    gate.complete(['2 unsent metadata edits']);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(session.lossSummaryReads, 1);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(session.calls, isEmpty);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget,
        reason: 'the guard is released once the sheet closes');
    await teardownTree(tester);
  });

  // SC-15: the confirmation names what will be lost.
  testWidgets('the Disconnect confirmation lists what will be lost', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _wrap(
        prefs,
        onDisconnect: () async {},
        losses: ['2 unsent metadata edits'],
      ),
    );
    await tester.pumpAndSettle();
    await _toBottom(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Reset and disconnect?'), findsOneWidget);
    expect(find.textContaining('2 unsent metadata edits'), findsOneWidget);
  });

  testWidgets('Settings opened from tab navigator keeps disconnect available', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _wrapNestedSettingsLauncher(prefs, onDisconnect: () async {}),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    await _toBottom(tester, find.text('Disconnect'));
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('Cancelling the disconnect bottom sheet does NOT fire callback', (
    tester,
  ) async {
    var disconnectCalled = false;
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _wrap(
        prefs,
        onDisconnect: () async {
          disconnectCalled = true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await _toBottom(tester, find.text('Disconnect'));
    expect(find.text('Disconnect'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Reset and disconnect?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(disconnectCalled, isFalse);
    // The Settings page is still visible.
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('Confirming the disconnect bottom sheet DOES fire callback', (
    tester,
  ) async {
    var disconnectCalled = false;
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _wrap(
        prefs,
        onDisconnect: () async {
          disconnectCalled = true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await _toBottom(tester, find.text('Disconnect'));
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    // FilledButton with this label inside the bottom sheet.
    await tester.tap(find.widgetWithText(FilledButton, 'Reset and disconnect'));
    await tester.pumpAndSettle();

    expect(disconnectCalled, isTrue);
    // The page doesn't pop itself: a successful reset ends the session and
    // the session host (with every session route) goes away with it.
  });

  // D7 (a) (owner, 2026-11-17; amends Phase 4 D29): offline, only "Set as
  // default" for stream quality is locked: download quality and "This
  // session only" are stored on this device only.
  group('offline mode', () {
    testWidgets('both quality dropdowns stay usable while offline', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(_wrap(prefs, offline: true));
      await tester.pumpAndSettle();

      final dropdowns = tester
          .widgetList<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .toList();
      expect(dropdowns, hasLength(2));
      for (final d in dropdowns) {
        expect(d.onChanged, isNotNull);
      }
      expect(find.byTooltip('Unavailable while offline'), findsNothing);
    });

    testWidgets('offline: download quality changes and is saved', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(_wrap(prefs, offline: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('128 kbps').last);
      await tester.pumpAndSettle();
      expect(prefs.getString('settings.downloadQuality'), '128');
    });

    testWidgets(
      'offline: the stream sheet offers This session only; Set as default '
      'is off with its hint',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(_wrap(prefs, offline: true));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Original').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('192 kbps').last);
        await tester.pumpAndSettle();

        expect(find.byType(BottomSheet), findsOneWidget);
        final setDefault = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Set as default'),
        );
        expect(setDefault.onPressed, isNull);
        expect(find.byTooltip('Unavailable while offline'), findsOneWidget);

        await tester.tap(find.text('This session only'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text('192 kbps'), findsOneWidget,
            reason: 'the session quality is shown');
        expect(prefs.getString('settings.streamQuality'), isNull);
      },
    );
  });

  // D7 (owner, 2026-11-17): a refused "Set as default" keeps the old default
  // on the row and says so.
  testWidgets('a refused Set as default keeps the old default and says so', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    _transport.inner = MockClient(
      (req) async => req.method == 'PUT'
          ? http.Response('{"detail":"refused"}', 400)
          : http.Response('{}', 200),
    );
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Original').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('320 kbps').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set as default'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't save the default quality. Try again."),
        findsOneWidget);
    final stream = tester
        .widgetList<DropdownButton<String>>(find.byType(DropdownButton<String>))
        .first;
    expect(stream.value, 'original');
    expect(prefs.getString('settings.streamQuality'), isNull);
  });

  group('SC-21 registry', () {
    testWidgets('renders Phase 4\'s sections in order', (tester) async {
      // Tall enough that the lazy list builds every section (Phase 5 adds
      // "Sync & storage" before Connection).
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(_wrap(prefs, onDisconnect: () async {}));
      await tester.pumpAndSettle();
      final titles = [
        for (final key in [
          'settings.section.playback',
          'settings.section.downloads',
          'settings.section.notifications',
          'settings.section.library_tools',
          'settings.section.connection',
        ])
          tester.getTopLeft(find.byKey(ValueKey(key))).dy,
      ];
      expect([...titles]..sort(), titles, reason: 'registry order');
      expect(find.text('Playback quality'), findsOneWidget);
      await _toBottom(tester, find.text('Library tools'));
      expect(find.text('Library tools'), findsOneWidget);
      expect(find.text('Conversions'), findsOneWidget);
    });

    testWidgets('a section with no available rows is hidden', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final hidden = StateProvider<bool>((ref) => false);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          credentialStoreTestOverride(),
          offlineModeProvider.overrideWith(() => TestOffline(false)),
          settingsSectionsProvider.overrideWithValue(const [
            SettingsSection(id: 'a', order: 0, title: 'Shown'),
            SettingsSection(id: 'b', order: 1, title: 'Empty'),
          ]),
          settingsRowsProvider.overrideWithValue([
            SettingsRowContribution(
              sectionId: 'a', order: 0, build: (_) => const Text('row a')),
            SettingsRowContribution(
              sectionId: 'b', order: 0, isAvailable: hidden,
              build: (_) => const Text('row b')),
          ]),
        ],
        child: const MaterialApp(home: SettingsPage()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Shown'), findsOneWidget);
      expect(find.text('row a'), findsOneWidget);
      expect(find.text('Empty'), findsNothing);
      expect(find.text('row b'), findsNothing);
    });
  });

  group('inputs go to SettingsControls (SC-26)', () {
    late _FakeSettings fake;
    Future<void> pump(WidgetTester tester) async {
      final prefs = await SharedPreferences.getInstance();
      fake = _FakeSettings();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          credentialStoreTestOverride(),
          offlineModeProvider.overrideWith(() => TestOffline(false)),
          settingsControlsProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const SettingsPage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    // 9D.2e (spec §7.12): the Integrations row's status is read "each time
    // Settings opens".
    testWidgets('opening Settings tells the controller once', (tester) async {
      await pump(tester);
      expect(fake.opened, 1);
      await tester.pump();
      expect(fake.opened, 1);
      expect(fake.calls, isEmpty);
    });

    testWidgets('stream quality: default vs this session', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Original').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('320 kbps').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set as default'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Original').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('192 kbps').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('This session only'));
      await tester.pumpAndSettle();
      expect(fake.calls, ['default 320', 'session 192']);
    });

    // D29, amended by D7 (a): the rows follow the controller's computed
    // rule; it locks only the sheet's "Set as default".
    for (final (offline, allowed) in [(false, false), (true, true)]) {
      testWidgets(
          'Set as default follows canChangeServerQuality '
          '(offline: $offline, allowed: $allowed)', (tester) async {
        final prefs = await SharedPreferences.getInstance();
        final fake = _FakeSettings(canChangeServerQuality: allowed);
        await tester.pumpWidget(ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWith((_) async => prefs),
            credentialStoreTestOverride(),
            offlineModeProvider.overrideWith(() => TestOffline(offline)),
            settingsControlsProvider.overrideWithValue(fake),
          ],
          child: MaterialApp(
            theme: ThemeData(splashFactory: NoSplash.splashFactory),
            home: const SettingsPage(),
          ),
        ));
        await tester.pumpAndSettle();
        final dropdowns = tester
            .widgetList<DropdownButton<String>>(
              find.byType(DropdownButton<String>),
            )
            .toList();
        expect(dropdowns, hasLength(2));
        for (final d in dropdowns) {
          expect(d.onChanged, isNotNull);
        }

        await tester.tap(find.text('Original').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('320 kbps').last);
        await tester.pumpAndSettle();
        final setDefault = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Set as default'),
        );
        expect(setDefault.onPressed == null, !allowed);
        expect(
          find.byTooltip('Unavailable while offline'),
          allowed ? findsNothing : findsOneWidget,
        );
        await tester.tap(find.text('This session only'));
        await tester.pumpAndSettle();
        expect(fake.calls, ['session 320']);
      });
    }

    testWidgets('download quality and the stale switch', (tester) async {
      await pump(tester);
      final downloadDropdown = find.byType(DropdownButton<String>);
      await tester.tap(downloadDropdown.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('128 kbps').last);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.widgetWithText(
          SwitchListTile,
          'Notify about changed downloads',
        ),
        matching: find.byType(Switch),
      ));
      await tester.pumpAndSettle();
      expect(fake.calls, ['download 128', 'notify false']);
    });
  });
}

class _FakeSettings implements SettingsControls {
  _FakeSettings({this.canChangeServerQuality = true});
  @override
  final bool canChangeServerQuality;
  final calls = <String>[];
  @override
  Future<void> setStreamQualityDefault(String quality) async =>
      calls.add('default $quality');
  @override
  void setStreamQualityForSession(String quality) =>
      calls.add('session $quality');
  @override
  Future<void> setDownloadQuality(String quality) async =>
      calls.add('download $quality');
  @override
  Future<void> setNotifyStaleDownloads(bool notify) async =>
      calls.add('notify $notify');
  @override
  Future<void> setHomeSectionHidden(String key, bool hidden) async =>
      calls.add('home $key $hidden');
  int opened = 0;
  @override
  void onSettingsOpened() => opened++;
}

/// A settings model whose load fails, with a detail that must not be shown.
class _UnreadableSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async =>
      throw StateError('cannot read /private/prefs.json');
}
