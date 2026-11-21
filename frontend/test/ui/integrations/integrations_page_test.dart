// Phase 9D.2e S4: the Integrations page's states and its connect flow.
//  * Spec §7.12: "It shows the state, the connect and opt-in flow, ..., a
//    reconnect prompt when needed, and 'Scrobbling is stopped on this
//    server. Ask whoever runs it.' when service is stopped." "When the block
//    says available: false, ... the page offers the status and Disconnect."
//    "The text 'Scrobbling powered by Last.fm' links to https://www.last.fm/
//    ... Links open in the system browser on a tap."
//  * Spec §7.4: Approve on last.fm, then "The user returns and taps Finish
//    connecting."
//  * SC-26: every tap calls the controller; the page decides nothing (the
//    offer comes from the model's policy, through the controller's view).
//  * SC-22: errors are the controller's message in OSML's words.
// The block × connection × service × online matrix itself is pinned by
// `lastfm_page_policy_test.dart`; here each offer flag shows (or hides) its
// control.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/lastfm/lastfm_errors.dart';
import 'package:frontend/ui/integrations/integrations_controller.dart';

import '../browse_harness.dart' show teardownTree;
import 'fake_integrations_controls.dart';
import '../../helpers/fake_lastfm_api.dart' show lastfmStatus;

const _stopped = 'Scrobbling is stopped on this server. Ask whoever runs it.';
const _credit = 'Scrobbling powered by Last.fm';

bool _enabled(WidgetTester tester, Finder button) {
  final w = tester.widget(
    find.descendant(of: button, matching: find.byWidgetPredicate(
      (w) => w is ButtonStyleButton,
    )).first,
  ) as ButtonStyleButton;
  return w.onPressed != null;
}

