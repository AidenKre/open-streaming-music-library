import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/ui/player_controller.dart';

/// Records every model command the controller forwards.
class _RecordingQueuePlayer extends QueuePlayer {
  final calls = <String>[];
  @override
  AudioState build() => const AudioState();
  @override
  Future<void> togglePlayPause() async => calls.add('toggle');
  @override
  Future<void> resume() async => calls.add('resume');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration requested) async => calls.add('seek ${requested.inSeconds}');
  @override
  Future<void> skipNext() async => calls.add('next');
  @override
  Future<void> skipPrevious() async => calls.add('previous');
  @override
  Future<void> skipToTrack(int itemId) async => calls.add('skipTo $itemId');
  @override
  Future<void> toggleShuffle() async => calls.add('shuffle');
  @override
  Future<void> cycleQueueRepeatMode() async => calls.add('repeat');
  @override
  Future<void> removeFromQueue(int itemId) async => calls.add('remove $itemId');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
}

void main() {
  late _RecordingQueuePlayer audio;
  late ProviderContainer c;

  setUp(() {
    audio = _RecordingQueuePlayer();
    c = ProviderContainer(overrides: [queuePlayerProvider.overrideWith(() => audio)]);
  });
  tearDown(() => c.dispose());

  PlayerControls player() => c.read(playerControlsProvider);

  test('every transport/queue input forwards to the playback model', () async {
    final p = player();
    await p.togglePlayPause();
    await p.play();
    await p.pause();
    await p.seek(const Duration(seconds: 12));
    await p.skipNext();
    await p.skipPrevious();
    await p.skipToItem(7);
    await p.toggleShuffle();
    await p.cycleRepeat();
    await p.removeFromQueue(9);
    await p.setVolume(0.5);
    await p.stop();
    expect(audio.calls, [
      'toggle', 'resume', 'pause', 'seek 12', 'next', 'previous',
      'skipTo 7', 'shuffle', 'repeat', 'remove 9', 'volume 0.5', 'stop',
    ]);
  });

  test('the OS media button toggles through the model, not OS state', () async {
    await player().click(MediaButton.media);
    expect(audio.calls, ['toggle']);
  });

  test('OS next/previous buttons skip through the controller', () async {
    await player().click(MediaButton.next);
    await player().click(MediaButton.previous);
    expect(audio.calls, ['next', 'previous']);
  });
}
