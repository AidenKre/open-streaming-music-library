// Phase 9D.2e S5: the connected account on the Integrations page.
//  * Spec §7.12: "It shows ... the counts, the list of scrobbles that did
//    not go through with a plain reason for each". "The connected account's
//    name links to https://www.last.fm/user/<name>" (the link is built by
//    the model; the page forwards the tap).
//  * Spec §7.4: "counts cover the 30 days of rows that are kept";
//    "last_success_at is the newest done_at among the caller's sent rows".
//  * Unknown is not zero: a count the server did not give shows "Unknown",
//    never 0.
//  * The account name and the problem rows' artist/track are shown as plain
//    text, never interpreted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/ui/integrations/integrations_controller.dart';

import '../browse_harness.dart' show teardownTree;
import 'fake_integrations_controls.dart';
import '../../helpers/fake_lastfm_api.dart' show lastfmStatus;

LastfmStatus _status({
  String state = 'enabled',
  Object? counts = const {
    'pending': 3,
    'sent': 120,
    'ignored': 2,
    'failed': 1,
    'dropped': 4,
  },
  String? account = 'listener_01',
  int? lastSuccessAt,
}) => lastfmStatus(
  state: state,
  account: account,
  connectionId: 'c-1',
  counts: counts,
  lastSuccessAt: lastSuccessAt,
);

String _countText(WidgetTester tester, String kind) {
  final texts = tester
      .widgetList<Text>(find.descendant(
        of: byKey('integrations.count.$kind'),
        matching: find.byType(Text),
      ))
      .map((t) => t.data ?? '')
      .toList();
  return texts.join(' | ');
}

// 2026-07-01T12:00:00Z: the same year in every time zone.
const _midYear = 1782907200000;

void main() {
  group('the account', () {
    testWidgets('"Scrobbling to" the name; the name opens the profile',
        (tester) async {
      final fake = FakeIntegrationsControls.known(_status());
      await pumpIntegrations(tester, fake);
      expect(find.text('Scrobbling to'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('integrations.profile'),
          matching: find.text('listener_01'),
        ),
        findsOneWidget,
      );
      await tester.tap(byKey('integrations.profile'));
      await tester.pump();
      expect(fake.calls, ['openProfile']);
      await teardownTree(tester);
    });

    testWidgets('markup in a name is shown as plain text', (tester) async {
      const name = '<b>x</b>&amp;';
      final fake = FakeIntegrationsControls.known(_status(account: name));
      await pumpIntegrations(tester, fake);
      expect(find.text(name), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('no name known: no profile link', (tester) async {
      final fake = FakeIntegrationsControls.known(_status(account: null));
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.profile'), findsNothing);
      expect(find.text('your Last.fm account'), findsOneWidget);
      await teardownTree(tester);
    });
  });

  group('counts', () {
    testWidgets('each kind with its label and number', (tester) async {
      final fake = FakeIntegrationsControls.known(_status());
      await pumpIntegrations(tester, fake);
      expect(_countText(tester, 'pending'), 'Waiting | 3');
      expect(_countText(tester, 'sent'), 'Sent | 120');
      expect(_countText(tester, 'ignored'), 'Ignored | 2');
      expect(_countText(tester, 'failed'), 'Refused | 1');
      expect(_countText(tester, 'dropped'), 'Not sent | 4');
      expect(find.text('Counts cover the last 30 days.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('zero is 0', (tester) async {
      final fake = FakeIntegrationsControls.known(_status(counts: const {
        'pending': 0, 'sent': 0, 'ignored': 0, 'failed': 0, 'dropped': 0,
      }));
      await pumpIntegrations(tester, fake);
      expect(_countText(tester, 'sent'), 'Sent | 0');
      await teardownTree(tester);
    });

    testWidgets('a count the server did not give is Unknown, never 0',
        (tester) async {
      final fake = FakeIntegrationsControls.known(_status(counts: const {
        'pending': 1, 'sent': 'many', 'ignored': -1,
      }));
      await pumpIntegrations(tester, fake);
      expect(_countText(tester, 'pending'), 'Waiting | 1');
      expect(_countText(tester, 'sent'), 'Sent | Unknown');
      expect(_countText(tester, 'ignored'), 'Ignored | Unknown');
      expect(_countText(tester, 'failed'), 'Refused | Unknown');
      expect(_countText(tester, 'dropped'), 'Not sent | Unknown');
      await teardownTree(tester);
    });

    testWidgets('not connected: no counts', (tester) async {
      final fake = FakeIntegrationsControls.known(
        _status(state: 'not_connected', account: null),
      );
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.count.sent'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('last success', () {
    testWidgets('shown with its date when known', (tester) async {
      final fake = FakeIntegrationsControls.known(
        _status(lastSuccessAt: _midYear),
      );
      await pumpIntegrations(tester, fake);
      final line = byKey('integrations.lastSuccess');
      expect(line, findsOneWidget);
      expect(
        find.descendant(of: line, matching: find.textContaining('2026')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: line,
          matching: find.textContaining('Last went through: '),
        ),
        findsOneWidget,
      );
      await teardownTree(tester);
    });

    testWidgets('absent when not known', (tester) async {
      final fake = FakeIntegrationsControls.known(_status());
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.lastSuccess'), findsNothing);
      await teardownTree(tester);
    });
  });

  group('did not go through', () {
    testWidgets('each row: track, artist, date and the reason, in order',
        (tester) async {
      final fake = FakeIntegrationsControls.known(
        _status(),
        problems: const [
          IntegrationsProblemView(
            artist: 'Simon & Garfunkel',
            track: 'Don’t Know Why',
            listenedAt: _midYear,
            reason: 'Last.fm ignored it because of the artist name.',
          ),
          IntegrationsProblemView(
            artist: 'AC/DC',
            track: '東京',
            listenedAt: _midYear,
            reason: 'Not sent.',
          ),
        ],
      );
      await pumpIntegrations(tester, fake);
      expect(find.text("Didn't go through"), findsOneWidget);
      expect(byKey('integrations.problem.2'), findsNothing);
      for (final (i, (artist, track, reason)) in [
        ('Simon & Garfunkel', 'Don’t Know Why',
            'Last.fm ignored it because of the artist name.'),
        ('AC/DC', '東京', 'Not sent.'),
      ].indexed) {
        final row = byKey('integrations.problem.$i');
        expect(row, findsOneWidget);
        expect(find.descendant(of: row, matching: find.textContaining(track)),
            findsOneWidget);
        expect(find.descendant(of: row, matching: find.textContaining(artist)),
            findsOneWidget);
        expect(find.descendant(of: row, matching: find.text(reason)),
            findsOneWidget);
        expect(find.descendant(of: row, matching: find.textContaining('2026')),
            findsOneWidget);
      }
      await teardownTree(tester);
    });

    testWidgets('none: says so', (tester) async {
      final fake = FakeIntegrationsControls.known(_status());
      await pumpIntegrations(tester, fake);
      expect(byKey('integrations.problem.0'), findsNothing);
      expect(find.text('None in the last 30 days.'), findsOneWidget);
      await teardownTree(tester);
    });
  });
}