void main() {
  group('loading and failure', () {
    testWidgets('loading shows progress and nothing to tap', (tester) async {
      final fake = FakeIntegrationsControls(
        const IntegrationsView(load: IntegrationsLoad.loading),
      );
      await pumpIntegrations(tester, fake);
      expect(find.text('Integrations'), findsOneWidget);
      expect(byKey('integrations.loading'), findsOneWidget);
      expect(byKey('integrations.connect'), findsNothing);
      expect(byKey('integrations.disconnect'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('a failed read shows its words and Retry', (tester) async {
      final fake = FakeIntegrationsControls(
        IntegrationsView(
          load: IntegrationsLoad.failed,
          loadError: lastfmProblemText(LastfmProblem.unavailable),
        ),
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(lastfmProblemText(LastfmProblem.unavailable)),
          findsOneWidget);
      await tester.tap(byKey('integrations.retry'));
      await tester.pump();
      expect(fake.calls, ['refresh']);
      await teardownTree(tester);
    });

    testWidgets('not offered says so, offers nothing', (tester) async {
      final fake = FakeIntegrationsControls(
        const IntegrationsView(load: IntegrationsLoad.notOffered),
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(lastfmProblemText(LastfmProblem.notOffered)),
          findsOneWidget);
      expect(byKey('integrations.connect'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('unreachable (cached block) says so, offers nothing',
        (tester) async {
      final fake = FakeIntegrationsControls(
        const IntegrationsView(load: IntegrationsLoad.unreachable,
            available: true),
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(lastfmProblemText(LastfmProblem.unreachable)),
          findsOneWidget);
      expect(byKey('integrations.connect'), findsNothing);
      expect(byKey('integrations.disconnect'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('the credit', () {
    for (final view in [
      const IntegrationsView(load: IntegrationsLoad.loading),
      const IntegrationsView(load: IntegrationsLoad.unreachable),
      knownView(status(state: 'not_connected', needsReconnect: null)),
      knownView(status(state: 'enabled')),
      knownView(status(state: 'enabled'), available: false),
    ]) {
      testWidgets('is on the page as text and opens last.fm on a tap '
          '(${view.load.name}, ${view.status?.state.name})', (tester) async {
        final fake = FakeIntegrationsControls(view);
        await pumpIntegrations(tester, fake);
        expect(find.text(_credit), findsOneWidget);
        expect(
          find.descendant(
            of: byKey('integrations.credit'),
            matching: find.text(_credit),
          ),
          findsOneWidget,
        );
        await tester.tap(byKey('integrations.credit'));
        await tester.pump();
        expect(fake.calls, ['openCredit']);
        await teardownTree(tester);
      });
    }

    testWidgets('no image anywhere on the page', (tester) async {
      final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
      await pumpIntegrations(tester, fake);
      expect(find.byType(Image), findsNothing);
      await teardownTree(tester);
    });
  });

  group('not connected', () {
    testWidgets('Connect asks the controller', (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'not_connected', needsReconnect: null, account: null),
      );
      await pumpIntegrations(tester, fake);
      expect(find.text('Connect Last.fm'), findsOneWidget);
      await tester.tap(byKey('integrations.connect'));
      await tester.pump();
      expect(fake.calls, ['connect']);
      expect(byKey('integrations.finish'), findsNothing);
      expect(byKey('integrations.disconnect'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline: no Connect, and why', (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'not_connected', needsReconnect: null, account: null),
        online: false,
      );
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.connect'), findsNothing);
      expect(find.text(
          "You're offline. Changing your Last.fm connection needs your "
          'server.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('busy: the buttons are disabled and progress shows',
        (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'not_connected', needsReconnect: null, account: null),
      )..busy = true;
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.busy'), findsOneWidget);
      expect(_enabled(tester, byKey('integrations.connect')), isFalse);
      await teardownTree(tester);
    });
  });

  group('awaiting the approval', () {
    testWidgets('says what to do; Finish, Start again and Disconnect',
        (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'awaiting_authorization', needsReconnect: null,
            account: null),
      );
      await pumpIntegrations(tester, fake);
      // The approval page may be gone (its link is not kept), so
      // the way out is said while Start again is offered.
      expect(find.text('Approve the access on last.fm, then come back and '
          'tap Finish connecting. If that page is no longer open, tap Start '
          'again.'), findsOneWidget);
      expect(find.text('Finish connecting'), findsOneWidget);
      expect(find.text('Start again'), findsOneWidget);
      await tester.tap(byKey('integrations.finish'));
      await tester.pump();
      await tester.tap(byKey('integrations.connect'));
      await tester.pump();
      expect(fake.calls, ['finish', 'connect']);
      expect(byKey('integrations.disconnect'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('reconnect', () {
    testWidgets('the prompt and Reconnect', (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'enabled', needsReconnect: true),
      );
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.reconnect'), findsOneWidget);
      expect(find.text('Last.fm no longer accepts this connection. Reconnect '
          'to keep scrobbling.'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
      await tester.tap(byKey('integrations.connect'));
      await tester.pump();
      expect(fake.calls, ['connect']);
      await teardownTree(tester);
    });

    testWidgets('a healthy connection has no Connect and no prompt',
        (tester) async {
      final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.connect'), findsNothing);
      expect(byKey('integrations.reconnect'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('server stopped', () {
    for (final state in ['not_connected', 'enabled']) {
      testWidgets('shows the stopped text with no cause ($state)',
          (tester) async {
        final fake = FakeIntegrationsControls.known(
          status(service: 'stopped', state: state),
        );
        await pumpIntegrations(tester, fake);
        expect(find.text(_stopped), findsOneWidget);
        expect(byKey('integrations.stopped'), findsOneWidget);
        expect(byKey('integrations.connect'), findsNothing);
        await teardownTree(tester);
      });
    }

    testWidgets('running: no stopped text', (tester) async {
      final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
      await pumpIntegrations(tester, fake);
      expect(find.text(_stopped), findsNothing);
      await teardownTree(tester);
    });
  });

  group('block says available: false', () {
    testWidgets('connected: turned off, status and Disconnect only',
        (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'enabled'),
        available: false,
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(lastfmProblemText(LastfmProblem.disabled)),
          findsOneWidget);
      expect(byKey('integrations.disconnect'), findsOneWidget);
      expect(byKey('integrations.connect'), findsNothing);
      expect(byKey('integrations.finish'), findsNothing);
      expect(byKey('integrations.optIn.confirm'), findsNothing);
      expect(find.textContaining('listener_01'), findsWidgets);
      await teardownTree(tester);
    });

    testWidgets('connected, not opted in: still no opt-in', (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'connected_disabled'),
        available: false,
      );
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.optIn.confirm'), findsNothing);
      expect(byKey('integrations.disconnect'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('not connected: nothing to do', (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'not_connected', needsReconnect: null, account: null),
        available: false,
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(lastfmProblemText(LastfmProblem.disabled)),
          findsOneWidget);
      expect(byKey('integrations.connect'), findsNothing);
      expect(byKey('integrations.disconnect'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('messages', () {
    testWidgets("the controller's message is shown", (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'awaiting_authorization', needsReconnect: null,
            account: null),
      );
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.message'), findsNothing);
      fake.message = lastfmProblemText(LastfmProblem.notAuthorizedYet);
      await tester.pump();
      expect(byKey('integrations.message'), findsOneWidget);
      expect(find.text(lastfmProblemText(LastfmProblem.notAuthorizedYet)),
          findsOneWidget);
      await teardownTree(tester);
    });

    for (final load in [
      IntegrationsLoad.failed,
      IntegrationsLoad.notOffered,
      IntegrationsLoad.unreachable,
    ]) {
      testWidgets('the message row shows in the ${load.name} view',
          (tester) async {
        final fake = FakeIntegrationsControls(IntegrationsView(load: load));
        await pumpIntegrations(tester, fake);
        expect(byKey('integrations.message'), findsNothing);
        fake.message = 'Last action said this.';
        await tester.pump();
        expect(byKey('integrations.message'), findsOneWidget);
        expect(find.text('Last action said this.'), findsOneWidget);
        await teardownTree(tester);
      });
    }

    testWidgets('no message row when the controller has no message',
        (tester) async {
      for (final load in [
        IntegrationsLoad.failed,
        IntegrationsLoad.notOffered,
        IntegrationsLoad.unreachable,
      ]) {
        final fake = FakeIntegrationsControls(IntegrationsView(load: load));
        await pumpIntegrations(tester, fake);
        expect(byKey('integrations.message'), findsNothing);
        await teardownTree(tester);
      }
    });

    testWidgets('an unknown account state says so; Disconnect stays',
        (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(state: 'something_new', needsReconnect: null, account: null),
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(lastfmProblemText(LastfmProblem.badAnswer)),
          findsOneWidget);
      expect(byKey('integrations.disconnect'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('review r1', () {
    const awaitingNote = 'Approve the access on last.fm, then come back and '
        'tap Finish connecting.';

    // #1: a reconnect waiting for its approval shows Finish and the note.
    testWidgets('a reconnect waiting for its approval offers Finish',
        (tester) async {
      final fake = FakeIntegrationsControls.known(lastfmStatus(
        needsReconnect: true,
        connectionId: 'c-1',
        approvalExpiresAt: 1800000600000,
        counts: null,
      ));
      await pumpIntegrations(tester, fake);
      expect(find.text(awaitingNote), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
      // No Start again button here, so it is not asked for.
      expect(find.text('Start again'), findsNothing);
      expect(find.textContaining('tap Start again'), findsNothing);
      await tester.tap(byKey('integrations.finish'));
      await tester.pump();
      expect(fake.calls, ['finish']);
      await teardownTree(tester);
    });

    // #5: no "tap Finish connecting" when Finish is not offered.
    for (final (label, view) in [
      ('offline', knownView(
          status(state: 'awaiting_authorization', needsReconnect: null,
              account: null),
          online: false)),
      ('turned off', knownView(
          status(state: 'awaiting_authorization', needsReconnect: null,
              account: null),
          available: false)),
      ('stopped', knownView(status(service: 'stopped',
          state: 'awaiting_authorization', needsReconnect: null,
          account: null))),
    ]) {
      testWidgets('awaiting, $label: the note does not ask for a missing '
          'button', (tester) async {
        final fake = FakeIntegrationsControls(view);
        await pumpIntegrations(tester, fake);
        expect(byKey('integrations.finish'), findsNothing);
        expect(find.text(awaitingNote), findsNothing);
        await teardownTree(tester);
      });
    }

    // #5: an unknown server state is said, not a blank page.
    testWidgets('an unknown server state says the answer is unusable',
        (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(service: 'rebooting', state: 'not_connected',
            needsReconnect: null, account: null),
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(lastfmProblemText(LastfmProblem.badAnswer)),
          findsOneWidget);
      await teardownTree(tester);
    });

    // #4: a misconfigured server (block off, service stopped) says stopped
    // only.
    testWidgets('block off and stopped: "stopped", not "turned off"',
        (tester) async {
      final fake = FakeIntegrationsControls.known(
        status(service: 'stopped', state: 'enabled'),
        available: false,
      );
      await pumpIntegrations(tester, fake);
      expect(find.text(_stopped), findsOneWidget);
      expect(find.text(lastfmProblemText(LastfmProblem.disabled)),
          findsNothing);
      expect(byKey('integrations.disconnect'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  testWidgets('the page creates its controller and disposes it on leave',
      (tester) async {
    final fake = FakeIntegrationsControls.known(status(state: 'enabled'));
    await pumpIntegrations(tester, fake);
    expect(fake.disposed, isFalse);
    await teardownTree(tester);
    expect(fake.disposed, isTrue);
  });
}
