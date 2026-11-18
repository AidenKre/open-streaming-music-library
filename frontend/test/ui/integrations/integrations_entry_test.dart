// Phase 9D.2e S8: how the Integrations page is reached.
//  * Spec §7.12: "SessionDestination.integrations (SC-08), opened from an
//    Integrations row under Settings → Library tools (SC-21), gated on the
//    integrations block (SC-03). When the block says available: false, the
//    row shows only for a user who still has a connection (read from the
//    status route each time Settings opens), and the page offers the status
//    and Disconnect. Without the block there is no row."
//  * 9-F13 (unit half): row absent without the block; with available:
//    false it shows only for a connected user; with available: true it
//    shows connected or not.
// Real model (`LastfmService`) over the scripted API; the status is read
// through the model only.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/integrations/integrations_controller.dart';
import 'package:frontend/ui/integrations/integrations_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings/settings_registry.dart';
import 'package:frontend/ui/settings_controller.dart';

import '../../helpers/fake_lastfm_api.dart';
import '../browse_harness.dart' show teardownTree;
import '../fake_session_controls.dart';
import 'fake_integrations_controls.dart';

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _scope(
  FakeLastfmApi api, {
  AdvertisedFeature<IntegrationsFeature>? block,
  bool absent = false,
}) {
  final c = ProviderContainer(
    overrides: [
      ...lastfmOverrides(api, block: block, absent: absent),
      canChangeServerQualityProvider.overrideWithValue(true),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<bool> _entry(ProviderContainer c) async {
  c.listen(lastfmIntegrationsEntryProvider, (_, _) {});
  await _settle();
  return c.read(lastfmIntegrationsEntryProvider);
}

SettingsRowContribution _row(ProviderContainer c) => c
    .read(settingsRowsProvider)
    .singleWhere((r) => r.isAvailable == lastfmIntegrationsEntryProvider);

void main() {
  group('whether the row shows', () {
    test('no block: no row, nothing asked', () async {
      final api = FakeLastfmApi();
      final c = _scope(api, absent: true);
      expect(await _entry(c), isFalse);
      expect(api.calls, isEmpty);
    });

    test('a block without a lastfm entry: no row', () async {
      final api = FakeLastfmApi();
      final c = _scope(api,
          block: const AdvertisedFeature(
            IntegrationsFeature(version: 1),
            fromCache: false,
          ));
      expect(await _entry(c), isFalse);
      expect(api.calls, isEmpty);
    });

    for (final (state, reconnect) in [
      ('not_connected', null),
      ('awaiting_authorization', null),
      ('connected_disabled', false),
      ('enabled', false),
      ('enabled', true),
    ]) {
      test('available: true shows it ($state)', () async {
        final api = FakeLastfmApi()
          ..onStatus = () async =>
              lastfmStatus(state: state, needsReconnect: reconnect);
        final c = _scope(api, block: liveIntegrations(available: true));
        expect(await _entry(c), isTrue);
      });
    }

    test('available: true from the cache shows it too', () async {
      final api = FakeLastfmApi();
      final c = _scope(api,
          block: const AdvertisedFeature(
            IntegrationsFeature(
              version: 1,
              lastfm: LastfmIntegration(available: true),
            ),
            fromCache: true,
          ));
      expect(await _entry(c), isTrue);
      expect(api.calls, isEmpty);
    });

    for (final (state, reconnect, shown) in [
      ('not_connected', null, false),
      ('awaiting_authorization', null, false),
      ('connected_disabled', false, true),
      ('enabled', false, true),
      ('enabled', true, true),
      ('something_new', null, false),
    ]) {
      test('available: false shows it only with a connection ($state, '
          'needs_reconnect $reconnect)', () async {
        final api = FakeLastfmApi()
          ..onStatus = () async =>
              lastfmStatus(state: state, needsReconnect: reconnect);
        final c = _scope(api, block: liveIntegrations(available: false));
        expect(await _entry(c), shown);
        expect(api.calls, ['status']);
      });
    }

    test('available: false and the status unreadable: no row', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => throw lastfmApiError(500, 'boom');
      final c = _scope(api, block: liveIntegrations(available: false));
      expect(await _entry(c), isFalse);
    });

    test('available: false from the cache (status unknown): no row',
        () async {
      final api = FakeLastfmApi();
      final c = _scope(api,
          block: const AdvertisedFeature(
            IntegrationsFeature(
              version: 1,
              lastfm: LastfmIntegration(available: false),
            ),
            fromCache: true,
          ));
      expect(await _entry(c), isFalse);
      expect(api.calls, isEmpty);
    });
  });

  group('each time Settings opens, the status is read again', () {
    test('a connection made elsewhere shows the row on the next open',
        () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(state: 'not_connected');
      final c = _scope(api, block: liveIntegrations(available: false));
      expect(await _entry(c), isFalse);
      api.onStatus = () async => lastfmStatus(state: 'enabled');
      c.read(settingsControlsProvider).onSettingsOpened();
      await _settle();
      expect(c.read(lastfmIntegrationsEntryProvider), isTrue);
      expect(api.calls, ['status', 'status']);
    });

    test('a disconnect elsewhere hides it on the next open', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(state: 'enabled');
      final c = _scope(api, block: liveIntegrations(available: false));
      expect(await _entry(c), isTrue);
      api.onStatus = () async => lastfmStatus(state: 'not_connected');
      c.read(settingsControlsProvider).onSettingsOpened();
      await _settle();
      expect(c.read(lastfmIntegrationsEntryProvider), isFalse);
    });

    test('nothing is asked when nothing listens to the Last.fm state',
        () async {
      final api = FakeLastfmApi();
      final c = _scope(api);
      c.read(settingsControlsProvider).onSettingsOpened();
      await _settle();
      expect(api.calls, isEmpty);
    });

    test('the model state is re-read too (Now Playing learns of it)',
        () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(state: 'connected_disabled');
      final c = _scope(api, block: liveIntegrations(available: true));
      c.listen(lastfmServiceProvider, (_, _) {});
      await _settle();
      api.onStatus = () async => lastfmStatus(state: 'enabled');
      c.read(settingsControlsProvider).onSettingsOpened();
      await _settle();
      final account = c.read(lastfmServiceProvider).value as LastfmKnown;
      expect(account.status.state, LastfmAccountState.enabled);
      expect(api.calls.where((x) => x == 'status'), hasLength(2));
    });
  });

  group('the row and the destination', () {
    test('the row is under Library tools', () {
      final c = _scope(FakeLastfmApi());
      expect(_row(c).sectionId, 'library_tools');
    });

    testWidgets('the row opens SessionDestination.integrations',
        (tester) async {
      final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
      final c = ProviderContainer();
      final row = _row(c);
      c.dispose();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionControlsProvider.overrideWithValue(FakeSessionControls()),
            integrationsControllerFactoryProvider.overrideWithValue(
              () => fake,
            ),
          ],
          child: MaterialApp(
            home: SessionHost(
              root: Scaffold(body: Builder(builder: row.build)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Integrations'), findsOneWidget);
      await tester.tap(find.text('Integrations'));
      await tester.pumpAndSettle();
      expect(find.byType(IntegrationsPage), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(IntegrationsPage)))!
            .settings
            .name,
        'session/integrations',
      );
      await teardownTree(tester);
    });

    test('the destination builds the Integrations page', () {
      expect(
        sessionDestinationPage(SessionDestination.integrations),
        isA<IntegrationsPage>(),
      );
    });
  });
}
