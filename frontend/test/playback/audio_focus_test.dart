import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/playback/audio_focus.dart';

import '../helpers/fake_audio_focus.dart';

class RecordingOwner implements AudioFocusOwner {
  final calls = <String>[];

  @override
  void onInterruptionBegan() => calls.add('began');

  @override
  void onInterruptionEnded({required bool shouldResume}) =>
      calls.add('ended(resume: $shouldResume)');

  @override
  void onBecameNoisy() => calls.add('noisy');
}

void main() {
  late FakeAudioSessionPort port;
  late AudioFocus focus;
  late RecordingOwner owner;

  setUp(() {
    port = FakeAudioSessionPort();
    focus = AudioFocus(port);
    owner = RecordingOwner();
  });

  tearDown(() async {
    focus.dispose();
    await port.controller.close();
  });

  test('routes interruptions and noisy output to the owner', () async {
    focus.bind(AudioOutput.queue, owner);
    port
      ..emit(const AudioInterruptionBegan(AudioInterruptionKind.pause))
      ..emit(const AudioInterruptionEnded(AudioInterruptionKind.pause))
      ..emit(const AudioInterruptionBegan(AudioInterruptionKind.unknown))
      ..emit(const AudioInterruptionEnded(AudioInterruptionKind.unknown))
      ..emit(const AudioBecameNoisy());
    await pumpEventQueue();
    expect(owner.calls, [
      'began',
      'ended(resume: true)',
      'began',
      'ended(resume: false)',
      'noisy',
    ]);
  });

  test('ducking is not a pause (D27)', () async {
    focus.bind(AudioOutput.queue, owner);
    port
      ..emit(const AudioInterruptionBegan(AudioInterruptionKind.duck))
      ..emit(const AudioInterruptionEnded(AudioInterruptionKind.duck));
    await pumpEventQueue();
    expect(owner.calls, isEmpty);
  });

  test('events with no owner are dropped, never buffered', () async {
    port.emit(const AudioBecameNoisy());
    await pumpEventQueue();
    focus.bind(AudioOutput.queue, owner);
    await pumpEventQueue();
    expect(owner.calls, isEmpty);
    focus.release(AudioOutput.queue, owner);
    port.emit(const AudioBecameNoisy());
    await pumpEventQueue();
    expect(owner.calls, isEmpty);
  });

  test('a stale owner cannot release its successor', () async {
    final successor = RecordingOwner();
    focus.bind(AudioOutput.queue, owner);
    focus.bind(AudioOutput.queue, successor);
    focus.release(AudioOutput.queue, owner);
    port.emit(const AudioBecameNoisy());
    await pumpEventQueue();
    expect(owner.calls, isEmpty);
    expect(successor.calls, ['noisy']);
  });

  test('the bound owner may play; once released it may not', () async {
    focus.bind(AudioOutput.queue, owner);
    expect(await focus.beforePlay(AudioOutput.queue), isTrue);
    focus.release(AudioOutput.queue, owner);
    expect(await focus.beforePlay(AudioOutput.queue), isFalse,
        reason: 'no owner, no audio');
  });

  test('the session is subscribed once an owner binds', () async {
    expect(port.listens, 0);
    focus.bind(AudioOutput.queue, owner);
    focus.bind(AudioOutput.queue, RecordingOwner());
    expect(port.listens, 1);
  });

  group('7B.2a: acknowledged transfer between the queue and preview', () {
    late FakeTimers timers;
    late AudioFocus transfer;
    late RelinquishingOwner queue;
    late RelinquishingOwner preview;

    setUp(() {
      timers = FakeTimers();
      transfer = AudioFocus(port, timer: timers.create);
      queue = RelinquishingOwner('queue');
      preview = RelinquishingOwner('preview');
      transfer
        ..bind(AudioOutput.queue, queue)
        ..bind(AudioOutput.preview, preview);
    });

    tearDown(() => transfer.dispose());

    /// Gives [output] the output: the other (bound) output is asked to stop
    /// and acknowledges.
    Future<void> hold(AudioOutput output) async {
      final granted = transfer.acquire(output);
      await pumpEventQueue();
      (output == AudioOutput.queue ? preview : queue).acknowledge();
      expect(await granted, isTrue);
    }

    test('with nobody holding the output, the other output is still asked to '
        'stop first (its play may be queued behind a load)', () async {
      expect(transfer.holder, isNull);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      expect(queue.relinquishes, 1);
      expect(granted, isNull);
      expect(transfer.yieldedBy(AudioOutput.queue), isTrue);
      queue.acknowledge();
      await pumpEventQueue();
      expect(granted, isTrue);
      expect(transfer.holder, AudioOutput.preview);
    });

    test('with no other output bound, acquire grants at once', () async {
      transfer.release(AudioOutput.queue, queue);
      expect(await transfer.acquire(AudioOutput.preview), isTrue);
      expect(transfer.holder, AudioOutput.preview);
    });

    test('the library play choke point takes a free output at once', () async {
      transfer.release(AudioOutput.preview, preview);
      expect(await transfer.beforePlay(AudioOutput.queue), isTrue);
      expect(transfer.holder, AudioOutput.queue);
    });

    test('the holder plays again without asking anyone', () async {
      await hold(AudioOutput.queue);
      final asked = preview.relinquishes;
      expect(await transfer.beforePlay(AudioOutput.queue), isTrue);
      expect(await transfer.acquire(AudioOutput.queue), isTrue);
      expect(preview.relinquishes, asked);
    });

    test('acquiring from a holder waits for its acknowledgement', () async {
      await hold(AudioOutput.queue);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      expect(queue.relinquishes, 1, reason: 'the holder is asked to stop');
      expect(granted, isNull, reason: 'no grant before the acknowledgement');
      expect(transfer.holder, AudioOutput.queue);
      bool? mayPlay;
      unawaited(
          transfer.beforePlay(AudioOutput.preview).then((g) => mayPlay = g));
      await pumpEventQueue();
      expect(mayPlay, isNull,
          reason: 'preview may not sound before the library acknowledged');
      queue.acknowledge();
      await pumpEventQueue();
      expect(granted, isTrue);
      expect(mayPlay, isTrue);
      expect(transfer.holder, AudioOutput.preview);
      expect(await transfer.beforePlay(AudioOutput.preview), isTrue);
    });

    test('a play of the output being given away is refused (newest request '
        'wins), and does not supersede the transfer', () async {
      await hold(AudioOutput.queue);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      expect(await transfer.beforePlay(AudioOutput.queue), isFalse);
      queue.acknowledge();
      await pumpEventQueue();
      expect(granted, isTrue);
      expect(transfer.holder, AudioOutput.preview);
    });

    test('a library play while preview holds stops preview first', () async {
      await hold(AudioOutput.preview);
      bool? granted;
      unawaited(
          transfer.beforePlay(AudioOutput.queue).then((g) => granted = g));
      await pumpEventQueue();
      expect(preview.relinquishes, 1);
      expect(granted, isNull);
      preview.acknowledge();
      await pumpEventQueue();
      expect(granted, isTrue);
      expect(transfer.holder, AudioOutput.queue);
    });

    test('a second acquire of the same pending output joins it', () async {
      await hold(AudioOutput.queue);
      final answers = <bool>[];
      unawaited(transfer.acquire(AudioOutput.preview).then(answers.add));
      unawaited(transfer.acquire(AudioOutput.preview).then(answers.add));
      await pumpEventQueue();
      expect(queue.relinquishes, 1);
      queue.acknowledge();
      await pumpEventQueue();
      expect(answers, [true, true]);
    });

    test('a pending acquire is superseded by a newer one', () async {
      await hold(AudioOutput.preview);
      bool? library;
      unawaited(
          transfer.beforePlay(AudioOutput.queue).then((g) => library = g));
      await pumpEventQueue();
      expect(preview.relinquishes, 1);
      // Preview is asked to play again before it acknowledged.
      expect(await transfer.acquire(AudioOutput.preview), isTrue);
      await pumpEventQueue();
      expect(library, isFalse, reason: 'the older request lost');
      preview.acknowledge(); // a late acknowledgement changes nothing
      await pumpEventQueue();
      expect(transfer.holder, AudioOutput.preview);
      expect(library, isFalse);
    });

    test('a transfer that is never acknowledged ends at the bound: refused, '
        'and the holder keeps the output', () async {
      await hold(AudioOutput.queue);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      expect(timers.pending.single.$1, AudioFocus.relinquishBound);
      timers.fireAll();
      await pumpEventQueue();
      expect(granted, isFalse);
      expect(transfer.holder, AudioOutput.queue);
      expect(await transfer.beforePlay(AudioOutput.queue), isTrue,
          reason: 'nothing stays blocked after the bound');
      queue.acknowledge(); // too late: no grant
      await pumpEventQueue();
      expect(transfer.holder, AudioOutput.queue);
    });

    test('a granted transfer cancels its bound timer', () async {
      await hold(AudioOutput.queue);
      unawaited(transfer.acquire(AudioOutput.preview));
      await pumpEventQueue();
      queue.acknowledge();
      await pumpEventQueue();
      expect(timers.active, isEmpty);
    });

    test('a relinquish that fails is not an acknowledgement', () async {
      await hold(AudioOutput.queue);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      queue.fail(StateError('lane failed'));
      await pumpEventQueue();
      expect(granted, isFalse);
      expect(transfer.holder, AudioOutput.queue);
    });

    test('a holder released mid-transfer leaves the output to the acquirer',
        () async {
      await hold(AudioOutput.queue);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      transfer.release(AudioOutput.queue, queue);
      await pumpEventQueue();
      expect(granted, isTrue);
      expect(transfer.holder, AudioOutput.preview);
    });

    test('an output with no owner cannot acquire', () async {
      transfer.release(AudioOutput.preview, preview);
      expect(await transfer.acquire(AudioOutput.preview), isFalse);
      expect(transfer.holder, isNull);
    });

    test('releasing the holder frees the output', () async {
      await hold(AudioOutput.preview);
      transfer.release(AudioOutput.preview, preview);
      expect(transfer.holder, isNull);
    });

    test('an owner that cannot relinquish is acknowledged at once', () async {
      final plain = AudioFocus(port, timer: timers.create);
      addTearDown(plain.dispose);
      plain
        ..bind(AudioOutput.queue, RecordingOwner())
        ..bind(AudioOutput.preview, preview);
      expect(await plain.acquire(AudioOutput.preview), isTrue);
    });

    test('giving up the output leaves nobody holding it; the library stays '
        'yielded until it takes the output again', () async {
      await hold(AudioOutput.queue);
      expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
      unawaited(transfer.acquire(AudioOutput.preview));
      await pumpEventQueue();
      expect(transfer.yieldedBy(AudioOutput.queue), isTrue,
          reason: 'yielded from the moment the transfer away starts');
      queue.acknowledge();
      await pumpEventQueue();
      transfer.giveUp(AudioOutput.preview);
      expect(transfer.holder, isNull);
      expect(transfer.yieldedBy(AudioOutput.queue), isTrue);
      final back = transfer.beforePlay(AudioOutput.queue);
      await pumpEventQueue();
      preview.acknowledge();
      expect(await back, isTrue);
      expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
      expect(transfer.holder, AudioOutput.queue);
    });

    test('R1-05: giving up an output whose acquire is pending cancels it',
        () async {
      await hold(AudioOutput.queue);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      transfer.giveUp(AudioOutput.preview);
      await pumpEventQueue();
      expect(granted, isFalse);
      queue.acknowledge();
      await pumpEventQueue();
      expect(transfer.holder, AudioOutput.queue);
    });

    test('giving up an output it does not hold changes nothing', () async {
      await hold(AudioOutput.queue);
      transfer.giveUp(AudioOutput.preview);
      expect(transfer.holder, AudioOutput.queue);
    });

    test('a refused transfer does not leave the holder yielded', () async {
      await hold(AudioOutput.queue);
      unawaited(transfer.acquire(AudioOutput.preview));
      await pumpEventQueue();
      timers.fireAll();
      await pumpEventQueue();
      expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
    });

    test('session events go to the holder only: an interruption during '
        'preview never reaches the library', () async {
      await hold(AudioOutput.preview);
      port
        ..emit(const AudioInterruptionBegan(AudioInterruptionKind.pause))
        ..emit(const AudioInterruptionEnded(AudioInterruptionKind.pause))
        ..emit(const AudioBecameNoisy());
      await pumpEventQueue();
      expect(preview.calls, ['began', 'ended(resume: true)', 'noisy']);
      expect(queue.calls, isEmpty);
    });

    test('with nobody holding the output, events go to the library',
        () async {
      port.emit(const AudioBecameNoisy());
      await pumpEventQueue();
      expect(queue.calls, ['noisy']);
      expect(preview.calls, isEmpty);
    });

    test('after preview gives the output up, events go to the library again',
        () async {
      await hold(AudioOutput.preview);
      transfer.giveUp(AudioOutput.preview);
      port.emit(const AudioBecameNoisy());
      await pumpEventQueue();
      expect(queue.calls, ['noisy']);
      expect(preview.calls, isEmpty);
    });

    test('during a transfer both the holder and the pending target hear the '
        'event', () async {
      await hold(AudioOutput.queue);
      unawaited(transfer.acquire(AudioOutput.preview));
      await pumpEventQueue();
      port.emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await pumpEventQueue();
      expect(queue.calls, ['began']);
      expect(preview.calls, ['began']);
    });

    test('dispose refuses a pending acquire', () async {
      await hold(AudioOutput.queue);
      bool? granted;
      unawaited(transfer.acquire(AudioOutput.preview).then((g) => granted = g));
      await pumpEventQueue();
      transfer.dispose();
      await pumpEventQueue();
      expect(granted, isFalse);
      expect(timers.active, isEmpty);
    });

    // 7-R1-23: a preview closed (or released) before the library acknowledged
    // leaves the library holding the output; it must not stay yielded, or its
    // automatic continuations never play again.
    // Pre-merge R2-L-02: an output that was taken, or asked for, and never
    // used goes back as if the transfer had never been asked.
    group('handing the output back unused', () {
      test('the holder hands it back: the other output holds it again, is '
          'not yielded, and is told once', () async {
        await hold(AudioOutput.queue);
        await hold(AudioOutput.preview);
        final asked = preview.relinquishes;
        transfer.handBack(AudioOutput.preview);
        expect(transfer.holder, AudioOutput.queue);
        expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
        expect(queue.returns, 1);
        expect(await transfer.beforePlay(AudioOutput.queue), isTrue);
        expect(preview.relinquishes, asked,
            reason: 'the library plays again without asking the preview');
      });

      test('while its transfer is still pending: the transfer ends refused, '
          'the holder keeps the output, is not yielded, and is told once',
          () async {
        await hold(AudioOutput.queue);
        bool? granted;
        unawaited(
            transfer.acquire(AudioOutput.preview).then((g) => granted = g));
        await pumpEventQueue();
        expect(granted, isNull);
        transfer.handBack(AudioOutput.preview);
        await pumpEventQueue();
        expect(granted, isFalse);
        expect(transfer.holder, AudioOutput.queue);
        expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
        expect(queue.returns, 1);
        expect(timers.active, isEmpty);
        queue.acknowledge(); // a late acknowledgement changes nothing
        await pumpEventQueue();
        expect(transfer.holder, AudioOutput.queue);
      });

      test('an output that neither holds nor waits hands nothing back',
          () async {
        await hold(AudioOutput.queue);
        transfer.handBack(AudioOutput.preview);
        expect(transfer.holder, AudioOutput.queue);
        expect(queue.returns, 0);
      });

      test('an output that is already being taken back hands nothing back',
          () async {
        await hold(AudioOutput.preview);
        bool? back;
        unawaited(
            transfer.beforePlay(AudioOutput.queue).then((g) => back = g));
        await pumpEventQueue();
        expect(back, isNull);
        transfer.handBack(AudioOutput.preview);
        expect(queue.returns, 0);
        expect(transfer.holder, AudioOutput.preview,
            reason: 'the transfer to the library is still waiting');
        preview.acknowledge();
        await pumpEventQueue();
        expect(back, isTrue);
        expect(transfer.holder, AudioOutput.queue);
      });
    });

    group('7-R1-23: a superseded transfer leaves its holder not yielded', () {
      test('giving up the pending target while the library still holds',
          () async {
        await hold(AudioOutput.queue);
        unawaited(transfer.acquire(AudioOutput.preview));
        await pumpEventQueue();
        expect(transfer.yieldedBy(AudioOutput.queue), isTrue);
        transfer.giveUp(AudioOutput.preview);
        await pumpEventQueue();
        expect(transfer.holder, AudioOutput.queue);
        expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
        queue.acknowledge(); // the late acknowledgement changes nothing
        await pumpEventQueue();
        expect(transfer.holder, AudioOutput.queue);
        expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
      });

      test('releasing the pending target while the library still holds',
          () async {
        await hold(AudioOutput.queue);
        unawaited(transfer.acquire(AudioOutput.preview));
        await pumpEventQueue();
        transfer.release(AudioOutput.preview, preview);
        await pumpEventQueue();
        expect(transfer.holder, AudioOutput.queue);
        expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
      });

      test('with nobody holding, the asked output stays yielded (it gave '
          'nothing back)', () async {
        // The queue was asked to stop although it did not hold: superseding
        // the transfer does not make it the holder, so its yield (cleared
        // only when it is granted) is kept, as before.
        unawaited(transfer.acquire(AudioOutput.preview));
        await pumpEventQueue();
        transfer.giveUp(AudioOutput.preview);
        await pumpEventQueue();
        expect(transfer.holder, isNull);
        expect(transfer.yieldedBy(AudioOutput.queue), isTrue);
      });

      test('a library holder whose transfer was superseded plays at once',
          () async {
        await hold(AudioOutput.queue);
        final asked = preview.relinquishes;
        unawaited(transfer.acquire(AudioOutput.preview));
        await pumpEventQueue();
        transfer.giveUp(AudioOutput.preview);
        expect(await transfer.beforePlay(AudioOutput.queue), isTrue);
        expect(preview.relinquishes, asked, reason: 'nobody else is asked');
        expect(transfer.yieldedBy(AudioOutput.queue), isFalse);
      });
    });
  });
}
