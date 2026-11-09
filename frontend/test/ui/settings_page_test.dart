import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings_controller.dart';
import 'package:frontend/ui/settings_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/settings/settings_registry.dart';
import 'package:frontend/ui/widgets/top_bar_actions.dart';

import 'fake_session_controls.dart';

/// Override that pins [offlineModeProvider] to a fixed value without running
/// the real health-poll timer.
class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() => _value;
}

Widget _wrap(
  SharedPreferences prefs, {
  Future<void> Function()? onDisconnect,
  bool offline = false,
  List<String> losses = const [],
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWith((_) async => prefs),
      offlineModeProvider.overrideWith(() => _StubOffline(offline)),
      if (onDisconnect != null)
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
      sharedPreferencesProvider.overrideWith((_) async => prefs),
      offlineModeProvider.overrideWith(() => _StubOffline(false)),
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

/// Settings is a lazy list: bring its end (Connection) into the tree.
Future<void> _toBottom(WidgetTester tester) async {
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 5; i++) {
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The dialog calls into ApiClient via setStreamQualityFull. Default to a
    // 2xx PUT so persistence happens; individual tests can override.
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{}', 200)),
    );
    // build()'s backend GET fires when ApiClient.baseUrl is non-empty —
    // tighten its timeout so tests don't hang on the default MockClient that
    // returns 2xx synchronously (which is fine here, but be defensive).
    SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 200);
  });

  tearDown(() {
    ApiClient.init('');
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
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient(
        (_) async => http.Response(
          '{"quality":"256"}',
          200,
          headers: {'content-type': 'application/json'},
        ),
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

    final switchFinder = find.byType(SwitchListTile);
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

  testWidgets('Disconnect tap opens the confirmation bottom sheet', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs, onDisconnect: () async {}));
    await tester.pumpAndSettle();

    await _toBottom(tester);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Reset and disconnect?'), findsOneWidget);
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
    await _toBottom(tester);
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
    await _toBottom(tester);
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

    await _toBottom(tester);
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

    await _toBottom(tester);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    // FilledButton with this label inside the bottom sheet.
    await tester.tap(find.widgetWithText(FilledButton, 'Reset and disconnect'));
    await tester.pumpAndSettle();

    expect(disconnectCalled, isTrue);
    // The page doesn't pop itself: a successful reset ends the session and
    // the session host (with every session route) goes away with it.
  });

  group('offline mode', () {
    testWidgets('stream quality dropdown is disabled while offline', (
      tester,
    ) async {
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(_wrap(prefs, offline: true));
      await tester.pumpAndSettle();

      // Both dropdowns should be present but with onChanged == null.
      final dropdowns = tester
          .widgetList<DropdownButton<String>>(
            find.byType(DropdownButton<String>),
          )
          .toList();
      expect(dropdowns, hasLength(2));
      for (final d in dropdowns) {
        expect(
          d.onChanged,
          isNull,
          reason: 'dropdown should be disabled while offline',
        );
      }
      // The explanatory tooltip is present.
      expect(find.byType(Tooltip), findsWidgets);
    });

    testWidgets(
      'offline: tapping the dropdown does not open the choice sheet',
      (tester) async {
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(_wrap(prefs, offline: true));
        await tester.pumpAndSettle();

        // Try to open the stream quality dropdown.
        await tester.tap(find.text('Original').first);
        await tester.pumpAndSettle();

        // Because onChanged is null the dropdown won't open its menu and the
        // choice bottom sheet must never appear.
        expect(find.text('Set as default'), findsNothing);
        expect(find.text('This session only'), findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
      },
    );
  });

  group('SC-21 registry', () {
    testWidgets('renders Phase 4\'s sections in order', (tester) async {
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
      await _toBottom(tester);
      expect(find.text('Library tools'), findsOneWidget);
      expect(find.text('Conversions'), findsOneWidget);
    });

    testWidgets('a section with no available rows is hidden', (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final hidden = StateProvider<bool>((ref) => false);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          offlineModeProvider.overrideWith(() => _StubOffline(false)),
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
          offlineModeProvider.overrideWith(() => _StubOffline(false)),
          settingsControlsProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const SettingsPage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

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

    // D29: the rows follow the controller's computed rule; they no longer
    // decide the offline rule themselves.
    for (final (offline, allowed) in [(false, false), (true, true)]) {
      testWidgets(
          'server quality rows follow canChangeServerQuality '
          '(offline: $offline, allowed: $allowed)', (tester) async {
        final prefs = await SharedPreferences.getInstance();
        await tester.pumpWidget(ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWith((_) async => prefs),
            offlineModeProvider.overrideWith(() => _StubOffline(offline)),
            settingsControlsProvider.overrideWithValue(
              _FakeSettings(canChangeServerQuality: allowed),
            ),
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
          expect(d.onChanged == null, !allowed);
        }
        expect(
          find.byTooltip('Unavailable while offline'),
          allowed ? findsNothing : findsNWidgets(2),
        );
      });
    }

    testWidgets('download quality and the stale switch', (tester) async {
      await pump(tester);
      final downloadDropdown = find.byType(DropdownButton<String>);
      await tester.tap(downloadDropdown.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('128 kbps').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
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
}
