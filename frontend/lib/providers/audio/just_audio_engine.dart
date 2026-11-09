import 'dart:async';
import 'dart:developer' as developer;

import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/providers/audio/playback_engine.dart';
import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/quality_presets.dart';

/// The only adapter onto just_audio (SC-27). Maps plugin types onto the
/// [PlaybackEngine] API.
///
/// Commands return once issued (SC-27 invariant 3). Every plugin call that
/// touches the playlist waits inside just_audio for a pending load (its
/// platform future resolves only after `load()`), so the adapter keeps two
/// views of the playlist:
///  * the *issued* model, updated synchronously by each command, which is
///    what callers query ([loadedItemIds], [hasItem], [queueLength]);
///  * the *applied* mirror, updated only as each native call completes,
///    from which native indices are computed and mapped back to items.
/// Native work runs in order on one internal chain. A new seed starts a new
/// generation: queued work of the old one is dropped and the seed does not
/// wait behind it. Pause, stop and volume go to the plugin directly (it
/// updates its own state synchronously), never behind the chain.
class JustAudioEngine implements PlaybackEngine {
  final ja.AudioPlayer _player;
  final StreamController<int?> _currentItemIdController =
      StreamController<int?>.broadcast();
  final StreamController<UnavailableAdvance> _unavailableAdvanceController =
      StreamController<UnavailableAdvance>.broadcast();
  final StreamController<EngineLoadEvent> _loadEventsController =
      StreamController<EngineLoadEvent>.broadcast();
  final StreamController<PlaybackObservation> _observationsController =
      StreamController<PlaybackObservation>.broadcast();
  final StreamController<EngineSourceFailure> _sourceFailuresController =
      StreamController<EngineSourceFailure>.broadcast();
  final List<StreamSubscription<Object?>> _pluginSubscriptions = [];
  final StreamController<EngineTransportState> _transportController =
      StreamController<EngineTransportState>.broadcast();
  EngineProcessingState _processing = EngineProcessingState.idle;
  EngineTransportState? _lastTransport;

  /// A queued play has reached the plugin (and no pause/stop came since).
  bool _playIssued = false;
  static int _runtimeCounter = 0;
  @override
  final int runtimeId = ++_runtimeCounter;
  int _sequence = 0;
  int _nextSourceId = 0;
  int? _sessionId;
  EngineSourceIdentity? _settled;
  List<_Source> _issued = const [];
  List<_Source> _applied = const [];
  StreamSubscription<int?>? _currentIndexSubscription;
  int? _committedCurrentItemId;
  int _playlistRevision = 0;
  int _generation = 0;
  int _pendingTransitions = 0;
  Future<void> _nativeTail = Future<void>.value();
  bool _wantPlaying = false;
  bool _isDisposed = false;

  /// Resolves the global offline-mode flag. When `true`, advances onto an
  /// entry without a verified local file are reported via
  /// [unavailableAdvanceStream] instead of being committed as the current
  /// item; the coordinator decides what to do next.
  final bool Function() _isOfflineFn;

  /// Audio focus gate at the single play() choke point (SC-27 invariant 5).
  final Future<bool> Function()? _beforePlay;

  /// Quality preset applied to NEW source URIs. Existing in-flight sources
  /// keep whatever quality they were created with — quality switches take
  /// effect at the next track boundary.
  String _streamQuality = originalQuality;

  JustAudioEngine(this._player, {bool Function()? isOfflineFn,
      Future<bool> Function()? beforePlay})
      : _isOfflineFn = isOfflineFn ?? (() => false),
        _beforePlay = beforePlay {
    _currentIndexSubscription = _player.currentIndexStream.listen(
      _onCurrentIndexChanged,
    );
    _pluginSubscriptions
      ..add(_player.playerStateStream.listen(_onPluginState))
      ..add(_player.positionStream.listen((_) => _observe()))
      ..add(_player.positionDiscontinuityStream.listen(_onDiscontinuity))
      ..add(_player.errorStream.listen(_onSourceError));
  }

  factory JustAudioEngine.create({
    bool Function()? isOfflineFn,
    Future<bool> Function()? beforePlay,
    ja.AudioPlayer Function({required bool handleInterruptions})? newPlayer,
  }) {
    // Interruptions and noisy output are routed through AudioFocus into
    // the playback core's commands, never handled by the plugin itself.
    final build = newPlayer ??
        ({required bool handleInterruptions}) =>
            ja.AudioPlayer(handleInterruptions: handleInterruptions);
    return JustAudioEngine(
      build(handleInterruptions: false),
      isOfflineFn: isOfflineFn,
      beforePlay: beforePlay,
    );
  }

