import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/providers/audio/audio_dependencies.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/audio/audio_service_bridge.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';

/// OS media-session output (SC-27 observer): publishes now-playing and the
/// playback state from the core's coherent published state. It never
/// mutates playback state (invariant 10). Latest wins on
/// `(sessionId, itemId)`: artwork still resolving for an item that is no
/// longer current, or after the notification was cleared, is dropped.
class NowPlayingPublisher {
  NowPlayingPublisher(this._bridge, this._art);
  final AudioServiceBridge _bridge;
  final CoverArtCacheManager _art;
  ({int sessionId, int itemId})? _current;
  Object? _currentMetadata;
  int _generation = 0;
  bool _cleared = true;
  ({bool playing, PlayerStatus status, Duration position})? _lastState;

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
    _current = key;
    _currentMetadata = metadata;
    final generation = ++_generation;
    unawaited(_art
        .resolveArtUri(
            hasAlbumArt: track.hasAlbumArt, coverArtId: track.coverArtId)
        .then((artUri) {
      if (generation != _generation) return; // superseded or cleared
      _cleared = false;
      _bridge.updateNowPlaying(track, artUri: artUri, duration: duration);
    }).catchError((Object error, StackTrace stackTrace) {
      developer.log('Artwork lookup failed', name: 'NowPlayingPublisher',
          error: error, stackTrace: stackTrace);
      if (generation != _generation) return;
      _cleared = false;
      _bridge.updateNowPlaying(track, duration: duration);
    }));
  }

  void _publishPlaybackState(AudioState next) {
    final state = (
      // The OS shows the desired transport (pause while buffering a play).
      playing: next.playback.playWhenReady,
      status: next.playback.status,
      position: next.playback.position,
    );
    if (state == _lastState) return;
    _lastState = state;
    _bridge.updatePlaybackState(
      playing: state.playing,
      processingState: AudioServiceBridge.processingStateFrom(state.status),
      position: state.position,
    );
  }
}

/// Kept alive by `playbackWiringProvider` once the session is ready.
final nowPlayingPublisherProvider = Provider<NowPlayingPublisher>((ref) {
  final publisher = NowPlayingPublisher(
      ref.read(audioServiceProvider), ref.read(coverArtCacheProvider));
  ref.listen<AudioState>(audioProvider, publisher.onState,
      fireImmediately: true);
  ref.onDispose(publisher.dispose);
  return publisher;
});
