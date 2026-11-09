import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/providers/audio/audio_focus.dart';

class FakeAudioSessionPort implements AudioSessionPort {
  final controller = StreamController<AudioSessionEvent>.broadcast();
  int listens = 0;

  @override
  Stream<AudioSessionEvent> get events {
    listens++;
    return controller.stream;
  }

  void emit(AudioSessionEvent event) => controller.add(event);
}

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

  test('ownership changes bump the revision; the owner may play', () async {
    final before = focus.ownershipRevision;
    focus.bind(AudioOutput.queue, owner);
    expect(focus.ownershipRevision, greaterThan(before));
    expect(await focus.beforePlay(AudioOutput.queue), isTrue);
    final bound = focus.ownershipRevision;
    focus.release(AudioOutput.queue, owner);
    expect(focus.ownershipRevision, greaterThan(bound));
    expect(await focus.beforePlay(AudioOutput.queue), isFalse,
        reason: 'no owner, no audio');
  });

  test('the session is subscribed once an owner binds', () async {
    expect(port.listens, 0);
    focus.bind(AudioOutput.queue, owner);
    focus.bind(AudioOutput.queue, RecordingOwner());
    expect(port.listens, 1);
  });
}
