// Phase 6A.2 (SC-26, 6-U10 busy in the page controller, 6-P04, 6-U03
// empty/failure paths): the collection detail controller turns Play and
// Shuffle into one LibraryActions call each, blocks duplicate submits while
// one is in flight, always clears busy, and explains an action that did not
// start, with Retry. It decides no rule: the outcome comes from the model.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/ui/collection_detail_controller.dart';
import 'package:frontend/ui/library_actions.dart';

import 'fake_library_actions.dart';

/// Play and Shuffle answer [next] (or throw [error]); with [gate] set they
/// wait for it.
class _GatedActions extends FakeLibraryActions {
  PlaybackOutcome next = const Accepted(1);
  Object? error;
  Completer<void>? gate;

  Future<PlaybackOutcome> _answer(String call) async {
    calls.add(call);
    final pending = gate;
    if (pending != null) await pending.future;
    final thrown = error;
    if (thrown != null) throw thrown;
    return next;
  }

  @override
  Future<PlaybackOutcome> play(LibraryScope collection) =>
      _answer('play ${FakeLibraryActions.describe(collection)}');

  @override
  Future<PlaybackOutcome> shuffle(LibraryScope collection) =>
      _answer('shuffle ${FakeLibraryActions.describe(collection)}');
}

void main() {
  const album = AlbumScope(artistId: 1, albumId: 2);
  late _GatedActions actions;
  late ProviderContainer container;

  setUp(() {
    actions = _GatedActions();
    container = ProviderContainer(overrides: [
      libraryActionsProvider.overrideWithValue(actions),
    ]);
  });

  tearDown(() => container.dispose());

  /// The controller for [scope], kept alive as a mounted page keeps it.
  CollectionDetailControls controls([LibraryScope scope = album]) {
    container.listen(collectionDetailControllerProvider(scope), (_, _) {});
    return container.read(collectionDetailControllerProvider(scope));
  }

  group('busy', () {
    test('Play calls LibraryActions.play once and is busy until it answers',
        () async {
      final c = controls();
      actions.gate = Completer<void>();
      final pending = c.play();
      expect(c.busy, isTrue);
      expect(actions.calls, ['play album(1,2)']);
      actions.gate!.complete();
      await pending;
      expect(c.busy, isFalse);
    });

    test('Shuffle calls LibraryActions.shuffle', () async {
      final c = controls(const ArtistScope(artistId: 4));
      await c.shuffle();
      expect(actions.calls, ['shuffle artist(4)']);
      expect(c.busy, isFalse);
    });

    test('a second Play or Shuffle while busy submits nothing', () async {
      final c = controls();
      actions.gate = Completer<void>();
      final first = c.play();
      await c.play();
      await c.shuffle();
      await c.retry();
      expect(actions.calls, ['play album(1,2)']);
      actions.gate!.complete();
      await first;
      await c.shuffle();
      expect(actions.calls, ['play album(1,2)', 'shuffle album(1,2)'],
          reason: 'a submit after the first settles is accepted');
    });

    test('busy clears after a Failed outcome', () async {
      final c = controls();
      actions.next = Failed(StateError('boom'));
      await c.play();
      expect(c.busy, isFalse);
    });

    test('busy clears when the action throws', () async {
      final c = controls();
      actions.error = StateError('membership read failed');
      await c.play();
      expect(c.busy, isFalse);
    });

    test('listeners hear busy start and end', () async {
      final c = controls();
      final seen = <bool>[];
      c.addListener(() => seen.add(c.busy));
      await c.play();
      expect(seen, [true, false]);
    });

    test('two surfaces on the same collection share one controller', () {
      final a = controls(const AlbumScope(artistId: 1, albumId: 2));
      final b = controls(const AlbumScope(artistId: 1, albumId: 2));
      final other = controls(const AlbumScope(artistId: 1, albumId: 3));
      expect(identical(a, b), isTrue);
      expect(identical(a, other), isFalse);
    });

    test('two surfaces on the same collection can not submit twice',
        () async {
      final a = controls(const AlbumScope(artistId: 1, albumId: 2));
      final b = controls(const AlbumScope(artistId: 1, albumId: 2));
      actions.gate = Completer<void>();
      final first = a.play();
      await b.shuffle();
      expect(actions.calls, ['play album(1,2)']);
      actions.gate!.complete();
      await first;
    });

    test('disposing the page mid-request is safe', () async {
      final c = controls();
      var notified = 0;
      c.addListener(() => notified++);
      actions.gate = Completer<void>();
      final pending = c.play();
      expect(notified, 1);
      container.dispose();
      container = ProviderContainer();
      actions.next = const RejectedEmpty();
      actions.gate!.complete();
      await expectLater(pending, completes);
      expect(notified, 1, reason: 'no notification after dispose');
    });
  });

  group('outcome to message', () {
    const failedCopy = "Couldn't start playback.";
    final cases = <(String, PlaybackOutcome, String?)>[
      ('Accepted', const Accepted(3), null),
      ('Superseded', const Superseded(), null),
      ('RejectedEmpty', const RejectedEmpty(), 'Nothing to play here right now.'),
      ('RejectedUnplayableOffline', const RejectedUnplayableOffline(),
          'Nothing here plays offline.'),
      ('Failed', Failed(StateError('x')), failedCopy),
    ];
    for (final (label, outcome, copy) in cases) {
      test('$label → ${copy ?? 'no message'}', () async {
        final c = controls();
        actions.next = outcome;
        await c.play();
        expect(c.message, copy);
        expect(c.canRetry, copy != null);
      });
    }

    test('a thrown error reads as a failure', () async {
      final c = controls();
      actions.error = StateError('membership read failed');
      await c.shuffle();
      expect(c.message, failedCopy);
      expect(c.canRetry, isTrue);
    });

    test('a new action clears the old message when it starts', () async {
      final c = controls();
      actions.next = const RejectedEmpty();
      await c.play();
      expect(c.message, isNotNull);
      actions.next = const Accepted(4);
      actions.gate = Completer<void>();
      final pending = c.play();
      expect(c.message, isNull);
      actions.gate!.complete();
      await pending;
      expect(c.message, isNull);
      expect(c.canRetry, isFalse);
    });
  });

  group('retry', () {
    test('Retry re-runs the action that failed (Shuffle stays Shuffle)',
        () async {
      final c = controls();
      actions.next = Failed(StateError('x'));
      await c.shuffle();
      actions.next = const Accepted(5);
      await c.retry();
      expect(actions.calls, ['shuffle album(1,2)', 'shuffle album(1,2)']);
      expect(c.message, isNull);
      expect(c.canRetry, isFalse);
    });

    test('Retry re-runs a Play that found nothing playable offline',
        () async {
      final c = controls();
      actions.next = const RejectedUnplayableOffline();
      await c.play();
      await c.retry();
      expect(actions.calls, ['play album(1,2)', 'play album(1,2)']);
    });

    test('Retry with nothing to retry submits nothing', () async {
      final c = controls();
      await c.retry();
      await c.play(); // accepted: nothing to retry afterwards either
      await c.retry();
      expect(actions.calls, ['play album(1,2)']);
    });
  });
}
