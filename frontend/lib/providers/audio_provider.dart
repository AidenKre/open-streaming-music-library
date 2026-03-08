import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';

enum PlayerStatus { idle, loading, playing, paused }

enum QueueRepeatMode { off, all, one }

class QueueContext {
  final String? artist;
  final String? album;
  final List<OrderParameter> orderParams;
  final int shuffleSeed;

  const QueueContext({
    this.artist,
    this.album,
    this.orderParams = const [],
    int? shuffleSeed,
  }) : shuffleSeed = shuffleSeed ?? 0;

  QueueContext withNewSeed() => QueueContext(
    artist: artist,
    album: album,
    orderParams: orderParams,
    shuffleSeed: Random().nextInt(1 << 32),
  );
}

class AudioState {
  final TrackUI? currentTrack;
  final PlayerStatus status;
  final Duration position;
  final Duration duration;
  final double volume;
  final QueueContext? queueContext;
  final bool shuffleOn;
  final QueueRepeatMode repeatMode;
  final List<String> shuffledUuids;
  final int shuffleIndex;
  final List<TrackUI> upcomingTracks;

  const AudioState({
    this.currentTrack,
    this.status = PlayerStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1.0,
    this.queueContext,
    this.shuffleOn = false,
    this.repeatMode = QueueRepeatMode.off,
    this.shuffledUuids = const [],
    this.shuffleIndex = 0,
    this.upcomingTracks = const [],
  });

  AudioState copyWith({
    TrackUI? currentTrack,
    bool clearTrack = false,
    PlayerStatus? status,
    Duration? position,
    Duration? duration,
    double? volume,
    QueueContext? queueContext,
    bool clearQueueContext = false,
    bool? shuffleOn,
    QueueRepeatMode? repeatMode,
    List<String>? shuffledUuids,
    int? shuffleIndex,
    List<TrackUI>? upcomingTracks,
  }) {
    return AudioState(
      currentTrack: clearTrack ? null : (currentTrack ?? this.currentTrack),
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
      queueContext: clearQueueContext ? null : (queueContext ?? this.queueContext),
      shuffleOn: shuffleOn ?? this.shuffleOn,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffledUuids: shuffledUuids ?? this.shuffledUuids,
      shuffleIndex: shuffleIndex ?? this.shuffleIndex,
      upcomingTracks: upcomingTracks ?? this.upcomingTracks,
    );
  }
}

List<OrderParameter> reversedOrder(List<OrderParameter> params) =>
    params.map((o) => OrderParameter(column: o.column, isAscending: !o.isAscending)).toList();

List<RowFilterParameter> _cursorFromTrack(TrackUI track, List<OrderParameter> orderParams) {
  return orderParams.map((o) {
    final value = switch (o.column) {
      'artist' => track.artist,
      'album' => track.album,
      'disc_number' => track.discNumber,
      'track_number' => track.trackNumber,
      'uuid_id' => track.uuidId,
      'title' => track.title,
      'album_artist' => track.albumArtist,
      'year' => track.year,
      'date' => track.date,
      'genre' => track.genre,
      'codec' => track.codec,
      'duration' => track.duration,
      'bitrate_kbps' => track.bitrateKbps,
      'sample_rate_hz' => track.sampleRateHz,
      'channels' => track.channels,
      'created_at' => track.createdAt,
      'last_updated' => track.lastUpdated,
      _ => null,
    };
    return RowFilterParameter(column: o.column, value: value);
  }).toList();
}

class AudioNotifier extends Notifier<AudioState> {
  late final ja.AudioPlayer _player;
  final List<StreamSubscription<void>> _subscriptions = [];
  bool _isAdvancing = false;

  AppDatabase get _db => ref.read(databaseProvider);

  @override
  AudioState build() {
    _player = ja.AudioPlayer();

    _subscriptions.add(
      _player.playerStateStream.listen((playerState) {
        if (playerState.processingState == ja.ProcessingState.completed) {
          _onTrackCompleted();
          return;
        }
        final status = _mapStatus(playerState);
        state = state.copyWith(status: status);
      }),
    );

    _subscriptions.add(
      _player.positionStream.listen((pos) {
        state = state.copyWith(position: pos);
      }),
    );

    _subscriptions.add(
      _player.durationStream.listen((dur) {
        state = state.copyWith(duration: dur ?? Duration.zero);
      }),
    );

    ref.onDispose(() {
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _player.dispose();
    });

    return const AudioState();
  }

