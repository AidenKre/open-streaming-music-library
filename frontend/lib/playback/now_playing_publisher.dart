import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';

/// OS media-session output (SC-27 observer): publishes now-playing and the
/// playback state from the core's coherent published state. It never
/// mutates playback state (invariant 10). Metadata publishes at once and
/// the artwork follows. Latest wins on `(sessionId, itemId)`: artwork still
/// resolving for an item that is no longer current, or after the
/// notification was cleared, is dropped.
class NowPlayingPublisher {
  NowPlayingPublisher(this._bridge, this._art, {Clock clock = const SystemClock()})
      : _stopwatch = clock.stopwatch();
  final AudioServiceBridge _bridge;
  final CoverArtCacheManager _art;
  final MonotonicStopwatch _stopwatch;

  /// A playing position this far off where real time puts it is a seek.
  static const _jump = Duration(milliseconds: 1500);
  Duration? _lastPosition;
  Duration _lastPublishedAt = Duration.zero;
  ({int sessionId, int itemId})? _current;
  Object? _currentMetadata;

  /// The art location last published for [_current] (kept across a
  /// same-item republish, e.g. the measured duration arriving).
  Uri? _currentArt;
  ({bool hasAlbumArt, int? coverArtId})? _currentArtSource;
  int _generation = 0;
  bool _cleared = true;
  ({bool playing, PlayerStatus status, int? itemId})? _lastState;

  void onState(AudioState? previous, AudioState next) {
    _publishNowPlaying(next);
    _publishPlaybackState(next);
  }

  void dispose() {
    _generation++;
    if (!_cleared) _bridge.clearNowPlaying();
  }

  void _publishNowPlaying(AudioState next) {
    final sessionId = next.queue.sessionId;
    final itemId = next.queue.currentItemId;
    final track = next.playback.currentTrack;
    if (sessionId == null || itemId == null || track == null) {
      if (_current == null && _cleared) return;
      _current = null;
      _currentMetadata = null;
      _currentArt = null;
      _currentArtSource = null;
      _generation++;
      _cleared = true;
      _bridge.clearNowPlaying();
      return;
    }
    final key = (sessionId: sessionId, itemId: itemId);
    // Same item: republish only when what the OS shows changed (an edit).
    final duration = next.playback.duration;
    final metadata = (track.title, track.artist, track.album, duration,
        track.hasAlbumArt, track.coverArtId);
    if (key == _current && metadata == _currentMetadata) return;
    final coverArtId = track.coverArtId;
    final artSource = (hasAlbumArt: track.hasAlbumArt, coverArtId: coverArtId);
    // Same item and the same artwork: the art already shown stays.
    final keptArt =
        key == _current && artSource == _currentArtSource ? _currentArt : null;
    _currentArtSource = artSource;
    _current = key;
    _currentMetadata = metadata;
    final generation = ++_generation;
    _cleared = false;
    // The metadata never waits for the art (user decision 2026-11-07): an
    // unresolved lookup would leave the previous track's title on the lock
    // screen. Locally stored art is known at once, so most items publish
    // once; otherwise the art follows when its location resolves.
    final localArt = keptArt ??
        (track.hasAlbumArt && coverArtId != null
            ? _art.localArtUri(coverArtId)
            : null);
    _currentArt = localArt;
    _bridge.updateNowPlaying(track, artUri: localArt, duration: duration);
    if (localArt != null || !track.hasAlbumArt || coverArtId == null) return;
    unawaited(_art
        .resolveArtUri(hasAlbumArt: true, coverArtId: coverArtId)
        .then((artUri) {
      if (artUri == null || generation != _generation) return;
      _currentArt = artUri;
      _bridge.updateNowPlaying(track, artUri: artUri, duration: duration);
    }).catchError((Object error, StackTrace stackTrace) {
      developer.log('Artwork lookup failed', name: 'NowPlayingPublisher',
          error: error, stackTrace: stackTrace);
    }));
  }

  /// Published on a transport, status or item change, or when the position
  /// jumps (a seek); never per position tick: the OS extrapolates a playing
  /// position from the last update itself.
  void _publishPlaybackState(AudioState next) {
    final state = (
      // The OS shows the desired transport (pause while buffering a play).
      playing: next.playback.playWhenReady,
      status: next.playback.status,
      itemId: next.queue.currentItemId,
    );
    final position = next.playback.position;
    final now = _stopwatch.elapsed;
    final last = _lastPosition;
    final expected = last == null
        ? null
        : last + (state.playing ? now - _lastPublishedAt : Duration.zero);
    final jumped = expected == null || (position - expected).abs() > _jump;
    if (state == _lastState && !jumped) return;
    _lastState = state;
    _lastPosition = position;
    _lastPublishedAt = now;
    _bridge.updatePlaybackState(
      playing: state.playing,
      processingState: AudioServiceBridge.processingStateFrom(state.status),
      position: position,
    );
  }
}

/// Kept alive by `playbackWiringProvider` once the session is ready.
final nowPlayingPublisherProvider = Provider<NowPlayingPublisher>((ref) {
  final publisher = NowPlayingPublisher(
      ref.read(audioServiceProvider), ref.read(coverArtCacheProvider),
      clock: ref.read(clockProvider));
  ref.listen<AudioState>(queuePlayerProvider, publisher.onState,
      fireImmediately: true);
  ref.onDispose(publisher.dispose);
  return publisher;
});
