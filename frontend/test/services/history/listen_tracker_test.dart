import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/services/history/listen_tracker.dart';

const _s = 1000000;

void main() {
  late ListenTracker tracker;
  var sequence = 0;
  final closed = <ListenOccurrence>[];
  ListenOccurrence? current;
  var checkpoints = 0;

  setUp(() {
    tracker = ListenTracker();
    sequence = 0;
    closed.clear();
    current = null;
    checkpoints = 0;
  });

  EngineSourceIdentity id(int item,
          {int source = 0, int session = 1, String? uuid}) =>
      EngineSourceIdentity(
          sourceId: source == 0 ? item * 10 : source,
          sessionId: session,
          itemId: item,
          trackUuid: uuid ?? 't$item');

  /// One observation at [t] seconds monotonic, [pos] seconds position.
  void obs(double t, double pos,
      {int item = 1,
      int? source,
      int session = 1,
      bool playing = true,
      EngineProcessingState state = EngineProcessingState.ready,
      PlaybackTransitionCause? cause,
      bool uncertain = false,
      int runtime = 1,
      Duration? duration,
      String? uuid,
      int? seq}) {
    final update = tracker.observe(
      PlaybackObservation(
        runtimeId: runtime,
        sequence: seq ?? ++sequence,
        playlistRevision: 1,
        source: id(item, source: source ?? 0, session: session, uuid: uuid),
        position: Duration(microseconds: (pos * _s).round()),
        duration: duration,
        playing: playing,
        processingState: state,
        transitionCause: cause,
        rate: 1.0,
        uncertain: uncertain,
      ),
      monotonicMicros: (t * _s).round(),
      nowUtcMs: 1800000000000 + (t * 1000).round(),
    );
    if (update.closed != null) closed.add(update.closed!);
    current = update.current;
    if (update.checkpoint) checkpoints++;
  }

  test('steady playback credits one listen', () {
    for (var i = 0; i <= 4; i++) {
      obs(i.toDouble(), i.toDouble());
    }
    expect(current!.creditedMicros, 4 * _s);
    expect(current!.trackUuid, 't1');
    expect(current!.startedAtUtcMs, 1800000000000);
    expect(closed, isEmpty);
  });

  test('4 s play + 20 s paused + 3 s play is one 7 s listen', () {
    for (var i = 0; i <= 4; i++) {
      obs(i.toDouble(), i.toDouble());
    }
    obs(4.0, 4.0, playing: false); // pause: checkpoint, no close
    expect(checkpoints, 1);
    obs(24.0, 4.0); // resume
    for (var i = 1; i <= 3; i++) {
      obs(24.0 + i, 4.0 + i);
    }
    expect(closed, isEmpty);
    expect(current!.creditedMicros, 7 * _s);
  });

  test('a user seek re-anchors the same listen; the jump is not credited',
      () {
    for (var i = 0; i <= 4; i++) {
      obs(i.toDouble(), i.toDouble());
    }
    obs(4.0, 60.0, cause: PlaybackTransitionCause.userSeek);
    obs(5.0, 61.0);
    obs(6.0, 62.0);
    expect(closed, isEmpty);
    expect(current!.creditedMicros, 6 * _s);
  });

  test('a backward seek keeps counting what is played again', () {
    for (var i = 0; i <= 10; i++) {
      obs(i.toDouble(), i.toDouble());
    }
    obs(10, 2, cause: PlaybackTransitionCause.userSeek);
    obs(11, 3);
    obs(12, 4);
    obs(13, 5);
    expect(current!.creditedMicros, 13 * _s,
        reason: 'replay counts; the total may exceed the track length');
  });

  test('moving to another item closes the listen once', () {
    obs(0, 0);
    obs(3, 3);
    obs(3, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
    obs(4, 1, item: 2);
    expect(closed.single.itemId, 1);
    expect(closed.single.creditedMicros, 3 * _s);
    expect(current!.itemId, 2);
    expect(current!.creditedMicros, 1 * _s);
  });

  test('two natural repeat-one loops are two listens', () {
    obs(0, 0);
    obs(10, 10);
    obs(10, 0, cause: PlaybackTransitionCause.repeatOneRestart);
    obs(20, 10);
    obs(20, 0, cause: PlaybackTransitionCause.repeatOneRestart);
    expect(closed.map((l) => l.creditedMicros), [10 * _s, 10 * _s]);
    expect(closed[0].generation, isNot(closed[1].generation));
  });

  test('same-item rebuilds and edits continue the listen', () {
    obs(0, 0);
    obs(2, 2);
    obs(2, 2, source: 99, cause: PlaybackTransitionCause.qualityRebuild);
    obs(3, 3, source: 99);
    obs(3, 3, cause: PlaybackTransitionCause.queueEdit, source: 99);
    obs(4, 4, source: 99);
    obs(4, 4, cause: PlaybackTransitionCause.reconcileContinuation, source: 77);
    obs(5, 5, source: 77);
    expect(closed, isEmpty);
    expect(current!.creditedMicros, 5 * _s);
  });

  test('uncertain observations are never credited', () {
    obs(0, 0);
    obs(2, 2);
    obs(3, 3, uncertain: true);
    obs(4, 4, uncertain: true);
    obs(5, 5); // settled again: re-anchored here
    obs(6, 6);
    expect(current!.creditedMicros, 3 * _s, reason: '0→2, then 5→6');
  });

  test('completion closes once; a duplicate completion is a no-op', () {
    obs(0, 0);
    obs(5, 5);
    obs(5, 5, state: EngineProcessingState.completed);
    obs(5, 5, state: EngineProcessingState.completed);
    expect(closed.single.creditedMicros, 5 * _s);
    expect(current, isNull);
  });

  test('stop closes the listen', () {
    obs(0, 0);
    obs(2, 2);
    obs(2, 2, playing: false, cause: PlaybackTransitionCause.stop);
    expect(closed.single.creditedMicros, 2 * _s);
  });

  test('an item left without progress produces no listen', () {
    obs(0, 0);
    obs(0, 0, item: 2, cause: PlaybackTransitionCause.userSkip);
    expect(closed, isEmpty);
  });

  test('buffering while playing credits nothing while it lasts', () {
    obs(0, 0);
    obs(2, 2);
    obs(2, 2, state: EngineProcessingState.buffering);
    obs(10, 2, state: EngineProcessingState.buffering);
    obs(10, 2);
    obs(11, 3);
    expect(current!.creditedMicros, 3 * _s);
  });

  test('observations of a replaced runtime are dropped; a new one closes',
      () {
    obs(0, 0, runtime: 2);
    obs(3, 3, runtime: 2);
    obs(4, 50, runtime: 1); // stale engine instance
    expect(current!.creditedMicros, 3 * _s);
    obs(4, 0, runtime: 3);
    expect(closed.single.creditedMicros, 3 * _s);
  });

  test('the track length is the first known duration', () {
    obs(0, 0);
    obs(1, 1, duration: const Duration(seconds: 200));
    obs(2, 2, duration: const Duration(seconds: 201));
    expect(current!.trackLength, const Duration(seconds: 200));
  });

  test('review: a zero duration is not a known length; a later real one is',
      () {
    obs(0, 0, duration: Duration.zero);
    obs(1, 1, duration: const Duration(seconds: 200));
    expect(current!.trackLength, const Duration(seconds: 200));
  });

  group('PR 5B audit (a)', () {
    test('the final sample before completion or stop is credited', () {
      for (final end in ['completed', 'stop']) {
        tracker = ListenTracker();
        closed.clear();
        obs(0, 0);
        obs(1, 1);
        if (end == 'completed') {
          obs(3, 3, state: EngineProcessingState.completed);
        } else {
          obs(3, 3, cause: PlaybackTransitionCause.stop);
        }
        expect(closed.single.creditedMicros, 3 * _s, reason: end);
      }
    });

    test('a skip back onto the same item starts a new listen', () {
      obs(0, 0);
      obs(100, 100);
      obs(100, 0, cause: PlaybackTransitionCause.userSkip); // a one-item wrap
      obs(150, 50);
      expect(closed.map((o) => o.creditedMicros), [100 * _s]);
      expect(current!.creditedMicros, 50 * _s);
      expect(current!.generation, isNot(closed.single.generation));
    });

    test('a natural advance that wraps onto the same item is a new listen',
        () {
      obs(0, 0);
      obs(30, 30);
      obs(30, 0, cause: PlaybackTransitionCause.naturalAdvance); // repeat-all
      obs(40, 10);
      expect(closed.map((o) => o.creditedMicros), [30 * _s]);
      expect(current!.creditedMicros, 10 * _s);
    });

    test('a rebase settles twice on its target: one listen, not two', () {
      obs(0, 0);
      obs(3, 3);
      // The reseed settles on B first, then the seek onto B settles again.
      obs(3, 0, item: 2, cause: PlaybackTransitionCause.userSkip);
      obs(3.2, 0.2, item: 2);
      obs(3.4, 0.4, item: 2);
      obs(3.4, 0, item: 2, cause: PlaybackTransitionCause.userSkip);
      obs(5.4, 2, item: 2);
      expect(closed.map((o) => o.itemId), [1], reason: 'no tiny play of B');
      expect(current!.itemId, 2);
      expect(current!.creditedMicros, (2.4 * _s).round());
    });

    test('a same-item settle mid-track (a failed seek fell back) continues',
        () {
      obs(0, 0);
      obs(60, 60);
      obs(60, 60, cause: PlaybackTransitionCause.naturalAdvance);
      obs(70, 70);
      expect(closed, isEmpty);
      expect(current!.creditedMicros, 70 * _s);
    });

    test('distinct queue items sharing a track UUID are two listens', () {
      // Short enough that only item identity (not the wrap rule) closes it.
      obs(0, 0, uuid: 'tX');
      obs(1.5, 1.5, uuid: 'tX');
      obs(1.5, 0, item: 2, uuid: 'tX',
          cause: PlaybackTransitionCause.naturalAdvance);
      obs(3.5, 2, item: 2, uuid: 'tX');
      expect(closed.single.itemId, 1);
      expect(closed.single.creditedMicros, (1.5 * _s).round());
      expect(current!.itemId, 2);
      expect(current!.creditedMicros, 2 * _s);
    });

    test('the same item id in a new session is a new listen', () {
      obs(0, 0);
      obs(3, 3);
      obs(3, 0, session: 2, cause: PlaybackTransitionCause.queueReplacement);
      obs(4, 1, session: 2);
      expect(closed.single.sessionId, 1);
      expect(current!.sessionId, 2);
      expect(current!.generation, isNot(closed.single.generation));
    });

    test('a source refresh keeps the listen and re-anchors (no backward '
        'credit, no jump credit)', () {
      obs(0, 0);
      obs(10, 10);
      obs(10, 8, cause: PlaybackTransitionCause.sourceRefresh);
      obs(12, 10);
      expect(closed, isEmpty);
      expect(current!.creditedMicros, 12 * _s);
    });

    test('an out-of-order (older sequence) observation is ignored', () {
      obs(0, 0, seq: 1);
      obs(3, 3, seq: 2);
      obs(3, 0, item: 2, cause: PlaybackTransitionCause.naturalAdvance,
          seq: 5);
      obs(3.5, 2.9, seq: 4); // item 1, delivered late
      obs(5, 2, item: 2, seq: 6);
      expect(closed.map((o) => o.itemId), [1]);
      expect(current!.itemId, 2);
      expect(current!.creditedMicros, 2 * _s);
    });

    test('bursts at one monotonic time and progress delayed past a pause '
        'credit nothing extra', () {
      obs(0, 0);
      obs(2, 2);
      obs(2, 2);
      obs(2, 2.5); // burst: no elapsed time, no credit
      obs(2, 2.5, playing: false); // paused
      obs(30, 2.5); // resumed after 28 s
      obs(31, 3.5);
      expect(current!.creditedMicros, 3 * _s);
    });

    test('an auto-advance whose first observation has a stale position is '
        'credited (live gate, macOS)', () {
      obs(0, 0);
      obs(5, 5);
      obs(5, 45, item: 2, cause: PlaybackTransitionCause.naturalAdvance);
      obs(5.1, 45, item: 2); // still stale
      obs(5.3, 0.2, item: 2);
      obs(8.3, 3.2, item: 2);
      expect(closed.single.creditedMicros, 5 * _s);
      expect(current!.creditedMicros, greaterThanOrEqualTo((2.9 * _s).round()));
      expect(current!.creditedMicros, lessThanOrEqualTo((3.3 * _s).round()));
    });

    test('branch audit M3: a stray tick near 0 before the repeat-one restart '
        'keeps the loop\'s credit', () {
      obs(0, 0);
      obs(10, 10);
      obs(10.05, 0.05); // the next loop's tick, delivered first
      obs(10.06, 0, cause: PlaybackTransitionCause.repeatOneRestart);
      expect(closed.single.creditedMicros, 10 * _s);
    });

    test('branch audit: a stall is settled by the buffering observation '
        '(live A06 trace)', () {
      obs(0, 0);
      obs(7.76, 7.76); // extrapolated while stalled
      obs(8, 3.77, state: EngineProcessingState.buffering); // real position
      expect(current!.creditedMicros, (3.77 * _s).round());
      expect(checkpoints, greaterThan(0));
    });

    test('a listen starts when audio starts, not when a paused item is '
        'restored', () {
      obs(0, 0, playing: false); // restored paused at t=0
      obs(3600, 0); // play pressed an hour later
      obs(3602, 2);
      expect(current!.startedAtUtcMs, 1800000000000 + 3600 * 1000);
      expect(current!.creditedMicros, 2 * _s);
    });
  });
}
