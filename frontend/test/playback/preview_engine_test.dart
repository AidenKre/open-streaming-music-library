import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/preview_engine.dart';

class _Plugin extends Mock implements ja.AudioPlayer {}

void main() {
  late _Plugin plugin;
  late StreamController<ja.PlayerState> states;
  late List<String> logs;
  late JustAudioPreviewEngine engine;

  setUp(() {
    plugin = _Plugin();
    states = StreamController<ja.PlayerState>.broadcast();
    logs = [];
    when(() => plugin.playerStateStream).thenAnswer((_) => states.stream);
    when(() => plugin.play()).thenAnswer((_) => Completer<void>().future);
    when(() => plugin.pause()).thenAnswer((_) async {});
    when(() => plugin.stop()).thenAnswer((_) async {});
    when(() => plugin.dispose()).thenAnswer((_) async {});
    engine = JustAudioPreviewEngine(plugin, log: logs.add);
  });

  tearDown(() => states.close());

  test('its own player is built with plugin interruption handling off', () {
    bool? handled;
    JustAudioPreviewEngine.create(newPlayer: ({required handleInterruptions}) {
      handled = handleInterruptions;
      return plugin;
    });
    expect(handled, isFalse);
  });

  test('load sets the one source and answers its duration', () async {
    final uri = Uri.parse('http://srv/tracks/x/stream?access_token=t');
    when(() => plugin.setUrl(uri.toString()))
        .thenAnswer((_) async => const Duration(seconds: 42));
    expect(await engine.load(uri), const Duration(seconds: 42));
    verify(() => plugin.setUrl(uri.toString())).called(1);
  });

  test('an unknown duration stays null', () async {
    when(() => plugin.setUrl(any())).thenAnswer((_) async => null);
    expect(await engine.load(Uri.parse('http://srv/a')), isNull);
  });

  test('a failed load throws a message-free failure and logs no token',
      () async {
    when(() => plugin.setUrl(any())).thenThrow(ja.PlayerException(
        0, 'cannot open http://srv/p?access_token=secret-token', 0));
    await expectLater(
        engine.load(Uri.parse('http://srv/p?access_token=secret-token')),
        throwsA(isA<PreviewLoadFailed>()));
    expect(logs, isNotEmpty);
    expect(logs.join(), isNot(contains('secret-token')));
  });

  test('play is issued, never awaited for the playback lifetime', () async {
    await engine.play().timeout(const Duration(seconds: 1));
    verify(() => plugin.play()).called(1);
  });

  test('pause, stop and dispose reach the plugin', () async {
    await engine.pause();
    await engine.stop();
    engine.dispose();
    verify(() => plugin.pause()).called(1);
    verify(() => plugin.stop()).called(1);
    verify(() => plugin.dispose()).called(1);
  });

  test('plugin states map onto the engine transport', () async {
    final seen = <EngineTransportState>[];
    final sub = engine.transportStates.listen(seen.add);
    addTearDown(sub.cancel);
    states
      ..add(ja.PlayerState(true, ja.ProcessingState.loading))
      ..add(ja.PlayerState(true, ja.ProcessingState.ready))
      ..add(ja.PlayerState(false, ja.ProcessingState.ready))
      ..add(ja.PlayerState(true, ja.ProcessingState.completed));
    await pumpEventQueue();
    expect(seen, const [
      EngineTransportState(true, EngineProcessingState.loading),
      EngineTransportState(true, EngineProcessingState.ready),
      EngineTransportState(false, EngineProcessingState.ready),
      EngineTransportState(true, EngineProcessingState.completed),
    ]);
  });
}
