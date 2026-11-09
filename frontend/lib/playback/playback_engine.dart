import 'package:frontend/repositories/queue_repository.dart';

/// What the engine is doing (SC-27 processing axis), independent of the
/// desired transport ([EngineTransportState.playing]) and of the playback
/// lifecycle.
enum EngineProcessingState { idle, loading, buffering, ready, completed }

/// Native looping over the loaded window. (5B.0d moves logical end/wrap to
/// the model; until then the core maps the queue repeat mode onto this.)
enum EngineLoopMode { off, all, one }

/// Desired transport as the engine reports it plus its processing state.
class EngineTransportState {
  const EngineTransportState(this.playing, this.processingState);
  final bool playing;
  final EngineProcessingState processingState;

  @override
  bool operator ==(Object other) =>
      other is EngineTransportState &&
      other.playing == playing &&
      other.processingState == processingState;

  @override
  int get hashCode => Object.hash(playing, processingState);

  @override
  String toString() => 'EngineTransportState($playing, $processingState)';
}

/// The engine advanced onto an entry that cannot play offline; the core
/// decides where playback goes instead.
class UnavailableAdvance {
  final int itemId;
  final int playPosition;

  const UnavailableAdvance({required this.itemId, required this.playPosition});
}

/// Why playback moved (Phase 5 §7). Commands carry it in-band; the engine
/// infers [naturalAdvance] and [repeatOneRestart] from the plugin.
enum PlaybackTransitionCause {
  userSeek,
  userSkip,
  queueReplacement,
  queueEdit,
  reconcileContinuation,
  qualityRebuild,
  sourceRefresh,
  naturalAdvance,
  repeatOneRestart,
  stop,
}

/// Immutable identity of one created engine source, captured when the
/// source was built. [sourceId] is unique per created source.
class EngineSourceIdentity {
  const EngineSourceIdentity({
    required this.sourceId,
    required this.sessionId,
    required this.itemId,
    required this.trackUuid,
    this.localPath,
  });
  final int sourceId;
  final int? sessionId;
  final int itemId;
  final String trackUuid;

  /// The local file this source plays, or null for a stream. Fixed for the
  /// source's life (so not part of equality: [sourceId] already is). A
  /// failure is classified by what the failing source actually loaded, not
  /// by the catalog's current path (review 2026-11-07).
  final String? localPath;

  @override
  bool operator ==(Object other) =>
      other is EngineSourceIdentity &&
      other.sourceId == sourceId &&
      other.sessionId == sessionId &&
      other.itemId == itemId &&
      other.trackUuid == trackUuid;

  @override
  int get hashCode => Object.hash(sourceId, sessionId, itemId, trackUuid);

  @override
  String toString() =>
      'EngineSourceIdentity(#$sourceId, session $sessionId, item $itemId)';
}

/// One ordered engine observation with provenance (SC-27 invariant 6).
/// Identity is captured when the observation is made, never reconstructed
/// later. While a structural change or seek is being applied the plugin's
/// index may refer to the old playlist: such observations are [uncertain]
/// and carry the last settled identity; consumers must not credit or
/// attribute them. A settled observation follows each applied change.
class PlaybackObservation {
  const PlaybackObservation({
    required this.runtimeId,
    required this.sequence,
    required this.playlistRevision,
    required this.source,
    required this.position,
    required this.duration,
    required this.playing,
    required this.processingState,
    required this.transitionCause,
    required this.rate,
    required this.uncertain,
  });
  final int runtimeId;
  final int sequence;
  final int playlistRevision;
  final EngineSourceIdentity? source;
  final Duration position;

  /// Engine-measured duration; null = unknown (never zero).
  final Duration? duration;
  final bool playing;
  final EngineProcessingState processingState;
  final PlaybackTransitionCause? transitionCause;

  /// Reserved for a future speed setting.
  final double rate;
  final bool uncertain;

  @override
  String toString() => 'PlaybackObservation(#$sequence rev $playlistRevision '
      '$source ${uncertain ? 'uncertain ' : ''}$transitionCause)';
}

