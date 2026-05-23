import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/disconnect_callback.dart';
import 'package:frontend/ui/settings_dialog.dart';

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
  DisconnectCallback? onDisconnect,
  bool offline = false,
}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWith((_) async => prefs),
      offlineModeProvider.overrideWith(() => _StubOffline(offline)),
    ],
    child: MaterialApp(
      home: Scaffold(body: SettingsDialog(onDisconnect: onDisconnect)),
    ),
  );
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
      MockClient((_) async => http.Response('{"quality":"256"}', 200,
          headers: {'content-type': 'application/json'})),
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

  testWidgets('Disconnect button is hidden when no callback is provided', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('Disconnect tap opens the confirmation bottom sheet', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _wrap(prefs, onDisconnect: () {}),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.text('Reset and disconnect?'), findsOneWidget);
  });

  testWidgets('Cancelling the disconnect bottom sheet does NOT fire callback',
      (tester) async {
    var disconnectCalled = false;
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _wrap(prefs, onDisconnect: () => disconnectCalled = true),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disconnect'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Reset and disconnect?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(disconnectCalled, isFalse);
    // The Settings AlertDialog is still visible.
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('Confirming the disconnect bottom sheet DOES fire callback',
      (tester) async {
    var disconnectCalled = false;
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      _wrap(prefs, onDisconnect: () => disconnectCalled = true),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    // FilledButton with this label inside the bottom sheet.
    await tester.tap(find.widgetWithText(FilledButton, 'Reset and disconnect'));
    await tester.pumpAndSettle();

    expect(disconnectCalled, isTrue);
    // The SettingsDialog itself has been popped.
    expect(find.text('Settings'), findsNothing);
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
        expect(d.onChanged, isNull,
            reason: 'dropdown should be disabled while offline');
      }
      // The explanatory tooltip is present.
      expect(find.byType(Tooltip), findsWidgets);
    });

    testWidgets('offline: tapping the dropdown does not open the choice sheet',
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
    });
  });
}
