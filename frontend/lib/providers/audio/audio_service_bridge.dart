import 'package:audio_service/audio_service.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_state.dart';

/// Function signatures for media button callbacks.
/// The coordinator binds these after construction.
typedef AsyncAction = Future<void> Function();
typedef AsyncSeekAction = Future<void> Function(Duration position);

/// Bridge between audio_service and our audio coordinator.
/// Handles notification updates and media button callbacks.
class AudioServiceBridge extends BaseAudioHandler {
  AsyncAction? onPlay;
  AsyncAction? onPause;
  AsyncAction? onSkipToNext;
  AsyncAction? onSkipToPrevious;
  AsyncSeekAction? onSeek;
  AsyncAction? onStop;

  /// Called by coordinator when the current track changes.
  void updateNowPlaying(TrackUI track, {Uri? artUri}) {
    mediaItem.add(MediaItem(
      id: track.uuidId,
      title: track.title ?? 'Unknown',
      artist: track.artist ?? '',
      album: track.album ?? '',
      duration: Duration(milliseconds: (track.duration * 1000).round()),
      artUri: artUri,
    ));
  }

  void clearNowPlaying() {
    mediaItem.add(null);
  }

  /// Called by coordinator when playback state changes.
  void updatePlaybackState({
    required bool playing,
    required AudioProcessingState processingState,
    required Duration position,
  }) {
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingState,
      playing: playing,
      updatePosition: position,
    ));
  }

  /// Maps our PlayerStatus to audio_service's AudioProcessingState.
  static AudioProcessingState processingStateFrom(PlayerStatus status) {
    return switch (status) {
      PlayerStatus.idle => AudioProcessingState.idle,
      PlayerStatus.loading => AudioProcessingState.loading,
      PlayerStatus.playing => AudioProcessingState.ready,
      PlayerStatus.paused => AudioProcessingState.ready,
    };
  }

  @override
  Future<void> play() async => await onPlay?.call();

  @override
  Future<void> pause() async => await onPause?.call();

  @override
  Future<void> skipToNext() async => await onSkipToNext?.call();

  @override
  Future<void> skipToPrevious() async => await onSkipToPrevious?.call();

  @override
  Future<void> seek(Duration position) async => await onSeek?.call(position);

  @override
  Future<void> stop() async => await onStop?.call();
}
