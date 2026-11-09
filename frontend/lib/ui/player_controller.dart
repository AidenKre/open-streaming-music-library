import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_providers.dart';

/// Every transport and queue input (SC-27): the mini player, the full
/// player and the OS media session (lock screen, notification, macOS Now
/// Playing, headset/media keys) all enter here, so they share one path and
/// one set of rules. The rules themselves (toggle decision, seek clamping,
/// offline policy) live in the playback model; this only forwards intents.
/// Phase 5 swaps the model behind it without touching views.
abstract interface class PlayerControls {
  Future<void> togglePlayPause();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> skipNext();
  Future<void> skipPrevious();
  Future<void> skipToItem(int itemId);
  Future<void> toggleShuffle();
  Future<void> cycleRepeat();
  Future<void> removeFromQueue(int itemId);
  Future<void> setVolume(double volume);

  /// A generic media-button press: `media` toggles (from app state, never
  /// the published OS state), `next`/`previous` skip.
  Future<void> click(MediaButton button);
}

final playerControlsProvider = Provider<PlayerControls>(
  (ref) => PlayerController(ref),
);

class PlayerController implements PlayerControls {
  PlayerController(this._ref);

  final Ref _ref;

  QueuePlayer get _player => _ref.read(queuePlayerProvider.notifier);

  @override
  Future<void> togglePlayPause() => _player.togglePlayPause();

  @override
  Future<void> play() => _player.resume();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipNext() => _player.skipNext();

  @override
  Future<void> skipPrevious() => _player.skipPrevious();

  @override
  Future<void> skipToItem(int itemId) => _player.skipToTrack(itemId);

  @override
  Future<void> toggleShuffle() => _player.toggleShuffle();

  @override
  Future<void> cycleRepeat() => _player.cycleQueueRepeatMode();

  @override
  Future<void> removeFromQueue(int itemId) => _player.removeFromQueue(itemId);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> click(MediaButton button) => switch (button) {
    MediaButton.media => togglePlayPause(),
    MediaButton.next => skipNext(),
    MediaButton.previous => skipPrevious(),
  };
}
