import 'package:audio_service/audio_service.dart';
import 'package:frontend/ui/player_controller.dart';

/// Records every player input, for widget tests that override
/// `playerControlsProvider`.
class FakePlayerControls implements PlayerControls {
  final calls = <String>[];
  @override
  Future<void> togglePlayPause() async => calls.add('toggle');
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek ${position.inMilliseconds}');
  @override
  Future<void> skipNext() async => calls.add('next');
  @override
  Future<void> skipPrevious() async => calls.add('previous');
  @override
  Future<void> skipToItem(int itemId) async => calls.add('skipTo $itemId');
  @override
  Future<void> toggleShuffle() async => calls.add('shuffle');
  @override
  Future<void> cycleRepeat() async => calls.add('repeat');
  @override
  Future<void> removeFromQueue(int itemId) async => calls.add('remove $itemId');
  @override
  Future<void> setVolume(double volume) async => calls.add('volume $volume');
  @override
  Future<void> click(MediaButton button) async => calls.add('click ${button.name}');
}
