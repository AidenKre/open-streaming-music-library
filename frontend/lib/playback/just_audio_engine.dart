import 'dart:async';
import 'dart:developer' as developer;

import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/api/token_permit.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/playback/preview_engine.dart';
import 'package:frontend/playback/track_cache_manager.dart';
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
class JustAudioEngine implements PlaybackEngine, MediaTokenSources {
  final ja.AudioPlayer _player;
  /// Base URL of the scope's server, used to build stream source URIs.
  final String _streamBaseUrl;
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
  final StreamController<EngineCommandFailure> _commandFailuresController =
      StreamController<EngineCommandFailure>.broadcast();
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

  /// The plugin's index and item, in order, since the last proven report
  /// (7-R1-05 / 7P.1 R1-06): `_trail.first` is the last proven entry, then
  /// one entry per native step that moves the plugin's index or item. just_audio
  /// keeps its Dart-side `currentIndex` until the platform reports the new
  /// one, after `removeAt`/`insert`/an indexed seek. An index report must be
  /// explained by the queue as it was when the command that caused it was
  /// issued, never by the queue as it is now; a report no issued command or
  /// natural advance explains is a failure to rebuild from. Steps are
  /// recorded at issue (a report may arrive before the call returns) and
  /// reports are consumed in order, the smallest matching index first (an
  /// ambiguous value reads as the older step). A reported index whose
  /// matched entry names the committed item is certain on it whichever step
  /// it belongs to; a settle read or a position tick sees only the Dart-side
  /// value an edit may not have moved yet, so it stays uncertain. [_pluginLost]: the
  /// plugin's own (only) source was removed, so nothing it reports is
  /// explained until the next indexed seek or seed.
  List<({int index, int? itemId})> _trail = [];
  bool _pluginLost = false;
  int _playlistRevision = 0;
  int _seedRevision = 0;

  /// A native command failed in this generation: the plugin's playlist is
  /// no longer proven to match the mirror. Nothing it reports is trusted
  /// until the next seed rebuilds it.
  bool _diverged = false;

  /// Bumped by play, pause and stop: a play failure is reported only while
  /// that play is still the latest.
  int _playToken = 0;

  /// The loop mode last asked of the plugin (it explains an index wrap).
  EngineLoopMode _requestedLoopMode = EngineLoopMode.off;
  int _generation = 0;
  int _pendingTransitions = 0;
  Future<void> _nativeTail = Future<void>.value();

  /// Completes when the current generation is replaced or the engine is
  /// disposed: whoever waits on its native work stops waiting.
  Completer<void> _generationEnded = Completer<void>();
  bool _wantPlaying = false;
  bool _isDisposed = false;

  /// Resolves the global offline-mode flag. When `true`, advances onto an
  /// entry without a verified local file are reported via
  /// [unavailableAdvanceStream] instead of being committed as the current
  /// item; the queue player decides what to do next.
  final bool Function() _isOfflineFn;

  /// Audio focus gate at the single play() choke point (SC-27 invariant 5).
  final Future<bool> Function()? _beforePlay;

  /// Whether an entry plays from its download (shared with the resolver
  /// and the queue player).
  final LocalSourcePolicy _localSources;

  /// Quality preset applied to NEW source URIs. Existing in-flight sources
  /// keep whatever quality they were created with — quality switches take
  /// effect at the next track boundary.
  String _streamQuality = originalQuality;

  /// The scope's media token, sent as `access_token` on stream URIs only
  /// (spec 7.3); local files never carry it.
  final String? _streamMediaToken;

  /// Whether the media token may go into a stream URL (sign-off OPEN-M-11
  /// step D). No permit: never. It is consulted when a source is BUILT, not
  /// when the native player fetches it: a URL already handed to the native
  /// player cannot be withdrawn except by replacing the source, as
  /// [releaseRemoteSources] does.
  final TokenPermit? _mediaTokenPermit;

  final void Function(String message) _logSink;

  static void _defaultLog(String message) =>
      developer.log(message, name: 'JustAudioEngine');

  /// Logs [what] with the error's text, redacted: player errors can quote the
  /// stream URL and its token (spec 7.2). Stack traces are left out.
  void _logError(String what, Object error) =>
      _logSink(_scrub('$what: $error'));

  /// [redactAccessToken], plus this engine's literal media token wherever it
  /// appears (a plugin may quote it outside a URL).
  String _scrub(String text) {
    final redacted = redactAccessToken(text);
    final token = _streamMediaToken;
    return token == null || token.isEmpty
        ? redacted
        : redacted.replaceAll(token, '<redacted>');
  }