  @override
  Future<void> setSeed(
    List<QueuePlaybackEntry> entries, {
    required int currentItemId,
    int? sessionId,
    PlaybackTransitionCause cause = PlaybackTransitionCause.queueReplacement,
    Duration initialPosition = Duration.zero,
    bool autoPlay = false,
    bool shuffleEnabled = false,
  }) async {
    if (_isDisposed) return;

    _sessionId = sessionId;
    final sources = _sortedEntries(entries).map(_newSource).toList();
    final localIndex = sources.indexWhere(
      (source) => source.entry.itemId == currentItemId,
    );
    if (localIndex < 0) {
      throw StateError('Current item is missing from the seeded player queue');
    }

    // A replacement: older queued native work is obsolete, and this seed
    // must not wait behind it (it may be stuck on a stalled load).
    final generation = ++_generation;
    final revision = ++_playlistRevision;
    _issued = sources;
    _applied = const [];
    _pendingTransitions = 1;
    _commitCurrentItem(currentItemId, emit: false);
    if (!autoPlay && !_playIssued) {
      // A queued play of the old seed is dropped with it.
      _wantPlaying = false;
      _emitTransport();
    }

    final seed = () async {
      try {
        final duration = await _player.setAudioSources(
          sources.map((source) => source.audio).toList(growable: false),
          initialIndex: localIndex,
          initialPosition: initialPosition,
        );
        if (generation != _generation) {
          _emitLoad(revision, EngineLoadOutcome.superseded);
          return;
        }
        _applied = _seeded(sources);
        _emitLoad(revision, EngineLoadOutcome.loaded, duration: duration);
      } on ja.PlayerInterruptedException {
        if (generation != _generation) {
          _emitLoad(revision, EngineLoadOutcome.superseded);
          return;
        }
        // A stop cut the load short; the playlist itself was set.
        _applied = _seeded(sources);
        _emitLoad(revision, EngineLoadOutcome.interrupted);
      } on ja.PlayerException catch (error) {
        if (generation != _generation) {
          _emitLoad(revision, EngineLoadOutcome.superseded);
          return;
        }
        // The playlist itself was set before the load failed.
        _applied = _seeded(sources);
        developer.log('Load failed', name: 'JustAudioEngine', error: error);
        _emitLoad(revision, EngineLoadOutcome.failed,
            errorCode: error.code, errorMessage: error.message);
      } catch (error, stackTrace) {
        developer.log('Load failed', name: 'JustAudioEngine',
            error: error, stackTrace: stackTrace);
        if (generation == _generation) {
          _applied = _seeded(sources);
          _emitLoad(revision, EngineLoadOutcome.failed,
              errorMessage: '$error');
        } else {
          _emitLoad(revision, EngineLoadOutcome.superseded);
        }
      } finally {
        if (generation == _generation) _transitionDone(cause);
      }
    }();
    _nativeTail = seed;

    if (autoPlay) {
      await play();
    }
  }

  @override
  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    if (_isDisposed || entries.isEmpty) return;

    final additions = _sortedEntries(entries
        .where((entry) => !hasItem(entry.itemId))
        .toList(growable: false))
        .map(_newSource)
        .toList(growable: false);
    if (additions.isEmpty) return;

