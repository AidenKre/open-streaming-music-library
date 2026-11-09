import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_session/audio_session.dart' as session;

import 'package:frontend/providers/audio/audio_focus.dart';

/// The production [AudioSessionPort]: the OS audio session via
/// audio_session, mapped onto model events. Subscribes when listened to.
class AudioSessionAdapter implements AudioSessionPort {
  @override
  Stream<AudioSessionEvent> get events {
    final subscriptions = <StreamSubscription<Object?>>[];
    late final StreamController<AudioSessionEvent> controller;
    controller = StreamController<AudioSessionEvent>(
      onListen: () {
        session.AudioSession.instance.then((audioSession) {
          if (controller.isClosed) return;
          subscriptions
            ..add(audioSession.interruptionEventStream
                .listen((event) => controller.add(eventFrom(event))))
            ..add(audioSession.becomingNoisyEventStream
                .listen((_) => controller.add(const AudioBecameNoisy())));
        }).catchError((Object error, StackTrace stackTrace) {
          developer.log('Audio session unavailable',
              name: 'AudioSessionAdapter', error: error, stackTrace: stackTrace);
        });
      },
      onCancel: () async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        await controller.close();
      },
    );
    return controller.stream;
  }

  static AudioSessionEvent eventFrom(session.AudioInterruptionEvent event) {
    final kind = switch (event.type) {
      session.AudioInterruptionType.pause => AudioInterruptionKind.pause,
      session.AudioInterruptionType.duck => AudioInterruptionKind.duck,
      session.AudioInterruptionType.unknown => AudioInterruptionKind.unknown,
    };
    return event.begin
        ? AudioInterruptionBegan(kind)
        : AudioInterruptionEnded(kind);
  }
}
