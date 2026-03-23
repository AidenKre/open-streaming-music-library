import 'package:frontend/models/ui/track_ui.dart';

enum PlayerStatus { idle, loading, playing, paused }

enum QueueRepeatMode { off, all, one }

class PlaybackSlice {
  final TrackUI? currentTrack;
  final PlayerStatus status;
  final Duration position;
  final Duration duration;
  final double volume;

  const PlaybackSlice({
    this.currentTrack,
    this.status = PlayerStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1.0,
  });

  PlaybackSlice copyWith({
    TrackUI? currentTrack,
    bool clearTrack = false,
    PlayerStatus? status,
    Duration? position,
    Duration? duration,
    double? volume,
  }) {
    return PlaybackSlice(
      currentTrack: clearTrack ? null : (currentTrack ?? this.currentTrack),
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
    );
  }
}

class QueueSlice {
  final int? sessionId;
  final int? currentItemId;
  final int currentPlayPosition;
  final int totalCount;
  final QueueRepeatMode repeatMode;
  final int queueVersion;

  const QueueSlice({
    this.sessionId,
    this.currentItemId,
    this.currentPlayPosition = 0,
    this.totalCount = 0,
    this.repeatMode = QueueRepeatMode.off,
    this.queueVersion = 0,
  });

  QueueSlice copyWith({
    int? sessionId,
    bool clearSession = false,
    int? currentItemId,
    bool clearCurrentItem = false,
    int? currentPlayPosition,
    int? totalCount,
    QueueRepeatMode? repeatMode,
    int? queueVersion,
  }) {
    return QueueSlice(
      sessionId: clearSession ? null : (sessionId ?? this.sessionId),
      currentItemId: clearCurrentItem
          ? null
          : (currentItemId ?? this.currentItemId),
      currentPlayPosition: currentPlayPosition ?? this.currentPlayPosition,
      totalCount: totalCount ?? this.totalCount,
      repeatMode: repeatMode ?? this.repeatMode,
      queueVersion: queueVersion ?? this.queueVersion,
    );
  }
}

class ShuffleSlice {
  final bool shuffleOn;

  const ShuffleSlice({this.shuffleOn = false});

  ShuffleSlice copyWith({bool? shuffleOn}) {
    return ShuffleSlice(shuffleOn: shuffleOn ?? this.shuffleOn);
  }
}

class AudioState {
  final PlaybackSlice playback;
  final QueueSlice queue;
  final ShuffleSlice shuffle;

  const AudioState({
    this.playback = const PlaybackSlice(),
    this.queue = const QueueSlice(),
    this.shuffle = const ShuffleSlice(),
  });

  AudioState copyWith({
    PlaybackSlice? playback,
    QueueSlice? queue,
    ShuffleSlice? shuffle,
  }) {
    return AudioState(
      playback: playback ?? this.playback,
      queue: queue ?? this.queue,
      shuffle: shuffle ?? this.shuffle,
    );
  }
}
