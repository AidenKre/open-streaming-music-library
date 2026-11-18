// Phase 6A.2 (spec §5 placement, 6-U09 detail half, SC-26): the in-body
// Play / Shuffle header renders what its controller and the shared
// availability predicate say, and forwards taps only to the controller.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/collection_detail_controller.dart';
import 'package:frontend/ui/widgets/collection_action_header.dart';

import '../browse_harness.dart' show teardownTree;
import '../fake_collection_detail_controls.dart';

void main() {
  const album = AlbumScope(artistId: 1, albumId: 2);
  const artist = ArtistScope(artistId: 1);
  const online = PlaybackAvailability.unknown(offline: false);

  late FakeCollectionDetailControls controls;
  late List<LibraryScope> controllerScopes;

  setUp(() {
    controls = FakeCollectionDetailControls();
    controllerScopes = [];
  });

  Future<void> pump(
    WidgetTester tester, {
    LibraryScope scope = album,
    PlaybackAvailability availability = online,
    bool empty = false,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        collectionDetailControllerProvider.overrideWith((ref, s) {
          controllerScopes.add(s);
          return controls;
        }),
        playbackAvailabilityProvider.overrideWith((ref, s) => availability),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: CollectionActionHeader(scope: scope, empty: empty),
        ),
      ),
    ));
  }

  Finder playButton([String noun = 'album']) =>
      find.bySemanticsLabel('Play $noun');
  Finder shuffleButton([String noun = 'album']) =>
      find.bySemanticsLabel('Shuffle $noun');

  void expectEnabled(WidgetTester tester, Finder button, bool enabled) {
    expect(button, findsOneWidget);
    expect(tester.getSemantics(button),
        isSemantics(isButton: true, isEnabled: enabled, hasTapAction: enabled));
  }

  testWidgets('online: Play and Shuffle are enabled and reach the controller',
      (tester) async {
    await pump(tester,
        availability: PlaybackAvailability.of(
            offline: false, downloaded: 0, total: 3));
    expectEnabled(tester, playButton(), true);
    expectEnabled(tester, shuffleButton(), true);
    await tester.tap(playButton());
    await tester.tap(shuffleButton());
    await tester.pump();
    expect(controls.calls, ['play', 'shuffle']);
    expect(controllerScopes.toSet(), {album},
        reason: 'the controller of this collection');
    await teardownTree(tester);
  });

  testWidgets('the labels name an artist for an artist', (tester) async {
    await pump(tester, scope: artist);
    expectEnabled(tester, playButton('artist'), true);
    expectEnabled(tester, shuffleButton('artist'), true);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Shuffle'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('offline with nothing downloaded: disabled, with the reason',
      (tester) async {
    await pump(tester,
        availability:
            PlaybackAvailability.of(offline: true, downloaded: 0, total: 3));
    expectEnabled(tester, playButton(), false);
    expectEnabled(tester, shuffleButton(), false);
    expect(find.text('Nothing here plays offline.'), findsOneWidget);
    await tester.tap(playButton(), warnIfMissed: false);
    await tester.pump();
    expect(controls.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('offline with a partial download: enabled (O2)',
      (tester) async {
    await pump(tester,
        availability:
            PlaybackAvailability.of(offline: true, downloaded: 1, total: 3));
    expectEnabled(tester, playButton(), true);
    expectEnabled(tester, shuffleButton(), true);
    expect(find.text('Nothing here plays offline.'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('offline while the counts load: disabled and loading, '
      'never "nothing downloaded"', (tester) async {
    await pump(tester,
        availability: const PlaybackAvailability.unknown(offline: true));
    expectEnabled(tester, playButton(), false);
    expectEnabled(tester, shuffleButton(), false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Nothing here plays offline.'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('busy: both disabled with a progress indicator', (tester) async {
    controls.set(busy: true);
    await pump(tester);
    expectEnabled(tester, playButton(), false);
    expectEnabled(tester, shuffleButton(), false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(shuffleButton(), warnIfMissed: false);
    await tester.pump();
    expect(controls.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('follows the controller: busy, then idle again',
      (tester) async {
    await pump(tester);
    expectEnabled(tester, playButton(), true);
    controls.set(busy: true);
    await tester.pump();
    expectEnabled(tester, playButton(), false);
    controls.set(busy: false);
    await tester.pump();
    expectEnabled(tester, playButton(), true);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('an empty collection: disabled, with a short explanation',
      (tester) async {
    await pump(tester, empty: true);
    expectEnabled(tester, playButton(), false);
    expectEnabled(tester, shuffleButton(), false);
    expect(find.text('No tracks to play.'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('a message shows with Retry, which reaches the controller',
      (tester) async {
    controls.set(message: "Couldn't start playback.", canRetry: true);
    await pump(tester);
    expect(find.text("Couldn't start playback."), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    expect(controls.calls, ['retry']);
    expectEnabled(tester, playButton(), true);
    await teardownTree(tester);
  });

  testWidgets('a message without retry offers no Retry', (tester) async {
    controls.set(message: 'Nothing to play here right now.', canRetry: false);
    await pump(tester);
    expect(find.text('Nothing to play here right now.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('no message, no Retry', (tester) async {
    await pump(tester);
    expect(find.text('Retry'), findsNothing);
    await teardownTree(tester);
  });
  // Review R1-2/R1-3 (round 1).
  testWidgets('offline, an empty narrowed grid with nothing playable says '
      'why it can not play, not "no tracks"', (tester) async {
    await pump(tester,
        empty: true,
        availability:
            PlaybackAvailability.of(offline: true, downloaded: 0, total: 5));
    expect(find.text('Nothing here plays offline.'), findsOneWidget);
    expect(find.text('No tracks to play.'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('Retry is disabled when the collection can not play',
      (tester) async {
    controls.set(message: 'Nothing here plays offline.', canRetry: true);
    await pump(tester,
        availability:
            PlaybackAvailability.of(offline: true, downloaded: 0, total: 3));
    final retry = find.widgetWithText(TextButton, 'Retry');
    expect(retry, findsOneWidget);
    expect(tester.widget<TextButton>(retry).onPressed, isNull);
    await tester.tap(retry, warnIfMissed: false);
    await tester.pump();
    expect(controls.calls, isEmpty);
    await teardownTree(tester);
  });

  testWidgets('Retry is disabled for an empty collection', (tester) async {
    controls.set(message: 'Nothing to play here right now.', canRetry: true);
    await pump(tester, empty: true);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Retry'))
            .onPressed,
        isNull);
    await teardownTree(tester);
  });
}
