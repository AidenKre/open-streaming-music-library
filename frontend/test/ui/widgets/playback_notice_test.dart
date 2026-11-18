// Owner decision 5 (2026-11-17), APP-OTHER-1 D5: a row tap whose playback
// does not start shows the existing playback message as a short notice at
// the bottom (a SnackBar); an accepted or superseded request shows nothing.
// The text comes from `playbackOutcomeMessage`, the one mapping.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/ui/widgets/playback_notice.dart';

void main() {
  /// Pumps a page with a messenger and a Scaffold; returns a context below
  /// them, as a row's tap handler has.
  Future<BuildContext> pumpPage(WidgetTester tester, {Key? key}) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            key: key,
            builder: (context) {
              captured = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  for (final outcome in const <PlaybackOutcome>[Accepted(1), Superseded()]) {
    testWidgets('$outcome shows no notice', (tester) async {
      final context = await pumpPage(tester);
      await showPlaybackOutcome(context, Future.value(outcome));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
    });
  }

  for (final (outcome, message) in <(PlaybackOutcome, String)>[
    (const RejectedEmpty(), 'Nothing to play here right now.'),
    (const RejectedUnplayableOffline(), 'Nothing here plays offline.'),
    (Failed(StateError('x')), "Couldn't start playback."),
  ]) {
    testWidgets('$outcome shows "$message" once as a notice', (tester) async {
      final context = await pumpPage(tester);
      await showPlaybackOutcome(context, Future.value(outcome));
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text(message),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsOneWidget);
    });
  }

  testWidgets('the row gone before the outcome lands: the notice still '
      'shows on the page messenger', (tester) async {
    final context = await pumpPage(tester, key: const ValueKey('row'));
    final pending = Completer<PlaybackOutcome>();
    final done = showPlaybackOutcome(context, pending.future);
    // The row's subtree is replaced; the messenger stays.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    expect(context.mounted, isFalse, reason: 'precondition');
    pending.complete(const Failed('gone'));
    await done;
    await tester.pump();
    expect(find.text("Couldn't start playback."), findsOneWidget);
  });
}