  JustAudioEngine(this._player, {bool Function()? isOfflineFn,
      Future<bool> Function()? beforePlay, LocalSourcePolicy? localSources,
      String streamBaseUrl = '',
      String? streamMediaToken, void Function(String message)? log,
      TokenPermit? mediaTokenPermit})
      : _mediaTokenPermit = mediaTokenPermit,
        _streamBaseUrl = streamBaseUrl,
        _streamMediaToken = streamMediaToken,
        _logSink = log ?? _defaultLog,
        _isOfflineFn = isOfflineFn ?? (() => false),
        _beforePlay = beforePlay,
        _localSources = localSources ?? LocalSourcePolicy() {
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
    String streamBaseUrl = '',
    String? streamMediaToken,
    bool Function()? isOfflineFn,
    Future<bool> Function()? beforePlay,
    LocalSourcePolicy? localSources,
    TokenPermit? mediaTokenPermit,
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
      localSources: localSources,
      streamBaseUrl: streamBaseUrl,
      streamMediaToken: streamMediaToken,
      mediaTokenPermit: mediaTokenPermit,
    );
  }

  /// The next verification (sign-off OPEN-M-11 step D): every stream source
  /// built without the media token, the committed current item included, is
  /// replaced natively by one with it when the permit now allows it. The
  /// current item is safe to replace: a source built without the token cannot
  /// be playing (the server refuses it), so replacing it interrupts nothing
  /// and, without it, Play would stay a dead end. It is seeked back to its
  /// position. Nothing to do: no structural work.
  @override
  Future<void> refreshWithheldMediaTokens() async {
    if (_isDisposed) return;
    final currentItemId = _committedCurrentItemId;
    final position = _player.position;
    final changes = <({_Source old, _Source replacement})>[];
    for (final old in _issued) {
      if (!old.tokenWithheld) continue;
      final built = _streamAudio(old.entry);
      if (built.withheld) continue;
      changes.add((
        old: old,
        replacement: old.withAudio(built.audio, tokenWithheld: false),
      ));
    }
    if (changes.isEmpty) return;
    if ((_failedSinceLoad || _pauseFailedSinceSeed) &&
        changes.any((c) => c.old.entry.itemId == currentItemId)) {
      // The same reset a new seed does (see [setSeed]): after a source error
      // the plugin sits deactivated and would not start the replaced source.
      _failedSinceLoad = false;
      _pauseFailedSinceSeed = false;
      _playIssued = false;
      unawaited(_player.stop().catchError((Object error) {
        _logError('Reset stop failed', error);
      }));
    }
    _issued = [
      for (final source in _issued)
        changes
                .where((c) => identical(c.old.audio, source.audio))
                .firstOrNull
                ?.replacement ??
            source,
    ];
    _structural(PlaybackTransitionCause.sourceRefresh, (generation) async {
      for (final change in changes) {
        final index = _indexOfSource(_applied, change.old);
        if (index == null) continue;
        if (!await _nativeRemove(generation, index)) return;
        if (!await _nativeInsert(
            generation, index, _latest(change.replacement))) {
          return;
        }
        if (change.old.entry.itemId == currentItemId && _live(generation)) {
          await _nativeSeek(position, _targetOf(_applied[index]),
              index: index);
        }
      }
    });
  }

  /// The server is not (or no longer) the verified one (sign-off OPEN-M-11
  /// step D): every stream source that carries the media token is replaced by
  /// one built without it. With [includeCurrent] false the committed current
  /// item's source is left alone; with true it is replaced too and seeked back
  /// to its position (the caller stops a remote current item first, in the
  /// queue player's lane: this never stops). Local files are never touched.
  /// A URL already handed to the native player cannot be withdrawn any other
  /// way. The permit is consulted when a source is built, not when the
  /// native player fetches it.
  @override
  Future<void> releaseRemoteSources({required bool includeCurrent}) async {
    if (_isDisposed) return;
    final currentItemId = _committedCurrentItemId;
    final currentAt =
        currentItemId == null ? null : _indexOf(_issued, currentItemId);
    final currentIsStream = includeCurrent &&
        currentAt != null &&
        _issued[currentAt].identity.localPath == null;
    final position = _player.position;
    final token = _streamMediaToken;
    if (token == null || token.isEmpty) return;
    final changes = <({_Source old, _Source replacement})>[];
    for (final old in _issued) {
      if (old.identity.localPath != null || old.tokenWithheld) continue;
      if (!includeCurrent && old.entry.itemId == currentItemId) continue;
      final built = _streamAudio(old.entry, allowToken: false);
      changes.add((
        old: old,
        replacement: old.withAudio(built.audio, tokenWithheld: true),
      ));
    }
    if (changes.isEmpty) return;
    _issued = [
      for (final source in _issued)
        changes
                .where((c) => identical(c.old.audio, source.audio))
                .firstOrNull
                ?.replacement ??
            source,
    ];
    _structural(PlaybackTransitionCause.sourceRefresh, (generation) async {
      for (final change in changes) {
        final index = _indexOfSource(_applied, change.old);
        if (index == null) continue;
        if (!await _nativeRemove(generation, index)) return;
        if (!await _nativeInsert(
            generation, index, _latest(change.replacement))) {
          return;
        }
        if (currentIsStream &&
            change.old.entry.itemId == currentItemId &&
            _live(generation)) {
          await _nativeSeek(position, _targetOf(_applied[index]),
              index: index);
        }
      }
    });
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
    PlaybackSourceKind? currentSourceKind,
  }) async {
    if (_isDisposed) return;

    if (!entries.any((entry) => entry.itemId == currentItemId)) {
      // Rejected before anything changes (the session identity included).
      throw StateError('Current item is missing from the seeded player queue');
    }
    _sessionId = sessionId;
    final sources = _sortedEntries(entries)
        .map((entry) => _newSource(entry,
            kind: entry.itemId == currentItemId ? currentSourceKind : null))
        .toList();
    final localIndex = sources.indexWhere(
      (source) => source.entry.itemId == currentItemId,
    );

    // A replacement: older queued native work is obsolete, and this seed
    // must not wait behind it (it may be stuck on a stalled load).
    _heldFailure = null; // a failure of the replaced playlist
    _generationEnded.complete();
    _generationEnded = Completer<void>();
    final generation = ++_generation;
    final revision = ++_playlistRevision;
    _seedRevision = revision;
    _diverged = false;
    _trail = [(index: localIndex, itemId: currentItemId)];
    _pluginLost = false;
    _issued = sources;
    _applied = const [];
    _pendingTransitions = 1;
    _commitCurrentItem(currentItemId, emit: false);
    if (!autoPlay && !_playIssued) {
      // A queued play of the old seed is dropped with it.
      _wantPlaying = false;
      _emitTransport();
    }
    if (_failedSinceLoad || _pauseFailedSinceSeed) {
      // Live gate (2026-11-07, macOS): after a source error the plugin sits
      // deactivated, or stuck loading the dead source, with `playing` still
      // true, so a seek, a play or a plain new seed never starts the next
      // item (a new load would also interrupt the stuck activation). A stop
      // resets it; just_audio applies it synchronously, before the load
      // below. It is not a reverted play: the desired transport (decided
      // just above) stays.
      _failedSinceLoad = false;
      _pauseFailedSinceSeed = false;
      _playIssued = false;
      unawaited(_player.stop().catchError((Object error) {
        _logError('Reset stop failed', error);
      }));
    }

    final seedSource = sources[localIndex].identity;
    final seed = () async {
      var handed = sources;
      try {
        if (sources[localIndex].tokenWithheld) {
          // The current source was built without the token while a verdict
          // was pending: wait for it (bounded by the gate), then take the
          // token if it is now allowed. Withheld neighbours alone never
          // wait: the next verification refreshes them.
          try {
            await _mediaTokenPermit?.verdictSettled();
          } catch (_) {}
          if (generation != _generation) {
            _emitLoad(revision, EngineLoadOutcome.superseded,
                source: seedSource);
            return;
          }
          handed = _withPermittedTokens(sources);
        }
        final duration = await _player.setAudioSources(
          handed.map((source) => source.audio).toList(growable: false),
          initialIndex: localIndex,
          initialPosition: initialPosition,
        );
        if (generation != _generation) {
          _emitLoad(revision, EngineLoadOutcome.superseded, source: seedSource);
          return;
        }
        _applied = _seeded(handed);
        _emitLoad(revision, EngineLoadOutcome.loaded,
            duration: duration, source: seedSource);
      } on ja.PlayerInterruptedException {
        if (generation != _generation) {
          _emitLoad(revision, EngineLoadOutcome.superseded, source: seedSource);
          return;
        }
        // A stop cut the load short; the playlist itself was set.
        _applied = _seeded(handed);
        _emitLoad(revision, EngineLoadOutcome.interrupted, source: seedSource);
      } on ja.PlayerException catch (error) {
        if (generation != _generation) {
          _emitLoad(revision, EngineLoadOutcome.superseded, source: seedSource);
          return;
        }
        // The playlist itself was set before the load failed.
        _applied = _seeded(handed);
        // The load event is this failure's report; the copy the plugin also
        // put on its error stream (Android) is not re-reported at settle.
        _heldFailure = null;
        _failedSinceLoad = true;
        _logError('Load failed', error);
        _emitLoad(revision, EngineLoadOutcome.failed,
            errorCode: error.code,
            errorMessage: _redacted(error.message),
            source: seedSource);
      } catch (error) {
        _logError('Load failed', error);
        if (generation == _generation) {
          _applied = _seeded(handed);
          _heldFailure = null; // reported by the load event
          _emitLoad(revision, EngineLoadOutcome.failed,
              errorMessage: _redacted('$error'),
              source: seedSource);
        } else {
          _emitLoad(revision, EngineLoadOutcome.superseded, source: seedSource);
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
  /// emitted so the queue player can perform a full-queue rescue. A source
  /// whose rule verdict is unchanged keeps its applied kind (a resolver's
  /// remote choice included).
  @override
  Future<void> refreshLoadedSourcesForAvailabilityChanges(
    List<QueuePlaybackEntry> updatedEntries,
  ) async {
    if (_isDisposed || _issued.isEmpty) return;

    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    final currentItemId = _committedCurrentItemId;

    final changes = <_SourceAvailabilityChange>[];
    // Sources whose verdict changed but whose applied source already matches:
    // no rebuild, but the new verdict is recorded (so a later change back is
    // seen as one).
    final renewed = <ja.AudioSource, String?>{};
    for (final old in _issued) {
      final newEntry = byItemId[old.entry.itemId] ?? old.entry;
      // An unchanged rule verdict is metadata only: the source keeps its
      // applied kind.
      if (_localSources.localPathFor(newEntry) == old.plannedPath) {
        continue;
      }
      // What the source was built from, not what its entry says now: the
      // policy may have changed its mind about the same entry (a suspect).
      final oldPath = old.identity.localPath;
      final oldKind = oldPath != null ? _SourceKind.file : _SourceKind.stream;
      final newKind = _sourceKindFor(newEntry);
      if (oldKind == newKind && oldPath == _localSources.localPathFor(newEntry)) {
        renewed[old.audio] = _localSources.localPathFor(newEntry);
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

    void renewPlans() {
      if (renewed.isEmpty) return;
      List<_Source> renew(List<_Source> sources) => [
            for (final source in sources)
              renewed.containsKey(source.audio)
                  ? source.withPlanned(renewed[source.audio])
                  : source,
          ];
      _issued = renew(_issued);
      _applied = renew(_applied);
    }

    if (changes.isEmpty) {
      _updateMetadata(byItemId);
      renewPlans();
      return;
    }

    // If the current source was a file that just disappeared and offline mode
    // would refuse to play the streaming replacement, hand off to the
    // queue player's full-queue rescue rather than rebuilding to a stream that
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
    renewPlans();
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
          await _nativeSeek(
              currentPosition, _targetOf(_applied[localIndex]),
              index: localIndex);
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

  /// The rule's provisional plan for [entry] ([LocalSourcePolicy], no file
  /// check), used only for sources nobody landed on. A landing's kind comes
  /// from the resolver (`PlaybackTargetResolver`, SC-27 §6) via
  /// `setSeed(currentSourceKind)`, and rebuilds keep the applied kind
  /// (`_rebuilt`).
  bool _hasLocalFile(QueuePlaybackEntry entry) =>
      _localSources.localPathFor(entry) != null;

  _SourceKind _sourceKindFor(QueuePlaybackEntry entry) {
    return _hasLocalFile(entry) ? _SourceKind.file : _SourceKind.stream;
  }

  @override
  PlaybackSourceKind? sourceKindOf(int itemId) {
    final at = _indexOf(_issued, itemId);
    return at == null ? null : _issued[at].identity.sourceKind;
  }

  @override
  Future<void> seekToItem(int itemId, {Duration position = Duration.zero,
      PlaybackTransitionCause cause = PlaybackTransitionCause.userSkip}) async {
    if (_isDisposed) return;
    if (_indexOf(_issued, itemId) == null) {
      throw StateError('Cannot seek to an item that has not been hydrated');
    }
    // A failure held for the item being left is not the target's (review
    // 2026-11-07): the core has moved on, and at the seek's settle it would
    // be blamed on the wrong source.
    if (itemId != _committedCurrentItemId) _heldFailure = null;
    // The issued model moves at once (callers see the new current item);
    // observations settle on it once the plugin has applied the seek.
    _commitCurrentItem(itemId, emit: true);
    _enqueue((_) async {
      final index = _indexOf(_applied, itemId);
      if (index == null) return;
      await _nativeSeek(position, _targetOf(_applied[index]), index: index);
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
    final token = ++_playToken;
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
        _player.play().catchError((Object error) {
          _logError('Failed to start playback', error);
          if (token != _playToken || !_live(generation)) return;
          _wantPlaying = false;
          _playIssued = false;
          _emitTransport();
          _emitFailure(_NativeStepError(
              EngineCommand.play, _currentTarget(), error), null,
              diverged: false);
        }),
      );
    });
  }

  @override
  Future<void> pause() async {
    if (_isDisposed) return;
    _wantPlaying = false;
    _playIssued = false;
    _playToken++;
    _emitTransport();
    _direct(_player.pause(), 'pause', command: EngineCommand.pause);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_isDisposed) return;
    _enqueue((_) {
      final current = _committedCurrentItemId;
      final at = current == null ? null : _indexOf(_issued, current);
      return _nativeSeek(position, at == null ? null : _targetOf(_issued[at]));
    }, transitionCause: PlaybackTransitionCause.userSeek);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_isDisposed) return;
    _direct(_player.setVolume(volume), 'setVolume',
        command: EngineCommand.setVolume);
  }

  @override
  Future<void> stop() async {
    if (_isDisposed) return;
    _wantPlaying = false;
    _playIssued = false;
    _heldFailure = null; // stopped: nothing left to recover
    _emitTransport();
    _playToken++;
    _direct(_player.stop(), 'stop', command: EngineCommand.stop);
    if (_diverged || _reportsPending) {
      // A stop is a real boundary even when nothing else is trusted.
      _emitObservation(_settled,
          cause: PlaybackTransitionCause.stop, uncertain: false);
    } else {
      _observe(cause: PlaybackTransitionCause.stop);
    }
  }

  @override
  Future<void> setLoopMode(EngineLoopMode mode) async {
    if (_isDisposed) return;
    _requestedLoopMode = mode;
    _direct(
      _player.setLoopMode(switch (mode) {
        EngineLoopMode.off => ja.LoopMode.off,
        EngineLoopMode.all => ja.LoopMode.all,
        EngineLoopMode.one => ja.LoopMode.one,
      }),
      'setLoopMode',
      command: EngineCommand.setLoopMode,
    );
  }

  @override
  Stream<EngineTransportState> get transportStateStream =>
      _transportController.stream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;
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
  Future<bool> whenApplied() {
    final generation = _generation;
    final ended = _generationEnded.future;
    return Future.any([
      _nativeTail.then((_) => _live(generation) && !_diverged),
      ended.then((_) => false),
    ]);
  }

  @override
  Stream<EngineCommandFailure> get commandFailures =>
      _commandFailuresController.stream;
  @override
  Stream<PlaybackObservation> get observations =>
      _observationsController.stream;

  @override
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _generation++;
    _generationEnded.complete();
    unawaited(_currentIndexSubscription?.cancel());
    for (final sub in _pluginSubscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(_observationsController.close());
    unawaited(_sourceFailuresController.close());
    unawaited(_commandFailuresController.close());
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
    final replacement = _rebuilt(old, old.entry);
    _issued = List<_Source>.from(_issued)..[localIndex] = replacement;

    _structural(PlaybackTransitionCause.qualityRebuild, (generation) async {
      final index = _indexOfSource(_applied, old);
      if (index == null) return;
      if (!await _nativeRemove(generation, index)) return;
      if (!await _nativeInsert(generation, index, _latest(replacement))) {
        return;
      }
      await _nativeSeek(seekTo, _targetOf(_applied[index]), index: index);
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
    final rebuilt = [for (final source in _issued) _rebuilt(source, source.entry)];
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
        await _nativeSeek(seekTo, _targetOf(_applied[index]), index: index);
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
      } catch (thrown) {
        var error = thrown;
        if (error is _NativeStepError) {
          _reportFailure(generation, error, transitionCause);
          error = error.cause ?? 'seek dropped while loading';
        }
        _logError('Native command failed', error);
      }
    }).whenComplete(() {
      if (transitionCause != null && generation == _generation) {
        _transitionDone(transitionCause);
      }
    });
  }

  /// Emits the one typed failure of a generation and marks it diverged; a
  /// later failure, or one of work a newer seed replaced, is only logged.
  void _reportFailure(int generation, _NativeStepError step,
      PlaybackTransitionCause? cause) {
    if (!_live(generation) || _diverged) return;
    _diverged = true;
    _emitFailure(step, cause);
  }

  void _emitFailure(_NativeStepError step, PlaybackTransitionCause? cause,
      {bool diverged = true}) {
    if (_commandFailuresController.isClosed) return;
    final error = step.cause;
    _commandFailuresController.add(EngineCommandFailure(
      runtimeId: runtimeId,
      seedRevision: _seedRevision,
      playlistRevision: _playlistRevision,
      command: step.command,
      reason: step.reason,
      diverged: diverged,
      target: step.target,
      position: step.position,
      cause: cause,
      errorCode: error is ja.PlayerException ? error.code : null,
    ));
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
    if (_diverged) {
      // The plugin's index and end are not proof of anything: not a natural
      // advance, no recovery of a held failure, no end-of-queue check.
      _heldFailure = null;
      _emitObservation(_settled, cause: cause, uncertain: true);
      return;
    }
    final expected = _committedCurrentItemId;
    final nativeIndex = _player.currentIndex;
    final native = _itemIdForIndex(nativeIndex);
    var settledCause = cause;
    // The settle's read of the plugin's index counts as a report. One that
    // belongs to a step with later steps' reports outstanding (or to a lost
    // plugin) is stale: not an advance, not a failure; settle on the
    // expected item, uncertain, and keep waiting.
    final matched = _consumeReport(nativeIndex);
    final stale = nativeIndex != null &&
        ((matched && _reportsPending) || (!matched && _pluginLost));
    if (!stale &&
        native != null &&
        native != expected &&
        !_isExplainedIndex(nativeIndex!, expected)) {
      _reportUnexplainedIndex(nativeIndex);
      _heldFailure = null;
      _emitObservation(_settled, cause: cause, uncertain: true);
      return;
    }
    if (!stale && native != null && native != expected) {
      settledCause = PlaybackTransitionCause.naturalAdvance;
      if (_isOfflineFn() && !_isIndexLocallyPlayable(nativeIndex!)) {
        // Same rule as a direct index event: the core picks the target.
        final unavailable = _applied[nativeIndex].entry;
        _unavailableAdvanceController.add(UnavailableAdvance(
          itemId: unavailable.itemId,
          playPosition: unavailable.playPosition,
        ));
        // The plugin is proven on the unavailable item (nothing committed).
        _resetTrail(nativeIndex);
        // The core is rescuing: nothing trustworthy to attribute yet, and
        // a held failure (the unavailable item's) must not reach a later,
        // unrelated settle.
        _heldFailure = null;
        _emitObservation(_settled, cause: settledCause, uncertain: true);
        return;
      }
      _commitCurrentItem(native, emit: true);
    }
    if (!stale && native != null) _resetTrail(nativeIndex);
    final settledIndex = native != null && !stale
        ? nativeIndex
        : (expected == null ? null : _indexOf(_applied, expected));
    _settled = _identityAt(settledIndex);
    _emitObservation(_settled, cause: settledCause, uncertain: stale);
    _reportHeldFailure();
    if (_player.processingState == ja.ProcessingState.completed) {
      // Still ended once the edit settled: the queue's real end.
      _onPluginState(ja.PlayerState(_player.playing, ja.ProcessingState.completed));
    }
  }

  /// The desired transport is the engine's own (a queued play waits behind
  /// the load, so the plugin reports `playing` late) and changes with the
  /// engine's commands; the processing state is the plugin's. A play the
  /// plugin reverted (audio-session activation failed) clears it.
  void _onPluginState(ja.PlayerState state) {
    _processing = _processingFrom(state.processingState);
    if (_processing == EngineProcessingState.ready) _failedSinceLoad = false;
    if (_processing == EngineProcessingState.completed &&
        (_pendingTransitions > 0 || _diverged)) {
      // A rebuild or refresh removes a source before inserting its
      // replacement: the native playlist can briefly end while the engine
      // edits it. Not the queue's end; rechecked when the edit settles.
      _processing = EngineProcessingState.buffering;
    }
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
    _releaseHeldIfStopped();
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
    _failedSinceLoad = true;
    final uncertain = _pendingTransitions > 0 || _diverged || _reportsPending;
    final failure = EngineSourceFailure(
      playlistRevision: _playlistRevision,
      source: uncertain ? null : _identityAt(error.index ?? _player.currentIndex),
      uncertain: uncertain,
      errorCode: error.code,
      errorMessage: _redacted(error.message),
    );
    _logError('Source failed: ${failure.source} ${error.code}', error);
    // Held until the transition settles (the latest one wins).
    if (uncertain) _heldFailure = error;
    _sourceFailuresController.add(failure);
    _releaseHeldIfStopped();
  }

  /// A failure held for outstanding index reports, once the plugin has
  /// stopped on it, is the settled source's (as at a stale settle): the
  /// report may never come.
  void _releaseHeldIfStopped() {
    if (_heldFailure == null ||
        _pendingTransitions > 0 ||
        _diverged ||
        _player.processingState != ja.ProcessingState.idle) {
      return;
    }
    _reportHeldFailure();
  }

  /// An uncertain failure waiting for its transition to settle.
  ja.PlayerException? _heldFailure;

  /// A source failed since the plugin last became ready: the next seed
  /// resets the plugin first (see [setSeed]).
  bool _failedSinceLoad = false;

  /// A pause failed natively (7P.1 review R2-01): the next seed resets the
  /// plugin, whatever it reports meanwhile.
  bool _pauseFailedSinceSeed = false;

  /// At settle: if the plugin stopped on the failure, it was the settled
  /// current source's (a failure during an insert or rebuild would else be
  /// lost, and playback would sit errored with no fallback or skip). If the
  /// plugin plays on, it was another source's and nothing more is said.
  void _reportHeldFailure() {
    final held = _heldFailure;
    _heldFailure = null;
    if (held == null || _isDisposed || _sourceFailuresController.isClosed) {
      return;
    }
    if (_player.processingState != ja.ProcessingState.idle) return;
    final source = _settled;
    if (source == null) return;
    _sourceFailuresController.add(EngineSourceFailure(
      playlistRevision: _playlistRevision,
      source: source,
      uncertain: false,
      errorCode: held.code,
      errorMessage: _redacted(held.message),
    ));
  }

  void _onDiscontinuity(ja.PositionDiscontinuity discontinuity) {
    if (_isDisposed ||
        _pendingTransitions > 0 ||
        _diverged ||
        discontinuity.reason != ja.PositionDiscontinuityReason.autoAdvance) {
      return; // explicit seeks are stamped by the command that issued them
    }
    final previous = _identityAt(discontinuity.previousEvent.currentIndex);
    final current = _identityAt(discontinuity.event.currentIndex);
    if (current == null) return;
    // While reports are outstanding the indices are not trusted: only a
    // restart of the committed item's own source is certain.
    if (_reportsPending &&
        !(previous?.sourceId == current.sourceId &&
            current.itemId == _committedCurrentItemId)) {
      return;
    }
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
    if (_pendingTransitions > 0 || _diverged || _reportsPending) {
      _emitObservation(_settled, cause: cause, uncertain: true);
      return;
    }
    _settled = _identityAt(index ?? _player.currentIndex);
    _emitObservation(_settled, cause: cause, uncertain: false);
  }

  /// Reports of earlier native steps are still outstanding.
  bool get _reportsPending => _pluginLost || _trail.length > 1;

  /// The last proven entry names the committed item: the plugin is on it.
  bool get _headIsCommitted =>
      !_pluginLost &&
      _trail.isNotEmpty &&
      _committedCurrentItemId != null &&
      _trail.first.itemId == _committedCurrentItemId;

  /// The committed item's identity in the applied mirror.
  EngineSourceIdentity? _committedIdentity() {
    final committed = _committedCurrentItemId;
    return _identityAt(committed == null ? null : _indexOf(_applied, committed));
  }

  /// The plugin is proven on [index]: nothing is outstanding.
  void _resetTrail(int? index) {
    if (index == null) return;
    _trail = [(index: index, itemId: _itemIdForIndex(index))];
    _pluginLost = false;
  }

  /// Consumes a report of [index] in order (smallest matching entry); false
  /// when no recorded step explains it.
  bool _consumeReport(int? index) {
    if (index == null) return false;
    final at = _trail.indexWhere((step) => step.index == index);
    if (at < 0) return false;
    if (at > 0) _trail.removeRange(0, at);
    return true;
  }

  /// Records the plugin's next index and item. A step that keeps the index
  /// replaces the last entry's item: reports carry only the index, so two
  /// entries with one index could never be told apart (review r3).
  void _addStep(int index, int? itemId) {
    final step = (index: index, itemId: itemId);
    if (_trail.isNotEmpty && _trail.last.index == index) {
      _trail[_trail.length - 1] = step;
    } else {
      _trail.add(step);
    }
  }

  /// Records, at issue, where the plugin goes with an insert at [index] (the
  /// mirror is still the playlist before the step).
  void _planInsert(int index) {
    if (_pluginLost || _trail.isEmpty) return;
    final last = _trail.last;
    if (index <= last.index) _addStep(last.index + 1, last.itemId);
  }

  /// As [_planInsert], for a remove. Removing the plugin's own source makes
  /// it play on with the item now at that index, or (it was last) fall back
  /// to the item before it; only a one-source list loses its item.
  void _planRemove(int index) {
    if (_pluginLost || _trail.isEmpty) return;
    final last = _trail.last;
    final at = last.index;
    if (index < at) {
      _addStep(at - 1, last.itemId);
    } else if (index == at) {
      if (at + 1 < _applied.length) {
        _addStep(at, _applied[at + 1].entry.itemId);
      } else if (at > 0) {
        _addStep(at - 1, _applied[at - 1].entry.itemId);
      } else {
        _pluginLost = true;
      }
    }
  }

  /// As [_planInsert], for an indexed seek to [index].
  void _planSeek(int index) {
    if (index < 0 || index >= _applied.length) return;
    _pluginLost = false;
    _addStep(index, _applied[index].entry.itemId);
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

  /// Whether work of [generation] may still touch the plugin: a newer seed
  /// (or dispose) makes it stale, also between the steps of one action.
  bool _live(int generation) => generation == _generation && !_isDisposed;

  /// Inserts natively and mirrors it, unless the work went stale meanwhile.
  /// (Each action starts live: the queue checks its generation first.)
  Future<bool> _nativeInsert(int generation, int index, _Source source) async {
    if (_live(generation)) _planInsert(index);
    try {
      await _player.insertAudioSource(index, source.audio);
    } catch (error) {
      throw _NativeStepError(EngineCommand.insert, _targetOf(source), error);
    }
    if (!_live(generation)) return false;
    // Mirror the metadata current now, not as of the call.
    _applied = List<_Source>.from(_applied)..insert(index, _latest(source));
    return true;
  }

  EngineCommandTarget _targetOf(_Source source) => EngineCommandTarget(
        itemId: source.identity.itemId,
        trackUuid: source.identity.trackUuid,
        sourceKind: source.identity.sourceKind,
      );

  /// just_audio drops a seek made while the plugin is loading, silently.
  Future<void> _nativeSeek(Duration position,
      EngineCommandTarget? target, {int? index}) async {
    if (_player.processingState == ja.ProcessingState.loading) {
      throw _NativeStepError(EngineCommand.seek, target, null,
          reason: EngineCommandFailureReason.dropped, position: position);
    }
    final generation = _generation;
    // An indexed seek moves the plugin to another item (same rule as an edit).
    if (index != null && _live(generation)) _planSeek(index);
    try {
      await _player.seek(position, index: index);
    } catch (error) {
      throw _NativeStepError(EngineCommand.seek, target, error,
          position: position);
    }
  }

  /// Removes natively and mirrors it, unless the work went stale.
  Future<bool> _nativeRemove(int generation, int index) async {
    if (_live(generation)) _planRemove(index);
    try {
      await _player.removeAudioSourceAt(index);
    } catch (error) {
      throw _NativeStepError(EngineCommand.remove,
          index < _applied.length ? _targetOf(_applied[index]) : null, error);
    }
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

  /// A direct command is not queued. With a [command], its failure is
  /// reported; only a failed pause (output may still be audible) diverges.
  void _direct(Future<void> action, String name, {EngineCommand? command}) {
    final generation = _generation;
    unawaited(action.catchError((Object error) {
      _logError('Failed to $name', error);
      if (command == null || _isDisposed) return;
      final step = _NativeStepError(
          command,
          command == EngineCommand.pause || command == EngineCommand.stop
              ? _currentTarget()
              : null,
          error);
      if (command == EngineCommand.pause) {
        // The native output may still play: the next seed resets the plugin
        // (a later ready report does not clear this, unlike a load error).
        _pauseFailedSinceSeed = true;
        _reportFailure(generation, step, null);
      } else {
        _emitFailure(step, null, diverged: false);
      }
    }));
  }

  EngineCommandTarget? _currentTarget() {
    final current = _committedCurrentItemId;
    final at = current == null ? null : _indexOf(_issued, current);
    return at == null ? null : _targetOf(_issued[at]);
  }

  String? _redacted(String? message) =>
      message == null ? null : _scrub(message);

  void _emitLoad(int revision, EngineLoadOutcome outcome,
      {Duration? duration,
      int? errorCode,
      String? errorMessage,
      EngineSourceIdentity? source}) {
    if (_loadEventsController.isClosed) return;
    _loadEventsController.add(EngineLoadEvent(
      playlistRevision: revision,
      outcome: outcome,
      duration: duration,
      errorCode: errorCode,
      errorMessage: errorMessage,
      source: source,
    ));
  }

  /// Builds the audio source and its identity from one decision. A given
  /// [kind] (the resolver's choice) is applied: only `remote` overrides the
  /// rule. `local` plays the rule's path, so a suspected, undecodable or
  /// missing download streams (the rule's own verdict, not a fallback). A null
  /// kind keeps the rule's plan.
  _Source _newSource(QueuePlaybackEntry entry, {PlaybackSourceKind? kind}) {
    final String? localPath;
    switch (kind) {
      case PlaybackSourceKind.remote:
        localPath = null;
      case PlaybackSourceKind.local:
      case null:
        localPath = _localSources.localPathFor(entry);
    }
    final built = _audioSourceFor(entry, localPath);
    return _Source(
      entry,
      built.audio,
      EngineSourceIdentity(
        sourceId: ++_nextSourceId,
        sessionId: _sessionId,
        itemId: entry.itemId,
        trackUuid: entry.uuidId,
        localPath: localPath,
      ),
      _localSources.localPathFor(entry),
      tokenWithheld: built.withheld,
    );
  }

  /// Rebuilds each withheld source of [sources] whose token is now permitted
  /// and records the replacement in the issued model (same identity).
  List<_Source> _withPermittedTokens(List<_Source> sources) {
    final out = <_Source>[];
    for (final source in sources) {
      if (!source.tokenWithheld) {
        out.add(source);
        continue;
      }
      // The latest issued version by identity: a refresh may have replaced
      // this plugin source already (the same verdict woke both).
      final latest = _issued
              .where((s) => s.identity.sourceId == source.identity.sourceId)
              .firstOrNull;
      if (latest == null) {
        // Replaced meanwhile (a quality rebuild, an availability refresh):
        // hand the original; the queued work behind the seed replaces it.
        out.add(source);
        continue;
      }
      if (!latest.tokenWithheld) {
        out.add(latest);
        continue;
      }
      final built = _streamAudio(latest.entry);
      if (built.withheld) {
        out.add(latest);
        continue;
      }
      final replacement = latest.withAudio(built.audio, tokenWithheld: false);
      _issued = [
        for (final s in _issued)
          s.identity.sourceId == source.identity.sourceId ? replacement : s,
      ];
      out.add(replacement);
    }
    return out;
  }

  /// Rebuilds [old] for [entry] without re-deciding its kind: the applied
  /// kind is kept unless the rule's own verdict for the entry changed since
  /// the source was built (then the rule's new plan applies).
  _Source _rebuilt(_Source old, QueuePlaybackEntry entry) =>
      _localSources.localPathFor(entry) == old.plannedPath
          ? _newSource(entry, kind: old.identity.sourceKind)
          : _newSource(entry);

  /// The media token for [streamUriWithoutToken], or null: no token, no
  /// permit, the permit says no, or it throws (sign-off OPEN-M-11 step D).
  String? _permittedMediaToken(Uri streamUriWithoutToken) {
    final token = _streamMediaToken;
    final permit = _mediaTokenPermit;
    if (token == null || token.isEmpty || permit == null) return null;
    try {
      return permit.allowsTokenTo(streamUriWithoutToken) ? token : null;
    } catch (_) {
      return null;
    }
  }

  /// Local files are served verbatim (never ask, never withheld). A stream
  /// is built without the token first; the token is added only if
  /// [_permittedMediaToken] allows it and [allowToken] is true.
  /// `withheld` is true when a token exists but did not go in.
  ({ja.AudioSource audio, bool withheld}) _audioSourceFor(
      QueuePlaybackEntry entry, String? localPath) {
    if (localPath != null) {
      // Local file is always served verbatim — quality preset doesn't apply.
      return (
        audio: ja.AudioSource.uri(Uri.file(localPath), tag: entry.itemId),
        withheld: false,
      );
    }
    return _streamAudio(entry);
  }

  ({ja.AudioSource audio, bool withheld}) _streamAudio(
      QueuePlaybackEntry entry, {bool allowToken = true}) {
    // A codec this device can't decode streams transcoded (major 1).
    final quality = _localSources.streamQualityFor(entry, _streamQuality);
    final bare = buildTrackStreamUri(_streamBaseUrl, entry.uuidId,
        quality: quality);
    final token = allowToken ? _permittedMediaToken(bare) : null;
    final uri = token == null
        ? bare
        : buildTrackStreamUri(_streamBaseUrl, entry.uuidId,
            quality: quality, mediaToken: token);
    final configured = _streamMediaToken != null && _streamMediaToken.isNotEmpty;
    return (
      audio: ja.AudioSource.uri(uri, tag: entry.itemId),
      withheld: configured && token == null,
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
    if (_diverged) {
      _observe(index: index);
      return;
    }
    final matched = _consumeReport(index);
    if (_pendingTransitions > 0) {
      _observe(index: index);
      return;
    }
    if (index != null &&
        ((matched && _reportsPending) || (!matched && _pluginLost))) {
      // A report of an earlier step (see [_trail]): neither an advance nor
      // a failure. Certain while the plugin is proven on the committed item.
      if (_headIsCommitted) _settled = _committedIdentity();
      _emitObservation(_settled, cause: null, uncertain: !_headIsCommitted);
      return;
    }
    if (index != null && !_isExplainedIndex(index, _committedCurrentItemId)) {
      _reportUnexplainedIndex(index);
      _emitObservation(_settled, cause: null, uncertain: true);
      return;
    }
    // Offline: don't commit an index whose source has no verified local file.
    // Report it upward so the queue player can search the full queue (not just
    // what we currently have loaded) for the next locally playable entry.
    if (index != null && _isOfflineFn() && !_isIndexLocallyPlayable(index)) {
      if (index >= 0 && index < _applied.length) {
        final unavailable = _applied[index].entry;
        _unavailableAdvanceController.add(UnavailableAdvance(
          itemId: unavailable.itemId,
          playPosition: unavailable.playPosition,
        ));
        // The plugin is proven on the unavailable item (nothing committed).
        _resetTrail(index);
      }
      return;
    }
    _commitCurrentItem(_itemIdForIndex(index), emit: true);
    if (_itemIdForIndex(index) != null) _resetTrail(index);
    _observe(index: index);
    // The plugin is proven again: a failure held while its reports were
    // outstanding is the settled source's if the plugin stopped on it.
    if (!_reportsPending) _reportHeldFailure();
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

  /// Whether the plugin's [index] follows from the [from] item: the same
  /// item, the one after it, or the wrap to the first under loop-all.
  bool _isExplainedIndex(int index, int? from) {
    if (from == null) return true;
    final at = _indexOf(_applied, from);
    if (at == null || index < 0 || index >= _applied.length) return false;
    return index == at ||
        index == at + 1 ||
        (index == 0 &&
            at == _applied.length - 1 &&
            _requestedLoopMode == EngineLoopMode.all);
  }

  /// An index nothing explains: the plugin's playlist is not proven to
  /// match the mirror, so the generation is diverged.
  void _reportUnexplainedIndex(int? index) {
    _reportFailure(
        _generation,
        _NativeStepError(
            null,
            index != null && index >= 0 && index < _applied.length
                ? _targetOf(_applied[index])
                : null,
            null,
            reason: EngineCommandFailureReason.unexplainedIndex),
        null);
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
  const _Source(this.entry, this.audio, this.identity, this.plannedPath,
      {this.tokenWithheld = false});
  final QueuePlaybackEntry entry;
  final ja.AudioSource audio;
  final EngineSourceIdentity identity;

  /// The rule's verdict for [entry] when this source was built, whatever kind
  /// was applied. A rebuild keeps the applied kind unless the verdict changed.
  final String? plannedPath;

  /// A stream source built while a media token exists but without it
  /// (sign-off OPEN-M-11 step D).
  final bool tokenWithheld;

  /// Metadata changes keep the created source and its identity.
  _Source withEntry(QueuePlaybackEntry entry) =>
      _Source(entry, audio, identity, plannedPath, tokenWithheld: tokenWithheld);

  /// The same source with the rule's newer verdict recorded.
  _Source withPlanned(String? plannedPath) =>
      _Source(entry, audio, identity, plannedPath, tokenWithheld: tokenWithheld);

  /// The same entry and identity over a replacement plugin source.
  _Source withAudio(ja.AudioSource audio, {required bool tokenWithheld}) =>
      _Source(entry, audio, identity, plannedPath, tokenWithheld: tokenWithheld);
}

/// A failed native insert or remove, carried to [_enqueue].
class _NativeStepError {
  const _NativeStepError(this.command, this.target, this.cause,
      {this.reason = EngineCommandFailureReason.failed, this.position});
  final EngineCommand? command;
  final EngineCommandTarget? target;
  final Object? cause;
  final EngineCommandFailureReason reason;
  final Duration? position;
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

EngineProcessingState _processingFrom(ja.ProcessingState state) =>
    switch (state) {
      ja.ProcessingState.idle => EngineProcessingState.idle,
      ja.ProcessingState.loading => EngineProcessingState.loading,
      ja.ProcessingState.buffering => EngineProcessingState.buffering,
      ja.ProcessingState.ready => EngineProcessingState.ready,
      ja.ProcessingState.completed => EngineProcessingState.completed,
    };

/// The [PreviewEngine] adapter: its own just_audio instance (7B.2a).
class JustAudioPreviewEngine implements PreviewEngine {
  JustAudioPreviewEngine(this._player, {void Function(String message)? log})
      : _log = log ??
            ((message) =>
                developer.log(message, name: 'JustAudioPreviewEngine'));

  factory JustAudioPreviewEngine.create({
    ja.AudioPlayer Function({required bool handleInterruptions})? newPlayer,
    void Function(String message)? log,
  }) {
    final build = newPlayer ??
        ({required bool handleInterruptions}) =>
            ja.AudioPlayer(handleInterruptions: handleInterruptions);
    return JustAudioPreviewEngine(build(handleInterruptions: false), log: log);
  }

  final ja.AudioPlayer _player;
  final void Function(String message) _log;
  String? _token;

  /// Player errors can quote the URL and its token: never logged raw.
  void _logError(String what, Object error) {
    var text = redactAccessToken('$what: $error');
    final token = _token;
    if (token != null && token.isNotEmpty) {
      text = text.replaceAll(token, '<redacted>');
    }
    _log(text);
  }

  @override
  Future<Duration?> load(Uri uri) async {
    _token = uri.queryParameters['access_token'];
    try {
      return await _player.setUrl(uri.toString());
    } catch (error) {
      _logError('preview load failed', error);
      throw const PreviewLoadFailed();
    }
  }

  @override
  Future<void> play() async {
    unawaited(_player
        .play()
        .catchError((Object error) => _logError('preview play failed', error)));
  }

  @override
  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (error) {
      _logError('preview pause failed', error);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (error) {
      _logError('preview stop failed', error);
    }
  }

  @override
  Stream<EngineTransportState> get transportStates =>
      _player.playerStateStream.map((state) => EngineTransportState(
          state.playing, _processingFrom(state.processingState)));

  @override
  void dispose() {
    unawaited(_player.dispose());
  }
}
