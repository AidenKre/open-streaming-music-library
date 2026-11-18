// Phase 9D.2e S6: the opt-in confirmation.
//  * Spec §7.5: "After a successful Complete the client shows the account
//    name and asks for explicit confirmation before anything is sent. The
//    confirmation screen states all of the following in plain words." The
//    seven points, quoted in the page's own words below; point 2 "link
//    both" (terms and privacy policy).
//  * Spec §7.5: "Where it names the application the user approved on
//    last.fm, it uses the name the operator registered there." The server
//    sends the operator's LASTFM_APP_NAME as the status `app_name`
//    (DEV-9-06, signoff-9-lastfm-app-name): when it is provided, points 1, 6
//    and 7 name the application (plain text, quoted); when it is not (unset,
//    implausible, or an older server that sends no field), the wording stays
//    "the application you approved on last.fm", exactly as before.
//  * Enable is sent only on the explicit tap (`enable` through the
//    controller).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../browse_harness.dart' show teardownTree;
import 'fake_integrations_controls.dart';

const _points = <(String, String)>[
  (
    'What is sent',
    'For each listen that counts: the artist, title, album, album artist, '
        'track length and the time it started; and, while you listen online, '
        'the track that is playing now. No files, no list of your library, '
        'and not your OSML username. Last.fm also sees this server’s network '
        'address and the application you approved on last.fm, which belongs '
        'to whoever runs this server.',
  ),
  (
    'Where it goes',
    'To the Last.fm profile listener_01, visible according to that '
        'account’s Last.fm privacy settings. Last.fm’s own terms and privacy '
        'policy apply.',
  ),
  (
    'Which listens',
    'Only listens the server receives after you confirm, including one made '
        'earlier on an offline device that syncs later. Listens received '
        'while whoever runs this server has the integration switched off, or '
        'while this connection needs repairing, are never sent.',
  ),
  (
    'OSML can’t take it back',
    'Last.fm’s API cannot delete a scrobble. You remove it on last.fm.',
  ),
  (
    'Not every listen arrives',
    'OSML tries a few times and then gives up; Last.fm refuses some listens '
        '(for example ones older than about two weeks); occasionally one is '
        'recorded more than once. This page lists the ones that did not go '
        'through.',
  ),
  (
    'Who holds the access',
    'This server stores a key that gives whoever runs it write access to '
        'your Last.fm account through Last.fm’s API, until you disconnect '
        'here or remove the application under Last.fm settings → '
        'Applications.',
  ),
  (
    'How to stop',
    'Disconnect. It discards what is waiting, and coming back needs a new '
        'approval and a new confirmation. Removing the application on '
        'last.fm also stops it, until you reconnect.',
  ),
];

const _appName = 'OSML at Home';

/// The seven points when the operator's application name is provided: only
/// points 1, 6 and 7 change, by naming the application.
final _namedPoints = <(String, String)>[
  (
    'What is sent',
    'For each listen that counts: the artist, title, album, album artist, '
        'track length and the time it started; and, while you listen online, '
        'the track that is playing now. No files, no list of your library, '
        'and not your OSML username. Last.fm also sees this server’s network '
        'address and the application “$_appName” you approved on last.fm, '
        'which belongs to whoever runs this server.',
  ),
  _points[1],
  _points[2],
  _points[3],
  _points[4],
  (
    'Who holds the access',
    'This server stores a key that gives whoever runs it write access to '
        'your Last.fm account through Last.fm’s API, until you disconnect '
        'here or remove the application “$_appName” under Last.fm settings '
        '→ Applications.',
  ),
  (
    'How to stop',
    'Disconnect. It discards what is waiting, and coming back needs a new '
        'approval and a new confirmation. Removing the application '
        '“$_appName” on last.fm also stops it, until you reconnect.',
  ),
];

Future<void> _expectPoints(
  WidgetTester tester,
  List<(String, String)> points,
) async {
  for (final (i, (title, body)) in points.indexed) {
    final point = byKey('integrations.optIn.point.${i + 1}');
    expect(point, findsOneWidget, reason: title);
    expect(find.descendant(of: point, matching: find.text(title)),
        findsOneWidget, reason: title);
    expect(find.descendant(of: point, matching: find.text(body)),
        findsOneWidget, reason: title);
  }
  expect(byKey('integrations.optIn.point.8'), findsNothing);
}

