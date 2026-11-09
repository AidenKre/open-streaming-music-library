import 'package:audio_service/audio_service.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_state.dart';

/// Function signatures for media button callbacks.
/// `playbackWiringProvider` binds these (to PlayerControls).
typedef AsyncAction = Future<void> Function();
typedef AsyncSeekAction = Future<void> Function(Duration position);
typedef AsyncClickAction = Future<void> Function(MediaButton button);

/// Bridge between audio_service and the app.
/// Publishes now-playing/state to the OS (from the playback model) and
/// forwards OS input to callbacks bound by `playbackWiringProvider` (which
/// routes them to `PlayerControls`). Callbacks that arrive before binding
/// are intentional no-ops.
class AudioServiceBridge extends BaseAudioHandler {
  AsyncAction? onPlay;
  AsyncAction? onPause;
  AsyncAction? onSkipToNext;
  AsyncAction? onSkipToPrevious;
  AsyncSeekAction? onSeek;
  AsyncAction? onStop;
  AsyncClickAction? onClick;

  /// Identifies which wiring currently owns these callbacks. The wiring
  /// passes a token when binding so a later `clearCallbacks` call from a
  /// disposed scope only nulls out callbacks it itself installed — a newer
  /// scope that bound after a reset is left untouched.
  Object? _callbackOwner;

  /// Install media button callbacks and remember the owner. A queue player
  /// must call this once with a stable token (typically `this`) when wiring
  /// up the bridge.
  void bindCallbacks({
    required Object owner,
    AsyncAction? onPlay,
    AsyncAction? onPause,
    AsyncAction? onSkipToNext,
    AsyncAction? onSkipToPrevious,
    AsyncSeekAction? onSeek,
    AsyncAction? onStop,
    AsyncClickAction? onClick,
  }) {
    _callbackOwner = owner;
    this.onPlay = onPlay;
    this.onPause = onPause;
    this.onSkipToNext = onSkipToNext;
    this.onSkipToPrevious = onSkipToPrevious;
    this.onSeek = onSeek;
    this.onStop = onStop;
    this.onClick = onClick;
  }

  /// Clear media button callbacks if [owner] still owns them. Called from a
  /// queue player's dispose hook so OS notification taps don't invoke a
  /// torn-down player. If a newer queue player has since rebound the bridge,
  /// this is a no-op — its callbacks survive.
  void clearCallbacks(Object owner) {
    if (!identical(_callbackOwner, owner)) return;
    _callbackOwner = null;
    onPlay = null;
    onPause = null;
    onSkipToNext = null;
    onSkipToPrevious = null;
    onSeek = null;
    onStop = null;
    onClick = null;
  }

  /// Publishes now-playing. [duration] is the best known duration (the
  /// engine-measured one, else the catalog's); null = unknown, so the OS
  /// shows no duration rather than 0:00.
  void updateNowPlaying(TrackUI track, {Uri? artUri, Duration? duration}) {
    mediaItem.add(MediaItem(
      id: track.uuidId,
      title: track.title ?? 'Unknown',
      artist: track.artist ?? '',
      album: track.album ?? '',
      duration: duration,
      artUri: artUri,
    ));
  }

  void clearNowPlaying() {
    mediaItem.add(null);
  }

  /// Called by the queue player when playback state changes.
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

  /// Headset/media-key click. The default implementation toggles from the
  /// published OS state; route it to the app instead (media toggles from app
  /// state, next/previous skip).
  @override
  Future<void> click([MediaButton button = MediaButton.media]) async =>
      await onClick?.call(button);
}
