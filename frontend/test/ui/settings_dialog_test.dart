import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/settings_dialog.dart';

Widget _wrap(SharedPreferences prefs, {VoidCallback? onDisconnect}) {
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWith((_) async => prefs),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SettingsDialog(onDisconnect: onDisconnect),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('renders both quality dropdowns with the loaded values',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings.streamQuality': '256',
      'settings.downloadQuality': '192',
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    expect(find.text('Stream quality'), findsOneWidget);
    expect(find.text('Download quality'), findsOneWidget);
    // Each dropdown shows its selected value as a label.
    expect(find.text('256 kbps'), findsOneWidget);
    expect(find.text('192 kbps'), findsOneWidget);
  });

  testWidgets('changing the stream-quality dropdown writes through to prefs',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    // Open the stream quality dropdown.
    await tester.tap(find.text('Original').first);
    await tester.pumpAndSettle();
    // Picking a new value pops the menu and triggers setStreamQuality.
    await tester.tap(find.text('320 kbps').last);
    await tester.pumpAndSettle();

    expect(prefs.getString('settings.streamQuality'), '320');
  });

  testWidgets('Disconnect button is hidden when no callback is provided',
      (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(prefs));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('Disconnect button fires its callback', (tester) async {
    var disconnectCalled = false;
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(
      prefs,
      onDisconnect: () => disconnectCalled = true,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Disconnect'), findsOneWidget);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();

    expect(disconnectCalled, isTrue);
  });
}