void main() {
  testWidgets('a provided application name is named in points 1, 6 and 7; '
      'all seven points stay', (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled', appName: _appName),
    );
    await pumpIntegrations(tester, fake);
    expect(find.text('Scrobble to listener_01?'), findsOneWidget);
    expect(find.text('Nothing is sent until you confirm.'), findsOneWidget);
    await _expectPoints(tester, _namedPoints);
    await teardownTree(tester);
  });

  testWidgets('no application name (an older server sends no field): '
      'today’s wording, unchanged', (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled'),
    );
    expect(fake.view.status!.appName, isNull);
    await pumpIntegrations(tester, fake);
    await _expectPoints(tester, _points);
    expect(find.textContaining('“'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('the name is plain text: markup is shown as typed, nothing '
      'becomes a link', (tester) async {
    const odd = '<b>bold</b> [link](https://e.example) *x*';
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled', appName: odd),
    );
    await pumpIntegrations(tester, fake);
    for (final n in [1, 6, 7]) {
      expect(
        find.descendant(
          of: byKey('integrations.optIn.point.$n'),
          matching: find.textContaining('the application “$odd”'),
        ),
        findsOneWidget,
        reason: 'point $n',
      );
    }
    // Only the terms and privacy links are tappable on the screen.
    expect(
      find.descendant(
        of: byKey('integrations.optIn'),
        matching: find.byType(TextButton),
      ),
      findsNWidgets(2),
    );
    await teardownTree(tester);
  });

  testWidgets('a 100-character name without spaces wraps in a narrow window '
      'without overflowing', (tester) async {
    final long = 'W' * 100;
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled', appName: long),
    );
    await pumpIntegrations(tester, fake);
    tester.view.physicalSize = const Size(320, 4000);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: byKey('integrations.optIn.point.6'),
        matching: find.textContaining('the application “$long”'),
      ),
      findsOneWidget,
    );
    await teardownTree(tester);
  });

  testWidgets('names the account and states all seven points', (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled'),
    );
    await pumpIntegrations(tester, fake);
    expect(byKey('integrations.optIn'), findsOneWidget);
    expect(find.text('Scrobble to listener_01?'), findsOneWidget);
    expect(find.text('Nothing is sent until you confirm.'), findsOneWidget);
    for (final (i, (title, body)) in _points.indexed) {
      final point = byKey('integrations.optIn.point.${i + 1}');
      expect(point, findsOneWidget, reason: title);
      expect(find.descendant(of: point, matching: find.text(title)),
          findsOneWidget, reason: title);
      expect(find.descendant(of: point, matching: find.text(body)),
          findsOneWidget, reason: title);
    }
    expect(byKey('integrations.optIn.point.8'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('the name in point 2 is the connected account', (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled', account: 'Some One'),
    );
    await pumpIntegrations(tester, fake);
    expect(find.text('Scrobble to Some One?'), findsOneWidget);
    expect(
      find.descendant(
        of: byKey('integrations.optIn.point.2'),
        matching: find.textContaining('To the Last.fm profile Some One, '),
      ),
      findsOneWidget,
    );
    await teardownTree(tester);
  });

  testWidgets('point 2 links the terms and the privacy policy',
      (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled'),
    );
    await pumpIntegrations(tester, fake);
    expect(find.text('Last.fm Terms of Use'), findsOneWidget);
    expect(find.text('Last.fm Privacy Policy'), findsOneWidget);
    await tester.tap(byKey('integrations.terms'));
    await tester.pump();
    await tester.tap(byKey('integrations.privacy'));
    await tester.pump();
    expect(fake.calls, ['openTerms', 'openPrivacy']);
    await teardownTree(tester);
  });

  testWidgets('nothing is sent until Start scrobbling is tapped',
      (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled'),
    );
    await pumpIntegrations(tester, fake);
    expect(fake.calls, isEmpty);
    expect(find.text('Start scrobbling'), findsOneWidget);
    await tester.tap(byKey('integrations.optIn.confirm'));
    await tester.pump();
    expect(fake.calls, ['enable']);
    await teardownTree(tester);
  });

  testWidgets('busy: Start scrobbling is disabled', (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled'),
    )..busy = true;
    await pumpIntegrations(tester, fake);
    await tester.tap(byKey('integrations.optIn.confirm'), warnIfMissed: false);
    await tester.pump();
    expect(fake.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('no opt-in when it is not offered (offline, enabled, needs '
      'reconnect, no name)', (tester) async {
    for (final fake in [
      FakeIntegrationsControls.known(status(state: 'connected_disabled'),
          online: false),
      FakeIntegrationsControls.known(status(state: 'enabled')),
      FakeIntegrationsControls.known(
          status(state: 'connected_disabled', needsReconnect: true)),
      FakeIntegrationsControls.known(
          status(state: 'connected_disabled', account: null)),
    ]) {
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.optIn'), findsNothing);
      expect(byKey('integrations.optIn.confirm'), findsNothing);
      await teardownTree(tester);
    }
  });

  testWidgets('connected, not opted in, without the opt-in: says so',
      (tester) async {
    final fake = FakeIntegrationsControls.known(
      status(state: 'connected_disabled'),
      online: false,
    );
    await pumpIntegrations(tester, fake);
    expect(find.text('Connected, not scrobbling yet.'), findsOneWidget);
    await teardownTree(tester);
  });
}