  PlayerStatus _mapStatus(ja.PlayerState playerState) {
    final processing = playerState.processingState;
    if (processing == ja.ProcessingState.loading ||
        processing == ja.ProcessingState.buffering) {
      return PlayerStatus.loading;
    }
    if (processing == ja.ProcessingState.completed ||
        processing == ja.ProcessingState.idle) {
      return PlayerStatus.idle;
    }
    return playerState.playing ? PlayerStatus.playing : PlayerStatus.paused;
  }

  void _onTrackCompleted() {
    if (_isAdvancing) return;
    skipNext();
  }

  String _streamUrl(TrackUI track) {
    final base = ApiClient.instance.baseUrl;
    return '$base/tracks/${track.uuidId}/stream';
  }

  Future<void> _playTrack(TrackUI track) async {
    state = state.copyWith(
      currentTrack: track,
      status: PlayerStatus.loading,
      position: Duration.zero,
    );
    try {
      await _player.setUrl(_streamUrl(track));
      _player.play();
    } on Exception {
      state = state.copyWith(status: PlayerStatus.idle);
      return;
    }
    await _refreshUpcoming();
  }

  /// Play a single track with no queue context.
  Future<void> play(TrackUI track) async {
    state = state.copyWith(
      clearQueueContext: true,
      shuffleOn: false,
      shuffledUuids: const [],
      shuffleIndex: 0,
      upcomingTracks: const [],
    );
    await _playTrack(track);
  }

  /// Play a track within a queue context (artist/album/sort order).
  Future<void> playFromQueue(QueueContext context, TrackUI track) async {
    var ctx = context;
    if (state.shuffleOn) {
      ctx = ctx.withNewSeed();
      final uuids = await _db.getTrackUuids(
        orderBy: ctx.orderParams,
        artist: ctx.artist,
        album: ctx.album,
      );
      final shuffled = _shuffleWithCurrentFirst(uuids, track.uuidId, ctx.shuffleSeed);
      state = state.copyWith(
        queueContext: ctx,
        shuffledUuids: shuffled,
        shuffleIndex: 0,
      );
    } else {
      state = state.copyWith(
        queueContext: ctx,
        shuffledUuids: const [],
        shuffleIndex: 0,
      );
    }
    await _playTrack(track);
  }

  Future<void> skipNext() async {
    if (_isAdvancing) return;
    _isAdvancing = true;
    try {
      await _skipNextInner();
    } finally {
      _isAdvancing = false;
    }
  }

  Future<void> _skipNextInner() async {
    final track = state.currentTrack;
    final ctx = state.queueContext;
    if (track == null || ctx == null) {
      await _player.stop();
      state = state.copyWith(status: PlayerStatus.idle);
      return;
    }

    // Repeat one: loop current track
    if (state.repeatMode == QueueRepeatMode.one) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }

