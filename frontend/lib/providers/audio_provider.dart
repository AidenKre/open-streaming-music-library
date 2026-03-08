import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/ui/track_ui.dart';

enum PlayerStatus { idle, loading, playing, paused }

class AudioState {
  final TrackUI? currentTrack;
  final PlayerStatus status;
  final Duration position;
  final Duration duration;
  final double volume;

  const AudioState({
    this.currentTrack,
    this.status = PlayerStatus.idle,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 1.0,
  });

  AudioState copyWith({
    TrackUI? currentTrack,
    bool clearTrack = false,
    PlayerStatus? status,
    Duration? position,
    Duration? duration,
    double? volume,
  }) {
    return AudioState(
      currentTrack: clearTrack ? null : (currentTrack ?? this.currentTrack),
      status: status ?? this.status,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      volume: volume ?? this.volume,
    );
  }
}

class AudioNotifier extends Notifier<AudioState> {
  late final ja.AudioPlayer _player;
  final List<StreamSubscription<void>> _subscriptions = [];

  @override
  AudioState build() {
    _player = ja.AudioPlayer();

    _subscriptions.add(
      _player.playerStateStream.listen((playerState) {
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
    // ProcessingState.ready
    return playerState.playing ? PlayerStatus.playing : PlayerStatus.paused;
  }

  String _streamUrl(TrackUI track) {
    final base = ApiClient.instance.baseUrl;
    return '$base/tracks/${track.uuidId}/stream';
  }

  Future<void> play(TrackUI track) async {
    state = state.copyWith(
      currentTrack: track,
      status: PlayerStatus.loading,
    );
    try {
      await _player.setUrl(_streamUrl(track));
      await _player.play();
    } on Exception {
      state = state.copyWith(status: PlayerStatus.idle);
    }
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
      status: PlayerStatus.idle,
      position: Duration.zero,
      duration: Duration.zero,
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