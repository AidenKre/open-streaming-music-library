// Phase 9D.2e S7: Disconnect.
//  * Spec §7.11: "The page reminds the user that they can also remove the
//    application under Last.fm settings → Applications; Last.fm's API offers
//    no way for OSML to revoke its own access."
//  * Spec §7.4: Disconnect works in every server state and deletes what is
//    waiting; §7.5 point 7: coming back needs a new approval and a new
//    confirmation.
//  * Disconnect is sent only after the user confirms.
import 'package:flutter_test/flutter_test.dart';

import '../browse_harness.dart' show teardownTree;
import 'fake_integrations_controls.dart';

const _reminder = 'You can also remove the application under Last.fm '
    'settings → Applications on last.fm.';

void main() {
  testWidgets('the page reminds of Last.fm settings → Applications',
      (tester) async {
    final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
    await pumpIntegrations(tester, fake);
    expect(find.text(_reminder), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('Disconnect asks first; Cancel sends nothing', (tester) async {
    final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
    await pumpIntegrations(tester, fake);
    await tester.tap(byKey('integrations.disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect Last.fm?'), findsOneWidget);
    expect(
      find.text('Scrobbles still waiting are discarded. Coming back needs a '
          'new approval and a new confirmation. $_reminder'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.calls, isEmpty);
    expect(find.text('Disconnect Last.fm?'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('confirming disconnects', (tester) async {
    final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
    await pumpIntegrations(tester, fake);
    await tester.tap(byKey('integrations.disconnect'));
    await tester.pumpAndSettle();
    await tester.tap(byKey('integrations.disconnect.confirm'));
    await tester.pumpAndSettle();
    expect(fake.calls, ['disconnect']);
    await teardownTree(tester);
  });

  for (final (label, fake) in [
    ('block off', () => FakeIntegrationsControls.known(
        status(state: 'enabled'), available: false)),
    ('stopped', () => FakeIntegrationsControls.known(
        status(service: 'stopped', state: 'enabled'))),
    ('awaiting', () => FakeIntegrationsControls.known(
        status(state: 'awaiting_authorization', needsReconnect: null,
            account: null))),
    ('needs reconnect', () => FakeIntegrationsControls.known(
        status(state: 'enabled', needsReconnect: true))),
  ]) {
    testWidgets('Disconnect is offered ($label)', (tester) async {
      final f = fake();
      await pumpIntegrations(tester, f);
      expect(byKey('integrations.disconnect'), findsOneWidget);
      await teardownTree(tester);
    });
  }

  testWidgets('offline: no Disconnect', (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'enabled'),
      online: false,
    );
    await pumpIntegrations(tester, fake);
    expect(byKey('integrations.disconnect'), findsNothing);
    await teardownTree(tester);
  });
}
