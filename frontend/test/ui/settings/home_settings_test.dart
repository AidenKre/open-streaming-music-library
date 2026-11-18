// Phase 9 §5 / SC-07 / SC-21 / D12 / 9-R02 (unit half: hide/show sections
// in Settings, persisted local hide preference): Settings registers a "Home"
// section with one toggle per hideable Home rail. A toggle shows whether the
// rail is shown; flipping it goes through the Settings controller (SC-26) and
// lands in `HomeLayoutPreferences`.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/home/home_page.dart';
import 'package:frontend/ui/settings_controller.dart';
import 'package:frontend/ui/settings_page.dart';

import '../../helpers/test_credentials.dart';
import '../../helpers/test_offline.dart';

/// Records the Home toggles; everything else is irrelevant here.
class _RecordingSettings implements SettingsControls {
  final hidden = <(String, bool)>[];

  @override
  bool get canChangeServerQuality => true;
  @override
  Future<void> setStreamQualityDefault(String quality) async {}
  @override
  void setStreamQualityForSession(String quality) {}
  @override
  Future<void> setDownloadQuality(String quality) async {}
  @override
  Future<void> setNotifyStaleDownloads(bool notify) async {}
  @override
  Future<void> setHomeSectionHidden(String key, bool hidden) async =>
      this.hidden.add((key, hidden));
  @override
  void onSettingsOpened() {}
}

/// Every Home toggle fails to save (a SharedPreferences failure).
class _FailingSettings extends _RecordingSettings {
  @override
  Future<void> setHomeSectionHidden(String key, bool hidden) async =>
      throw StateError('prefs write failed');
}

const _showRediscover = 'Show Rediscover';
const _showMore = 'Show More from your artists';

void main() {
  final api = testApiClient(
    'http://localhost:8000',
    MockClient((_) async => http.Response('{}', 200)),
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final originalSyncTimeout = SettingsNotifier.backendSyncTimeout;
    addTearDown(() => SettingsNotifier.backendSyncTimeout = originalSyncTimeout);
    SettingsNotifier.backendSyncTimeout = const Duration(milliseconds: 200);
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          credentialStoreTestOverride(),
          offlineModeProvider.overrideWith(() => TestOffline(false)),
          ...overrides,
        ],
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool switchValue(WidgetTester tester, String title) => tester
      .widget<SwitchListTile>(find.widgetWithText(SwitchListTile, title))
      .value;

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a Home section after Notifications holds both toggles, on by '
      'default', (tester) async {
    await pumpSettings(tester);
    expect(find.byKey(const ValueKey('settings.section.home')), findsOneWidget);
    final notifications = tester
        .getTopLeft(
          find.byKey(const ValueKey('settings.section.notifications')),
        )
        .dy;
    final home =
        tester.getTopLeft(find.byKey(const ValueKey('settings.section.home'))).dy;
    final tools = tester
        .getTopLeft(
          find.byKey(const ValueKey('settings.section.library_tools')),
        )
        .dy;
    expect(notifications < home && home < tools, isTrue);
    expect(switchValue(tester, _showRediscover), isTrue);
    expect(switchValue(tester, _showMore), isTrue);
    await teardown(tester);
  });

  testWidgets('a stored hidden rail shows its toggle off', (tester) async {
    SharedPreferences.setMockInitialValues({
      'settings.homeHiddenSections': [HomeSectionIds.moreFromArtists],
    });
    await pumpSettings(tester);
    expect(switchValue(tester, _showRediscover), isTrue);
    expect(switchValue(tester, _showMore), isFalse);
    await teardown(tester);
  });

  testWidgets('a toggle sends its section id to the Settings controller', (
    tester,
  ) async {
    final settings = _RecordingSettings();
    await pumpSettings(
      tester,
      overrides: [settingsControlsProvider.overrideWithValue(settings)],
    );
    await tester.tap(find.widgetWithText(SwitchListTile, _showRediscover));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(SwitchListTile, _showMore));
    await tester.pumpAndSettle();
    expect(settings.hidden, [
      (HomeSectionIds.rediscover, true),
      (HomeSectionIds.moreFromArtists, true),
    ]);
    await teardown(tester);
  });

  // 9-R1-30: a failed save is not an uncaught async error; the user is told
  // and the switch keeps showing the stored state.
  testWidgets('a toggle whose save fails says so and stays as stored', (
    tester,
  ) async {
    await pumpSettings(
      tester,
      overrides: [settingsControlsProvider.overrideWithValue(_FailingSettings())],
    );
    await tester.tap(find.widgetWithText(SwitchListTile, _showRediscover));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't save this setting."), findsOneWidget);
    expect(switchValue(tester, _showRediscover), isTrue);
    await teardown(tester);
  });

  testWidgets('switching a rail off and on again persists through the real '
      'controller', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.widgetWithText(SwitchListTile, _showRediscover));
    await tester.pumpAndSettle();
    expect(switchValue(tester, _showRediscover), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('settings.homeHiddenSections'), [
      HomeSectionIds.rediscover,
    ]);

    await tester.tap(find.widgetWithText(SwitchListTile, _showRediscover));
    await tester.pumpAndSettle();
    expect(switchValue(tester, _showRediscover), isTrue);
    expect(prefs.getStringList('settings.homeHiddenSections'), isEmpty);
    await teardown(tester);
  });
}
