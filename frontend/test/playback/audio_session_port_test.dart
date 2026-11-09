import 'package:audio_session/audio_session.dart' as session;
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/audio_session_port.dart';

void main() {
  test('maps audio_session interruptions onto model events', () {
    AudioSessionEvent map(bool begin, session.AudioInterruptionType type) =>
        AudioSessionAdapter.eventFrom(
            session.AudioInterruptionEvent(begin, type));
    final began = map(true, session.AudioInterruptionType.pause);
    expect(began, isA<AudioInterruptionBegan>());
    expect((began as AudioInterruptionBegan).kind, AudioInterruptionKind.pause);
    final ended = map(false, session.AudioInterruptionType.unknown);
    expect(ended, isA<AudioInterruptionEnded>());
    expect((ended as AudioInterruptionEnded).kind,
        AudioInterruptionKind.unknown);
    expect((map(true, session.AudioInterruptionType.duck)
            as AudioInterruptionBegan).kind,
        AudioInterruptionKind.duck);
  });
}