/// How an issued load ended. [superseded]: a later seed replaced it.
/// [interrupted]: a stop cut it short; the playlist stays seeded.
enum EngineLoadOutcome { loaded, failed, superseded, interrupted }

/// Completion of a load the engine issued for playlist [playlistRevision].
/// Loads are never awaited by the playback lane (SC-27 invariant 3).
class EngineLoadEvent {
  const EngineLoadEvent({
    required this.playlistRevision,
    required this.outcome,
    this.duration,
    this.errorCode,
    this.errorMessage,
  });
  final int playlistRevision;
  final EngineLoadOutcome outcome;

  /// Engine-measured duration of the current source; null = unknown.
  final Duration? duration;

  /// Raw plugin error (no HTTP status; classification is the core's job).
  final int? errorCode;
  final String? errorMessage;
}

/// A raw plugin failure for one source (no HTTP status: classification is
/// the core's job). [source] is the failing source's identity, mapped through
/// what the plugin has applied; while a transition is pending the plugin's
/// index may name the old playlist, so the failure is [uncertain] with no
/// source.
class EngineSourceFailure {
  const EngineSourceFailure({
    required this.playlistRevision,
    required this.source,
    required this.uncertain,
    this.errorCode,
    this.errorMessage,
  });
  final int playlistRevision;
  final EngineSourceIdentity? source;
  final bool uncertain;
  final int? errorCode;
  final String? errorMessage;
}

/// The playback engine seen by the playback core (SC-27). No plugin types
/// cross this boundary; `JustAudioEngine` is the only adapter.
///
/// Commands return once issued: the engine orders native work itself and
/// reports slow completion (loads) as events, so a stalled load never blocks
/// the caller. Pause, stop and volume reach the plugin immediately, never
/// behind queued native work.
abstract interface class PlaybackEngine {
  /// Replaces the loaded window with [entries], current item first to play.
  /// Sources built from now on belong to [sessionId].
  Future<void> setSeed(
    List<QueuePlaybackEntry> entries, {
    required int currentItemId,
    int? sessionId,
    PlaybackTransitionCause cause = PlaybackTransitionCause.queueReplacement,
    Duration initialPosition = Duration.zero,
    bool autoPlay = false,
    bool shuffleEnabled = false,
  });

  /// Inserts entries not yet loaded at their play positions.
  Future<void> addEntries(List<QueuePlaybackEntry> entries);

  /// Replaces everything after the current item with [entries].
  Future<void> replaceFutureEntries({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  });

  /// Rebuilds the window around the (kept) current item.
  Future<void> rebuildAroundCurrent({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  });

  Future<void> removeItem(int itemId);

  /// Updates loaded entries' metadata without rebuilding sources.
  void replaceLoadedEntriesMetadata(List<QueuePlaybackEntry> updatedEntries);

  /// Rebuilds sources whose local-file vs. stream availability changed.
  Future<void> refreshLoadedSourcesForAvailabilityChanges(
    List<QueuePlaybackEntry> updatedEntries,
  );

  /// Stream quality applied to sources built from now on.
  void setStreamQuality(String quality);
  Future<void> rebuildCurrentSource(String quality, Duration seekTo);
  Future<void> rebuildAllSources(String quality, Duration seekTo);

  Future<void> seekToItem(int itemId, {Duration position = Duration.zero,
      PlaybackTransitionCause cause = PlaybackTransitionCause.userSkip});
  Future<void> play();
  Future<void> pause();
  /// A user seek within the current item.
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> setLoopMode(EngineLoopMode mode);

  int? get currentItemId;

  /// Bumped by every structural playlist change the engine issues.
  int get playlistRevision;
  Duration get position;
  int get queueLength;
  List<int> get loadedItemIds;
  bool hasItem(int itemId);

  Stream<EngineTransportState> get transportStateStream;
  Stream<Duration> get positionStream;
  Stream<int?> get currentItemIdStream;
  Stream<UnavailableAdvance> get unavailableAdvanceStream;
  Stream<EngineLoadEvent> get loadEvents;
  Stream<EngineSourceFailure> get sourceFailures;

  /// Identifies this engine instance in its observations.
  int get runtimeId;
  Stream<PlaybackObservation> get observations;

  void dispose();
}