    for (final source in additions) {
      _issued = _inserted(_issued, source);
    }
    _structural(PlaybackTransitionCause.queueEdit, (generation) async {
      for (final source in additions) {
        final latest = _latest(source);
        final index = _insertionIndexFor(_applied, latest.entry.playPosition);
        if (!await _nativeInsert(generation, index, latest)) return;
      }
    });
  }

  @override
  Future<void> replaceFutureEntries({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    if (_isDisposed) return;

    final currentIndex = _indexOf(_issued, currentItemId);
    if (currentIndex == null) {
      throw StateError('Current item is not loaded');
    }

    final additions =
        _sortedEntries(entries).map(_newSource).toList(growable: false);
    var issued = _issued.take(currentIndex + 1).toList();
    for (final source in additions) {
      issued = _inserted(issued, source);
    }
    _issued = issued;

    _structural(PlaybackTransitionCause.queueEdit, (generation) async {
      final appliedCurrent = _indexOf(_applied, currentItemId);
      if (appliedCurrent == null) return;
      for (var i = _applied.length - 1; i > appliedCurrent; i--) {
        if (!await _nativeRemove(generation, i)) return;
      }
      for (final source in additions) {
        final latest = _latest(source);
        final index = _insertionIndexFor(_applied, latest.entry.playPosition);
        if (!await _nativeInsert(generation, index, latest)) return;
      }
    });
  }

  @override
  Future<void> rebuildAroundCurrent({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    if (_isDisposed) return;

    final currentIndex = _indexOf(_issued, currentItemId);
    if (currentIndex == null) {
      throw StateError('Current item is not loaded');
    }

    final current = _issued[currentIndex];
    final sorted = _sortedEntries(entries);
    final desiredCurrentIndex = sorted.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (desiredCurrentIndex < 0) {
      throw StateError('Current item is missing from rebuilt queue');
    }
    // The playing source is kept; everything around it is rebuilt.
    final rebuilt = [
      for (var i = 0; i < sorted.length; i++)
        i == desiredCurrentIndex
            ? current.withEntry(sorted[i])
            : _newSource(sorted[i]),
    ];
    _issued = rebuilt;
    // The kept source is not native work: its new metadata (play position)
    // applies to the mirror at once.
    _applied = [
      for (final source in _applied)
        identical(source.audio, current.audio)
            ? source.withEntry(sorted[desiredCurrentIndex])
            : source,
    ];

    _structural(PlaybackTransitionCause.queueEdit, (generation) async {
      final appliedCurrent = _indexOf(_applied, currentItemId);
      if (appliedCurrent == null) return;
      for (var i = _applied.length - 1; i > appliedCurrent; i--) {
        if (!await _nativeRemove(generation, i)) return;
      }
      for (var i = 0; i < appliedCurrent; i++) {
        if (!await _nativeRemove(generation, 0)) return;
      }

      final prefix = rebuilt.take(desiredCurrentIndex).toList(growable: false);
      for (var i = 0; i < prefix.length; i++) {
        if (!await _nativeInsert(generation, i, _latest(prefix[i]))) return;
      }

      final suffix =
          rebuilt.skip(desiredCurrentIndex + 1).toList(growable: false);
      for (var i = 0; i < suffix.length; i++) {
        final index = prefix.length + 1 + i;
        if (!await _nativeInsert(generation, index, _latest(suffix[i]))) {
          return;
        }
      }
    });
  }

  @override
  Future<void> removeItem(int itemId) async {
    if (_isDisposed) return;

    final localIndex = _indexOf(_issued, itemId);
    if (localIndex == null) return;
    _issued = List<_Source>.from(_issued)..removeAt(localIndex);

    _structural(PlaybackTransitionCause.queueEdit, (generation) async {
      final index = _indexOf(_applied, itemId);
      if (index == null) return;
      await _nativeRemove(generation, index);
    });
  }

  @override
  void replaceLoadedEntriesMetadata(List<QueuePlaybackEntry> updatedEntries) {
    if (_isDisposed) return;

    _updateMetadata(
        {for (final entry in updatedEntries) entry.itemId: entry});
  }

  /// Metadata (play positions, file paths) is not native work: it applies to
  /// the issued model and the applied mirror at once, so native indices stay
  /// computed from current positions.
  void _updateMetadata(Map<int, QueuePlaybackEntry> byItemId) {
    List<_Source> updated(List<_Source> sources) => [
          for (final source in sources)
            source.withEntry(byItemId[source.entry.itemId] ?? source.entry),
        ];
    _issued = updated(_issued);
    _applied = updated(_applied);
  }

  /// Refresh loaded entry metadata AND rebuild any sources whose local-vs-
  /// streaming availability changed. Driven by `downloadStatusVersionProvider`
  /// changes — when a queued-ahead track gets downloaded mid-playback its
  /// already-built stream source has to flip to file://, and when a downloaded
  /// track is deleted its file:// source has to flip back to a stream (or be
  /// reported as unavailable if we're offline and it was the current item).
  ///
  /// Future-queue sources are replaced silently. The current source is only
  /// rebuilt when both kinds are playable from the player's perspective; if
  /// the current source was a local file that just disappeared and there's no
  /// streaming fallback available (offline), an [UnavailableAdvance] event is
  /// emitted so the coordinator can perform a full-queue rescue.
  @override
  Future<void> refreshLoadedSourcesForAvailabilityChanges(
    List<QueuePlaybackEntry> updatedEntries,
  ) async {
    if (_isDisposed || _issued.isEmpty) return;

    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    final currentItemId = _committedCurrentItemId;

    final changes = <_SourceAvailabilityChange>[];
    for (final old in _issued) {
      final newEntry = byItemId[old.entry.itemId] ?? old.entry;
      final oldKind = _sourceKindFor(old.entry);
      final newKind = _sourceKindFor(newEntry);
      if (oldKind == newKind && old.entry.filePath == newEntry.filePath) {
        continue;
      }
      final replacement = _newSource(newEntry);
      changes.add(_SourceAvailabilityChange(
        old: old,
        replacement: replacement,
        oldKind: oldKind,
        newKind: newKind,
      ));
    }

    if (changes.isEmpty) {
      _updateMetadata(byItemId);
      return;
    }

    // If the current source was a file that just disappeared and offline mode
    // would refuse to play the streaming replacement, hand off to the
    // coordinator's full-queue rescue rather than rebuilding to a stream that
    // can't actually play.
    final currentChange = currentItemId == null
        ? null
        : changes
            .where((c) => c.replacement.entry.itemId == currentItemId)
            .firstOrNull;
    final rescueTarget = (currentChange != null &&
            currentChange.oldKind == _SourceKind.file &&
            currentChange.newKind == _SourceKind.stream &&
            _isOfflineFn())
        ? currentChange
        : null;
    // Unchanged sources and the rescued current one keep their source and
    // take the new metadata; the others get rebuilt sources.
    final rebuilt = [
      for (final change in changes)
        if (!identical(change, rescueTarget)) change,
    ];
    _updateMetadata({
      for (final entry in updatedEntries)
        if (!rebuilt.any((c) => c.replacement.entry.itemId == entry.itemId))
          entry.itemId: entry,
    });
    _issued = [
      for (final source in _issued)
        rebuilt
                .where((c) => identical(c.old.audio, source.audio))
                .firstOrNull
                ?.replacement ??
            source,
    ];

    _structural(PlaybackTransitionCause.sourceRefresh, (generation) async {
      final currentPosition = _player.position;
      for (final change in rebuilt) {
        final index = _indexOfSource(_applied, change.old);
        if (index == null) continue;
        if (!await _nativeRemove(generation, index)) return;
        if (!await _nativeInsert(
            generation, index, _latest(change.replacement))) {
          return;
        }
      }
      if (rescueTarget == null &&
          currentChange != null &&
          currentItemId != null) {
        final localIndex = _indexOf(_applied, currentItemId);
        if (localIndex != null && _live(generation)) {
          await _player.seek(currentPosition, index: localIndex);
        }
      }
      if (rescueTarget != null) {
        _unavailableAdvanceController.add(UnavailableAdvance(
          itemId: rescueTarget.replacement.entry.itemId,
          playPosition: rescueTarget.replacement.entry.playPosition,
        ));
      }
    });
  }

  /// Whether [entry] should play from a local file. Decided purely from the
  /// DB-provided `file_path`: the DownloadReconciliationService is the single
  /// authority for whether a downloaded file is present (it nulls stale paths
  /// on startup and on every app resume), and app-initiated deletes null the
  /// path synchronously. Trusting it keeps this off the event loop — the old
  /// per-build/per-transition `File.existsSync()` blocked the isolate and could
  /// misclassify a present file as a stream on a transient stat failure.
  bool _hasLocalFile(QueuePlaybackEntry entry) {
    final localPath = entry.filePath;
    return localPath != null && localPath.isNotEmpty;
  }

  _SourceKind _sourceKindFor(QueuePlaybackEntry entry) {
    return _hasLocalFile(entry) ? _SourceKind.file : _SourceKind.stream;
  }

  @override
  Future<void> seekToItem(int itemId, {Duration position = Duration.zero,
      PlaybackTransitionCause cause = PlaybackTransitionCause.userSkip}) async {
    if (_isDisposed) return;
    if (_indexOf(_issued, itemId) == null) {
      throw StateError('Cannot seek to an item that has not been hydrated');
    }
    // The issued model moves at once (callers see the new current item);
    // observations settle on it once the plugin has applied the seek.
    _commitCurrentItem(itemId, emit: true);
    _enqueue((_) async {
      final index = _indexOf(_applied, itemId);
      if (index == null) return;
      await _player.seek(position, index: index);
    }, transitionCause: cause);
  }

  @override
  int? get currentItemId => _committedCurrentItemId;

  @override
  int get playlistRevision => _playlistRevision;

  @override
  Duration get position => _player.position;

  @override
  int get queueLength => _issued.length;

  @override
  List<int> get loadedItemIds =>
      _issued.map((source) => source.entry.itemId).toList(growable: false);

  @override
  bool hasItem(int itemId) => _indexOf(_issued, itemId) != null;

  /// Ordered after queued native work, but never awaited: just_audio's
  /// play() future lives as long as playback. A pause/stop issued meanwhile
  /// cancels it.
  @override
  Future<void> play() async {
    if (_isDisposed) return;
    _wantPlaying = true;
    _emitTransport();
    _enqueue((generation) async {
      if (!_wantPlaying) return;
      final beforePlay = _beforePlay;
      if (beforePlay != null && !await beforePlay()) {
        // Focus refused: no audio, so no desired play either (unless a newer
        // seed has taken over meanwhile).
        if (!_live(generation)) return;
        _wantPlaying = false;
        _emitTransport();
        return;
      }
      if (!_wantPlaying || !_live(generation)) return;
      _playIssued = true;
      unawaited(
        _player.play().catchError((Object error, StackTrace stackTrace) {
          developer.log(
            'Failed to start playback',
            name: 'JustAudioEngine',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    });
  }

  @override
  Future<void> pause() async {
    if (_isDisposed) return;
    _wantPlaying = false;
    _playIssued = false;
    _emitTransport();
    _direct(_player.pause(), 'pause');
  }

  @override
  Future<void> seek(Duration position) async {
    if (_isDisposed) return;
    _enqueue((_) => _player.seek(position),
        transitionCause: PlaybackTransitionCause.userSeek);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_isDisposed) return;
    _direct(_player.setVolume(volume), 'setVolume');
  }

  @override
  Future<void> stop() async {
    if (_isDisposed) return;
    _wantPlaying = false;
    _playIssued = false;
    _emitTransport();
    _direct(_player.stop(), 'stop');
    _observe(cause: PlaybackTransitionCause.stop);
  }

  @override
  Future<void> setLoopMode(EngineLoopMode mode) async {
    if (_isDisposed) return;
    _direct(
      _player.setLoopMode(switch (mode) {
        EngineLoopMode.off => ja.LoopMode.off,
        EngineLoopMode.all => ja.LoopMode.all,
        EngineLoopMode.one => ja.LoopMode.one,
      }),
      'setLoopMode',
    );
  }

  @override
  Stream<EngineTransportState> get transportStateStream =>
      _transportController.stream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;
  @override
  Stream<Duration?> get durationStream => _player.durationStream;
  @override
  Stream<int?> get currentItemIdStream => _currentItemIdController.stream;
  @override
  Stream<UnavailableAdvance> get unavailableAdvanceStream =>
      _unavailableAdvanceController.stream;
  @override
  Stream<EngineLoadEvent> get loadEvents => _loadEventsController.stream;
  @override
  Stream<EngineSourceFailure> get sourceFailures =>
      _sourceFailuresController.stream;
  @override
  Stream<PlaybackObservation> get observations =>
      _observationsController.stream;

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _generation++;
    unawaited(_currentIndexSubscription?.cancel());
    for (final sub in _pluginSubscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(_observationsController.close());
    unawaited(_sourceFailuresController.close());
    unawaited(_transportController.close());
    unawaited(_currentItemIdController.close());
    unawaited(_unavailableAdvanceController.close());
    unawaited(_loadEventsController.close());
    unawaited(_player.dispose());
  }

  /// Update the quality applied to subsequent source builds. Existing
  /// in-flight sources are not rebuilt — the change takes effect on the next
  /// track loaded into the queue.
  @override
  void setStreamQuality(String quality) {
    _streamQuality = quality;
  }

  /// Replace only the currently-playing source with one built at [quality]
  /// and seek to [seekTo]. Used for temporary quality changes so the current
  /// track rebuffers at the new quality without touching the rest of the queue.
  @override
  Future<void> rebuildCurrentSource(String quality, Duration seekTo) async {
    if (_isDisposed) return;
    final currentItemId = _committedCurrentItemId;
    if (currentItemId == null) return;
    final localIndex = _indexOf(_issued, currentItemId);
    if (localIndex == null) return;

    _streamQuality = quality;
    final old = _issued[localIndex];
    final replacement = _newSource(old.entry);
    _issued = List<_Source>.from(_issued)..[localIndex] = replacement;

    _structural(PlaybackTransitionCause.qualityRebuild, (generation) async {
      final index = _indexOfSource(_applied, old);
      if (index == null) return;
      if (!await _nativeRemove(generation, index)) return;
      if (!await _nativeInsert(generation, index, _latest(replacement))) {
        return;
      }
      await _player.seek(seekTo, index: index);
    });
  }

  /// Replace all loaded sources with ones built at [quality] and seek to
  /// [seekTo] in the current track. Used for full quality changes so the entire
  /// ahead-buffered window rebuffers at the new quality.
  @override
  Future<void> rebuildAllSources(String quality, Duration seekTo) async {
    if (_isDisposed) return;
    final currentItemId = _committedCurrentItemId;
    if (currentItemId == null) return;
    if (_indexOf(_issued, currentItemId) == null) return;

    _streamQuality = quality;
    final rebuilt = [for (final source in _issued) _newSource(source.entry)];
    _issued = rebuilt;

    _structural(PlaybackTransitionCause.qualityRebuild, (generation) async {
      final count = _applied.length;
      for (var i = 0; i < count; i++) {
        if (!await _nativeRemove(generation, 0)) return;
      }
      for (var i = 0; i < rebuilt.length; i++) {
        if (!await _nativeInsert(generation, i, _latest(rebuilt[i]))) return;
      }
      final index = _indexOf(_applied, currentItemId);
      if (index != null && _live(generation)) {
        await _player.seek(seekTo, index: index);
      }
    });
  }

  /// Queues native work behind earlier native work of this generation. A
  /// work item with a [transitionCause] moves playback: until it (and every
  /// other pending transition) is applied, observations are uncertain.
  void _enqueue(Future<void> Function(int generation) action,
      {PlaybackTransitionCause? transitionCause}) {
    final generation = _generation;
    if (transitionCause != null) _pendingTransitions++;
    _nativeTail = _nativeTail.then((_) async {
      if (generation != _generation || _isDisposed) return;
      try {
        await action(generation);
      } catch (error, stackTrace) {
        developer.log('Native command failed', name: 'JustAudioEngine',
            error: error, stackTrace: stackTrace);
      }
    }).whenComplete(() {
      if (transitionCause != null && generation == _generation) {
        _transitionDone(transitionCause);
      }
    });
  }

  /// A structural change: the issued model already reflects it and keeps
  /// the caller-visible current item (no churn is emitted).
  void _structural(PlaybackTransitionCause cause,
      Future<void> Function(int generation) action) {
    _playlistRevision++;
    _enqueue(action, transitionCause: cause);
  }

  /// When the last pending transition is applied, observations settle on
  /// the source the plugin now reports, mapped through the applied mirror
  /// (provisional rule A1: the plugin reports index shifts in order). If
  /// that is not the expected current item, the plugin advanced meanwhile.
  void _transitionDone(PlaybackTransitionCause cause) {
    _pendingTransitions--;
    if (_pendingTransitions > 0 || _isDisposed) return;
    final expected = _committedCurrentItemId;
    final nativeIndex = _player.currentIndex;
    final native = _itemIdForIndex(nativeIndex);
    var settledCause = cause;
    if (native != null && native != expected) {
      settledCause = PlaybackTransitionCause.naturalAdvance;
      if (_isOfflineFn() && !_isIndexLocallyPlayable(nativeIndex!)) {
        // Same rule as a direct index event: the core picks the target.
        final unavailable = _applied[nativeIndex].entry;
        _unavailableAdvanceController.add(UnavailableAdvance(
          itemId: unavailable.itemId,
          playPosition: unavailable.playPosition,
        ));
        // The core is rescuing: nothing trustworthy to attribute yet.
        _emitObservation(_settled, cause: settledCause, uncertain: true);
        return;
      }
      _commitCurrentItem(native, emit: true);
    }
    final settledIndex = native != null
        ? nativeIndex
        : (expected == null ? null : _indexOf(_applied, expected));
    _settled = _identityAt(settledIndex);
    _emitObservation(_settled, cause: settledCause, uncertain: false);
  }

  /// The desired transport is the engine's own (a queued play waits behind
  /// the load, so the plugin reports `playing` late) and changes with the
  /// engine's commands; the processing state is the plugin's. A play the
  /// plugin reverted (audio-session activation failed) clears it.
  void _onPluginState(ja.PlayerState state) {
    _processing = _processingFrom(state.processingState);
    if (_processing == EngineProcessingState.completed && _wantPlaying) {
      // The queue ended. just_audio keeps `playing` true at completion (a
      // later seed would start audibly, a later play() would be a no-op),
      // so the engine pauses it: nothing is desired any more.
      _wantPlaying = false;
      _playIssued = false;
      _direct(_player.pause(), 'pause');
    }
    if (_playIssued &&
        !_player.playing &&
        _processing != EngineProcessingState.completed) {
      _playIssued = false;
      _wantPlaying = false;
    }
    _emitTransport();
    _observe();
  }

  void _emitTransport() {
    final next = EngineTransportState(_wantPlaying, _processing);
    if (next == _lastTransport || _transportController.isClosed) return;
    _lastTransport = next;
    _transportController.add(next);
  }

  /// Raw failure of one source, with its identity (classification and
  /// recovery belong to the playback core).
  void _onSourceError(ja.PlayerException error) {
    if (_isDisposed || _sourceFailuresController.isClosed) return;
    final uncertain = _pendingTransitions > 0;
    final failure = EngineSourceFailure(
      playlistRevision: _playlistRevision,
      source: uncertain ? null : _identityAt(error.index ?? _player.currentIndex),
      uncertain: uncertain,
      errorCode: error.code,
      errorMessage: error.message,
    );
    developer.log('Source failed: ${failure.source} ${error.code}',
        name: 'JustAudioEngine', error: error);
    _sourceFailuresController.add(failure);
  }

  void _onDiscontinuity(ja.PositionDiscontinuity discontinuity) {
    if (_isDisposed ||
        _pendingTransitions > 0 ||
        discontinuity.reason != ja.PositionDiscontinuityReason.autoAdvance) {
      return; // explicit seeks are stamped by the command that issued them
    }
    final previous = _identityAt(discontinuity.previousEvent.currentIndex);
    final current = _identityAt(discontinuity.event.currentIndex);
    if (current == null) return;
    _settled = current;
    _emitObservation(
      current,
      cause: previous?.sourceId == current.sourceId
          ? PlaybackTransitionCause.repeatOneRestart
          : PlaybackTransitionCause.naturalAdvance,
      uncertain: false,
    );
  }

  /// An observation of the plugin's state now. While a transition is
  /// pending its index may refer to the old playlist: uncertain, carrying
  /// the last settled identity.
  void _observe({int? index, PlaybackTransitionCause? cause}) {
    if (_isDisposed) return;
    if (_pendingTransitions > 0) {
      _emitObservation(_settled, cause: cause, uncertain: true);
      return;
    }
    _settled = _identityAt(index ?? _player.currentIndex);
    _emitObservation(_settled, cause: cause, uncertain: false);
  }

  void _emitObservation(EngineSourceIdentity? source,
      {required PlaybackTransitionCause? cause, required bool uncertain}) {
    if (_observationsController.isClosed) return;
    _observationsController.add(PlaybackObservation(
      runtimeId: runtimeId,
      sequence: ++_sequence,
      playlistRevision: _playlistRevision,
      source: source,
      position: _player.position,
      duration: _player.duration,
      playing: _player.playing,
      processingState: _processingFrom(_player.processingState),
      transitionCause: cause,
      rate: _player.speed,
      uncertain: uncertain,
    ));
  }

  EngineSourceIdentity? _identityAt(int? index) {
    if (index == null || index < 0 || index >= _applied.length) return null;
    return _applied[index].identity;
  }

  static EngineProcessingState _processingFrom(ja.ProcessingState state) =>
      switch (state) {
        ja.ProcessingState.idle => EngineProcessingState.idle,
        ja.ProcessingState.loading => EngineProcessingState.loading,
        ja.ProcessingState.buffering => EngineProcessingState.buffering,
        ja.ProcessingState.ready => EngineProcessingState.ready,
        ja.ProcessingState.completed => EngineProcessingState.completed,
      };

  /// Whether work of [generation] may still touch the plugin: a newer seed
  /// (or dispose) makes it stale, also between the steps of one action.
  bool _live(int generation) => generation == _generation && !_isDisposed;

  /// Inserts natively and mirrors it, unless the work went stale meanwhile.
  /// (Each action starts live: the queue checks its generation first.)
  Future<bool> _nativeInsert(int generation, int index, _Source source) async {
    await _player.insertAudioSource(index, source.audio);
    if (!_live(generation)) return false;
    // Mirror the metadata current now, not as of the call.
    _applied = List<_Source>.from(_applied)..insert(index, _latest(source));
    return true;
  }

  /// Removes natively and mirrors it, unless the work went stale.
  Future<bool> _nativeRemove(int generation, int index) async {
    await _player.removeAudioSourceAt(index);
    if (!_live(generation)) return false;
    _applied = List<_Source>.from(_applied)..removeAt(index);
    return true;
  }

  /// The seeded playlist as the mirror records it: metadata applied to the
  /// issued model while the load was pending (a rebuild's kept source, a
  /// reorder) is kept.
  List<_Source> _seeded(List<_Source> sources) =>
      [for (final source in sources) _latest(source)];

  /// [source] with the metadata the issued model has now (play positions
  /// can change between issuing an insert and applying it).
  _Source _latest(_Source source) =>
      _issued.where((s) => identical(s.audio, source.audio)).firstOrNull ??
      source;

  void _direct(Future<void> command, String name) {
    unawaited(command.catchError((Object error, StackTrace stackTrace) {
      developer.log('Failed to $name', name: 'JustAudioEngine',
          error: error, stackTrace: stackTrace);
    }));
  }

  void _emitLoad(int revision, EngineLoadOutcome outcome,
      {Duration? duration, int? errorCode, String? errorMessage}) {
    if (_loadEventsController.isClosed) return;
    _loadEventsController.add(EngineLoadEvent(
      playlistRevision: revision,
      outcome: outcome,
      duration: duration,
      errorCode: errorCode,
      errorMessage: errorMessage,
    ));
  }

  _Source _newSource(QueuePlaybackEntry entry) => _Source(
        entry,
        _audioSourceFor(entry),
        EngineSourceIdentity(
          sourceId: ++_nextSourceId,
          sessionId: _sessionId,
          itemId: entry.itemId,
          trackUuid: entry.uuidId,
        ),
      );

  ja.AudioSource _audioSourceFor(QueuePlaybackEntry entry) {
    if (_hasLocalFile(entry)) {
      // Local file is always served verbatim — quality preset doesn't apply.
      return ja.AudioSource.uri(
        Uri.file(entry.filePath!),
        tag: entry.itemId,
      );
    }
    return ja.AudioSource.uri(
      buildTrackStreamUri(entry.uuidId, quality: _streamQuality),
      tag: entry.itemId,
    );
  }

  static int? _indexOf(List<_Source> sources, int itemId) {
    final index = sources.indexWhere((source) => source.entry.itemId == itemId);
    return index < 0 ? null : index;
  }

  static int? _indexOfSource(List<_Source> sources, _Source source) {
    final index = sources.indexWhere((s) => identical(s.audio, source.audio));
    return index < 0 ? null : index;
  }

  static List<_Source> _inserted(List<_Source> sources, _Source source) =>
      List<_Source>.from(sources)
        ..insert(_insertionIndexFor(sources, source.entry.playPosition), source);

  static int _insertionIndexFor(List<_Source> sources, int playPosition) {
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].entry.playPosition > playPosition) {
        return i;
      }
    }
    return sources.length;
  }

  static List<QueuePlaybackEntry> _sortedEntries(
    List<QueuePlaybackEntry> entries,
  ) {
    final sorted = List<QueuePlaybackEntry>.from(entries);
    sorted.sort((a, b) => a.playPosition.compareTo(b.playPosition));
    return sorted;
  }

  void _onCurrentIndexChanged(int? index) {
    // While a transition is being applied the native index may still refer
    // to the old playlist; it is not trusted.
    if (_isDisposed) return;
    if (_pendingTransitions > 0) {
      _observe(index: index);
      return;
    }
    // Offline: don't commit an index whose source has no verified local file.
    // Report it upward so the coordinator can search the full queue (not just
    // what we currently have loaded) for the next locally playable entry.
    if (index != null && _isOfflineFn() && !_isIndexLocallyPlayable(index)) {
      if (index >= 0 && index < _applied.length) {
        final unavailable = _applied[index].entry;
        _unavailableAdvanceController.add(UnavailableAdvance(
          itemId: unavailable.itemId,
          playPosition: unavailable.playPosition,
        ));
      }
      return;
    }
    _commitCurrentItem(_itemIdForIndex(index), emit: true);
    _observe(index: index);
  }

  bool _isIndexLocallyPlayable(int index) {
    if (index < 0 || index >= _applied.length) return false;
    return _hasLocalFile(_applied[index].entry);
  }

  void _commitCurrentItem(int? itemId, {required bool emit}) {
    final changed = _committedCurrentItemId != itemId;
    _committedCurrentItemId = itemId;
    if (emit && changed) {
      _currentItemIdController.add(itemId);
    }
  }

  int? _itemIdForIndex(int? index) {
    if (index == null || index < 0 || index >= _applied.length) {
      return null;
    }
    return _applied[index].entry.itemId;
  }
}

/// One created plugin source and the queue entry it plays.
class _Source {
  const _Source(this.entry, this.audio, this.identity);
  final QueuePlaybackEntry entry;
  final ja.AudioSource audio;
  final EngineSourceIdentity identity;

  /// Metadata changes keep the created source and its identity.
  _Source withEntry(QueuePlaybackEntry entry) => _Source(entry, audio, identity);
}

enum _SourceKind { file, stream }

class _SourceAvailabilityChange {
  final _Source old;
  final _Source replacement;
  final _SourceKind oldKind;
  final _SourceKind newKind;

  const _SourceAvailabilityChange({
    required this.old,
    required this.replacement,
    required this.oldKind,
    required this.newKind,
  });
}
