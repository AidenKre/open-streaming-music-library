import 'dart:math';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';

enum PlayerStatus { idle, loading, playing, paused }

enum QueueRepeatMode { off, all, one }

class QueueContext {
  final int? artistId;
  final int? albumId;
  final List<OrderParameter> orderParams;
  final int shuffleSeed;

  const QueueContext({
    this.artistId,
    this.albumId,
    this.orderParams = const [],
    int? shuffleSeed,
  }) : shuffleSeed = shuffleSeed ?? 0;

  QueueContext withNewSeed() => QueueContext(
    artistId: artistId,
    albumId: albumId,
    orderParams: orderParams,
    shuffleSeed: Random().nextInt(1 << 32),
  );
}

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
  final QueueContext? queueContext;
  final QueueRepeatMode repeatMode;
  final List<TrackUI> upcomingTracks;

  const QueueSlice({
    this.queueContext,
    this.repeatMode = QueueRepeatMode.off,
    this.upcomingTracks = const [],
  });

  QueueSlice copyWith({
    QueueContext? queueContext,
    bool clearQueueContext = false,
    QueueRepeatMode? repeatMode,
    List<TrackUI>? upcomingTracks,
  }) {
    return QueueSlice(
      queueContext: clearQueueContext
          ? null
          : (queueContext ?? this.queueContext),
      repeatMode: repeatMode ?? this.repeatMode,
      upcomingTracks: upcomingTracks ?? this.upcomingTracks,
    );
  }
}

class ShuffleSlice {
  final bool shuffleOn;
  final List<String> shuffledUuids;
  final int shuffleIndex;

  const ShuffleSlice({
    this.shuffleOn = false,
    this.shuffledUuids = const [],
    this.shuffleIndex = 0,
  });

  ShuffleSlice copyWith({
    bool? shuffleOn,
    List<String>? shuffledUuids,
    int? shuffleIndex,
  }) {
    return ShuffleSlice(
      shuffleOn: shuffleOn ?? this.shuffleOn,
      shuffledUuids: shuffledUuids ?? this.shuffledUuids,
      shuffleIndex: shuffleIndex ?? this.shuffleIndex,
    );
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

List<OrderParameter> reversedOrder(List<OrderParameter> params) => params
    .map((o) => OrderParameter(column: o.column, isAscending: !o.isAscending))
    .toList();