    if (state.shuffleOn && state.shuffledUuids.isNotEmpty) {
      await _skipNextShuffle(ctx);
    } else {
      await _skipNextCursor(track, ctx);
    }
  }

  Future<void> _skipNextCursor(TrackUI current, QueueContext ctx) async {
    final cursor = _cursorFromTrack(current, ctx.orderParams);
    final rows = await _db.getTracks(
      orderBy: ctx.orderParams,
      cursorFilters: cursor,
      artist: ctx.artist,
      album: ctx.album,
      limit: 1,
    );

    if (rows.isNotEmpty) {
      await _playTrack(TrackUI.fromQueryRow(rows.first));
      return;
    }

    // End of queue
    if (state.repeatMode == QueueRepeatMode.all) {
      // Wrap to first track
      final firstRows = await _db.getTracks(
        orderBy: ctx.orderParams,
        artist: ctx.artist,
        album: ctx.album,
        limit: 1,
      );
      if (firstRows.isNotEmpty) {
        await _playTrack(TrackUI.fromQueryRow(firstRows.first));
        return;
      }
    }

    // RepeatOff: stop
    await _player.stop();
    state = state.copyWith(status: PlayerStatus.idle);
  }

  Future<void> _skipNextShuffle(QueueContext ctx) async {
    final nextIndex = state.shuffleIndex + 1;
    if (nextIndex < state.shuffledUuids.length) {
      final uuid = state.shuffledUuids[nextIndex];
      final rows = await _db.getTrackByUuid(uuid);
      if (rows.isNotEmpty) {
        state = state.copyWith(shuffleIndex: nextIndex);
        await _playTrack(TrackUI.fromQueryRow(rows.first));
        return;
      }
    }

    // End of shuffle list
    if (state.repeatMode == QueueRepeatMode.all && state.shuffledUuids.isNotEmpty) {
      final uuid = state.shuffledUuids[0];
      final rows = await _db.getTrackByUuid(uuid);
      if (rows.isNotEmpty) {
        state = state.copyWith(shuffleIndex: 0);
        await _playTrack(TrackUI.fromQueryRow(rows.first));
        return;
      }
    }

    await _player.stop();
    state = state.copyWith(status: PlayerStatus.idle);
  }

  Future<void> skipPrevious() async {
    final track = state.currentTrack;
    final ctx = state.queueContext;

    // If >3s in, seek to start
    if (state.position.inSeconds > 3) {
      await _player.seek(Duration.zero);
      return;
    }

    if (track == null || ctx == null) {
      await _player.seek(Duration.zero);
      return;
    }

    if (state.repeatMode == QueueRepeatMode.one) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }

    if (state.shuffleOn && state.shuffledUuids.isNotEmpty) {
      await _skipPrevShuffle(ctx);
    } else {
      await _skipPrevCursor(track, ctx);
    }
  }

  Future<void> _skipPrevCursor(TrackUI current, QueueContext ctx) async {
    final reversed = reversedOrder(ctx.orderParams);
    final cursor = _cursorFromTrack(current, reversed);
    final rows = await _db.getTracks(
      orderBy: reversed,
      cursorFilters: cursor,
      artist: ctx.artist,
      album: ctx.album,
      limit: 1,
    );

    if (rows.isNotEmpty) {
      await _playTrack(TrackUI.fromQueryRow(rows.first));
      return;
    }

    // Start of queue
    if (state.repeatMode == QueueRepeatMode.all) {
      // Wrap to last track (first in reversed order)
      final lastRows = await _db.getTracks(
        orderBy: reversed,
        artist: ctx.artist,
        album: ctx.album,
        limit: 1,
      );
      if (lastRows.isNotEmpty) {
        await _playTrack(TrackUI.fromQueryRow(lastRows.first));
        return;
      }
    }

    // RepeatOff: seek to start
    await _player.seek(Duration.zero);
  }

  Future<void> _skipPrevShuffle(QueueContext ctx) async {
    final prevIndex = state.shuffleIndex - 1;
    if (prevIndex >= 0) {
      final uuid = state.shuffledUuids[prevIndex];
      final rows = await _db.getTrackByUuid(uuid);
      if (rows.isNotEmpty) {
        state = state.copyWith(shuffleIndex: prevIndex);
        await _playTrack(TrackUI.fromQueryRow(rows.first));
        return;
      }
    }

    // Start of shuffle list
    if (state.repeatMode == QueueRepeatMode.all && state.shuffledUuids.isNotEmpty) {
      final lastIndex = state.shuffledUuids.length - 1;
      final uuid = state.shuffledUuids[lastIndex];
      final rows = await _db.getTrackByUuid(uuid);
      if (rows.isNotEmpty) {
        state = state.copyWith(shuffleIndex: lastIndex);
        await _playTrack(TrackUI.fromQueryRow(rows.first));
        return;
      }
    }

    await _player.seek(Duration.zero);
  }

  Future<void> toggleShuffle() async {
    final ctx = state.queueContext;
    if (ctx == null) return;

    if (!state.shuffleOn) {
      // Turn on: load all UUIDs, shuffle with current track first
      final newCtx = ctx.withNewSeed();
      final uuids = await _db.getTrackUuids(
        orderBy: newCtx.orderParams,
        artist: newCtx.artist,
        album: newCtx.album,
      );
      final currentUuid = state.currentTrack?.uuidId;
      final shuffled = _shuffleWithCurrentFirst(uuids, currentUuid, newCtx.shuffleSeed);
      state = state.copyWith(
        shuffleOn: true,
        queueContext: newCtx,
        shuffledUuids: shuffled,
        shuffleIndex: 0,
      );
    } else {
      // Turn off: clear shuffle state
      state = state.copyWith(
        shuffleOn: false,
        shuffledUuids: const [],
        shuffleIndex: 0,
      );
    }
    _refreshUpcoming();
  }

  void cycleQueueRepeatMode() {
    final next = switch (state.repeatMode) {
      QueueRepeatMode.off => QueueRepeatMode.all,
      QueueRepeatMode.all => QueueRepeatMode.one,
      QueueRepeatMode.one => QueueRepeatMode.off,
    };
    state = state.copyWith(repeatMode: next);
  }

  Future<void> skipToTrack(TrackUI track) async {
    if (state.shuffleOn && state.shuffledUuids.isNotEmpty) {
      final idx = state.shuffledUuids.indexOf(track.uuidId);
      if (idx >= 0) {
        state = state.copyWith(shuffleIndex: idx);
      }
    }
    await _playTrack(track);
  }

  Future<void> _refreshUpcoming() async {
    final track = state.currentTrack;
    final ctx = state.queueContext;
    if (track == null || ctx == null) {
      state = state.copyWith(upcomingTracks: const []);
      return;
    }

    if (state.shuffleOn && state.shuffledUuids.isNotEmpty) {
      // Next 20 from shuffled list
      final start = state.shuffleIndex + 1;
      final end = (start + 20).clamp(0, state.shuffledUuids.length);
      if (start >= state.shuffledUuids.length) {
        state = state.copyWith(upcomingTracks: const []);
        return;
      }
      final uuids = state.shuffledUuids.sublist(start, end);
      final rows = await _db.getTracksByUuids(uuids);
      // Reorder to match uuid order
      final map = <String, TrackUI>{};
      for (final row in rows) {
        final t = TrackUI.fromQueryRow(row);
        map[t.uuidId] = t;
      }
      final ordered = uuids.where((u) => map.containsKey(u)).map((u) => map[u]!).toList();
      state = state.copyWith(upcomingTracks: ordered);
    } else {
      // Forward cursor from current track
      final cursor = _cursorFromTrack(track, ctx.orderParams);
      final rows = await _db.getTracks(
        orderBy: ctx.orderParams,
        cursorFilters: cursor,
        artist: ctx.artist,
        album: ctx.album,
        limit: 20,
      );
      state = state.copyWith(
        upcomingTracks: rows.map(TrackUI.fromQueryRow).toList(),
      );
    }
  }

  List<String> _shuffleWithCurrentFirst(List<String> uuids, String? currentUuid, int seed) {
    final shuffled = List<String>.from(uuids);
    shuffled.shuffle(Random(seed));
    if (currentUuid != null) {
      shuffled.remove(currentUuid);
      shuffled.insert(0, currentUuid);
    }
    return shuffled;
  }

  Future<void> resume() async {
    if (state.status == PlayerStatus.paused) {
      await _player.play();
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.stop();
    state = state.copyWith(
      clearTrack: true,
      clearQueueContext: true,
      status: PlayerStatus.idle,
      position: Duration.zero,
      duration: Duration.zero,
      shuffleOn: false,
      shuffledUuids: const [],
      shuffleIndex: 0,
      upcomingTracks: const [],
    );
  }

  Future<void> seek(Duration pos) async {
    await _player.seek(pos);
  }

  Future<void> setVolume(double v) async {
    await _player.setVolume(v);
    state = state.copyWith(volume: v);
  }
}

final audioProvider =
    NotifierProvider<AudioNotifier, AudioState>(AudioNotifier.new);

final currentTrackProvider = Provider<TrackUI?>((ref) =>
    ref.watch(audioProvider.select((s) => s.currentTrack)));

final audioPositionProvider = Provider<Duration>((ref) =>
    ref.watch(audioProvider.select((s) => s.position)));

final audioDurationProvider = Provider<Duration>((ref) =>
    ref.watch(audioProvider.select((s) => s.duration)));

final audioStatusProvider = Provider<PlayerStatus>((ref) =>
    ref.watch(audioProvider.select((s) => s.status)));

final audioVolumeProvider = Provider<double>((ref) =>
    ref.watch(audioProvider.select((s) => s.volume)));

final shuffleProvider = Provider<bool>((ref) =>
    ref.watch(audioProvider.select((s) => s.shuffleOn)));

final repeatModeProvider = Provider<QueueRepeatMode>((ref) =>
    ref.watch(audioProvider.select((s) => s.repeatMode)));

final upcomingTracksProvider = Provider<List<TrackUI>>((ref) =>
    ref.watch(audioProvider.select((s) => s.upcomingTracks)));