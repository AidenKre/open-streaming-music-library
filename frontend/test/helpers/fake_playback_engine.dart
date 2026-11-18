import 'dart:async';

import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/repositories/queue_repository.dart';

// The fake playback engine the queue-player tests drive (moved out of
// queue_player_test.dart, APP-TEST stage 1).

class FakePlaybackEngine
    implements PlaybackEngine {
  final _playerStateController = StreamController<EngineTransportState>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _currentItemIdController = StreamController<int?>.broadcast();
  final _unavailableAdvanceController =
      StreamController<UnavailableAdvance>.broadcast();

  List<QueuePlaybackEntry> _loadedEntries = const [];
  int? _currentLocalIndex;
  int? _committedCurrentItemId;
  Duration _position = Duration.zero;
  bool _disposed = false;
  bool get isDisposed => _disposed;
  Completer<void>? addEntriesEntered;
  Completer<void>? addEntriesRelease;

  final List<SeedCall> seedCalls = [];

  /// Runs at the start of every seed, before the fake commits or plays.
  Future<void> Function(int? sessionId)? beforeSeed;
  final List<List<QueuePlaybackEntry>> addedBatches = [];
  final List<List<QueuePlaybackEntry>> replacedFutureBatches = [];
  final List<List<QueuePlaybackEntry>> rebuildCalls = [];
  final List<int> removedItems = [];
  final List<int> seekedItems = [];
  final List<PlaybackTransitionCause> seekCauses = [];
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;

  /// The desired transport as `JustAudioEngine` keeps it: a play stays
  /// issued across a seed without autoplay (just_audio keeps `playing`
  /// across a playlist replacement); only a pause or a stop clears it.
  bool wantsPlaying = false;

  /// What the adapter reports once a seeded load settles.
  void emitSettledTransport() => emitPlayerState(
      EngineTransportState(wantsPlaying, EngineProcessingState.ready));
  EngineLoopMode? lastLoopMode;
  double? lastVolume;
  String? lastStreamQuality;

  @override
  void setStreamQuality(String quality) {
    lastStreamQuality = quality;
  }

  @override
  Future<void> rebuildCurrentSource(String quality, Duration seekTo) async =>
      rebuilds.add(('current', quality, seekTo, _committedCurrentItemId));

  @override
  Future<void> rebuildAllSources(String quality, Duration seekTo) async =>
      rebuilds.add(('all', quality, seekTo, _committedCurrentItemId));

  final rebuilds = <(String, String, Duration, int?)>[];

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
    if (!entries.any((entry) => entry.itemId == currentItemId)) {
      // Like `JustAudioEngine.setSeed`: rejected before anything changes.
      throw StateError('Current item is missing from the seeded player queue');
    }
    await beforeSeed?.call(sessionId);
    playlistRevision++; // like the engine: every seed is a new revision
    seedRevision = playlistRevision;
    _loadedEntries = _sorted(entries);
    _currentLocalIndex = _loadedEntries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    _committedCurrentItemId = currentItemId;
    _position = initialPosition;
    _processing = EngineProcessingState.ready;
    seedCalls.add(
      SeedCall(
        entries: List<QueuePlaybackEntry>.from(_loadedEntries),
        currentItemId: currentItemId,
        sessionId: sessionId,
        cause: cause,
        initialPosition: initialPosition,
        autoPlay: autoPlay,
        shuffleEnabled: shuffleEnabled,
        currentSourceKind: currentSourceKind,
      ),
    );
    _appliedKinds
      ..clear()
      ..addAll({if (currentSourceKind != null) currentItemId: currentSourceKind});
    // Like production's structural mutation: commit identity silently.
    if (autoPlay) {
      playCalls++;
      wantsPlaying = true;
    }
    if (seedFailuresAfterReplacing > 0) {
      seedFailuresAfterReplacing--;
      throw StateError('the seed replaced the playlist, then failed');
    }
  }

  /// The next seeds that fail after they replaced the playlist (its
  /// revision already moved on). The `PlaybackEngine` interface lets
  /// `setSeed` throw; `JustAudioEngine` throws only before it changes
  /// anything (a current item missing from the entries), so this stands for
  /// a failure today's engine does not produce. It is what reaches the
  /// queue player's restore of the previous queue after a failed start.
  int seedFailuresAfterReplacing = 0;

  @override
  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    final release = addEntriesRelease;
    if (release != null) {
      final entered = addEntriesEntered;
      addEntriesEntered = null;
      if (entered != null && !entered.isCompleted) entered.complete();
      await release.future;
      addEntriesRelease = null;
    }
    final additions = entries
        .where((entry) => !hasItem(entry.itemId))
        .toList(growable: false);
    if (additions.isEmpty) return;

    playlistRevision++;
    addedBatches.add(additions);
    _beginHeldEdit();
    for (final entry in _sorted(additions)) {
      final insertionIndex = _insertionIndexFor(entry.playPosition);
      if (_currentLocalIndex != null && insertionIndex <= _currentLocalIndex!) {
        _currentLocalIndex = _currentLocalIndex! + 1;
      }
      _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
        ..insert(insertionIndex, entry);
    }
  }

  @override
  void replaceLoadedEntriesMetadata(List<QueuePlaybackEntry> updatedEntries) {
    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    _loadedEntries = _loadedEntries
        .map((entry) => byItemId[entry.itemId] ?? entry)
        .toList(growable: false);
  }

  /// Set by the test harness so the fake can decide, on a per-itemId basis,
  /// whether the simulated local file is currently considered present. The
  /// production controller goes through dart:io File.existsSync() — in tests
  /// we steer it through the same external set the QueueRepository fixture
  /// uses to decide playability.
  bool Function(QueuePlaybackEntry entry) sourceAvailability = (entry) =>
      entry.filePath != null && entry.filePath!.isNotEmpty;

  bool offlineForRefresh = false;

  final List<RefreshedSource> refreshedSources = [];
  final List<int> rescuedItemIds = [];

  @override
  Future<void> refreshLoadedSourcesForAvailabilityChanges(
    List<QueuePlaybackEntry> updatedEntries,
  ) async {
    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    final nextEntries = <QueuePlaybackEntry>[];
    int? rescueItemId;
    int? rescuePlayPosition;
    for (final oldEntry in _loadedEntries) {
      final newEntry = byItemId[oldEntry.itemId] ?? oldEntry;
      nextEntries.add(newEntry);
      final oldHadFile = sourceAvailability(oldEntry);
      final newHasFile = sourceAvailability(newEntry);
      if (oldHadFile == newHasFile && oldEntry.filePath == newEntry.filePath) {
        continue;
      }
      refreshedSources.add(
        RefreshedSource(
          itemId: newEntry.itemId,
          oldHadFile: oldHadFile,
          newHasFile: newHasFile,
          entry: newEntry,
        ),
      );
      if (newEntry.itemId == _committedCurrentItemId &&
          oldHadFile &&
          !newHasFile &&
          offlineForRefresh) {
        rescueItemId = newEntry.itemId;
        rescuePlayPosition = newEntry.playPosition;
      }
    }
    _loadedEntries = nextEntries;
    if (rescueItemId != null && rescuePlayPosition != null) {
      rescuedItemIds.add(rescueItemId);
      _unavailableAdvanceController.add(
        UnavailableAdvance(
          itemId: rescueItemId,
          playPosition: rescuePlayPosition,
        ),
      );
    }
  }

  @override
  Future<void> replaceFutureEntries({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    final error = replaceFutureEntriesError;
    if (error != null) {
      replaceFutureEntriesError = null;
      throw error;
    }
    final currentIndex = _loadedEntries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (currentIndex < 0) {
      throw StateError('Current item $currentItemId is not loaded');
    }

    playlistRevision++;
    replacedFutureBatches.add(List<QueuePlaybackEntry>.from(entries));
    _beginHeldEdit();
    _loadedEntries = List<QueuePlaybackEntry>.from(
      _loadedEntries.take(currentIndex + 1),
    );
    for (final entry in _sorted(entries)) {
      final insertionIndex = _insertionIndexFor(entry.playPosition);
      _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
        ..insert(insertionIndex, entry);
    }
  }

  @override
  Future<void> rebuildAroundCurrent({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    final sorted = _sorted(entries);
    final nextIndex = sorted.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (nextIndex < 0) {
      throw StateError('Current item $currentItemId is not in rebuilt queue');
    }

    playlistRevision++;
    rebuildCalls.add(List<QueuePlaybackEntry>.from(sorted));
    _loadedEntries = sorted;
    _currentLocalIndex = nextIndex;
    _committedCurrentItemId = currentItemId;
    duringRebuild?.call();
  }

  /// Runs inside every rebuild (a plugin reporting states while its native
  /// playlist is edited, e.g. completed → buffering → completed again).
  void Function()? duringRebuild;

  /// Review 6-R3-01, like the real engine: an insert (`addEntries`,
  /// `replaceFutureEntries`) updates the issued playlist ([loadedItemIds])
  /// at once but applies natively later. With [holdNextEdit] set, the next
  /// such insert stays pending until [settleEdit]. A completion reported
  /// through [completeNatively] while it is pending is masked as buffering;
  /// at the settle the engine re-reports completed with the ended item still
  /// current (darwin stays completed after an insert).
  bool holdNextEdit = false;
  bool _editPending = false;
  bool _completedWhilePending = false;
  bool get editPending => _editPending;

  void _beginHeldEdit() {
    if (!holdNextEdit) return;
    holdNextEdit = false;
    _editPending = true;
  }

  /// The plugin reaches the end of its native playlist.
  void completeNatively() {
    if (_editPending) {
      _completedWhilePending = true;
      emitPlayerState(
          EngineTransportState(true, EngineProcessingState.buffering));
    } else {
      emitPlayerState(
          EngineTransportState(false, EngineProcessingState.completed));
    }
  }

  /// The pending insert has applied natively.
  void settleEdit() {
    _editPending = false;
    if (!_completedWhilePending) return;
    _completedWhilePending = false;
    emitPlayerState(
        EngineTransportState(false, EngineProcessingState.completed));
  }

  @override
  Future<void> removeItem(int itemId) async {
    final index = _loadedEntries.indexWhere((entry) => entry.itemId == itemId);
    if (index < 0) return;
    playlistRevision++;
    removedItems.add(itemId);
    _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
      ..removeAt(index);
    if (_currentLocalIndex != null && index < _currentLocalIndex!) {
      _currentLocalIndex = _currentLocalIndex! - 1;
    }
  }

  @override
  Future<void> seekToItem(
    int itemId, {
    Duration position = Duration.zero,
    PlaybackTransitionCause cause = PlaybackTransitionCause.userSkip,
  }) async {
    final index = _loadedEntries.indexWhere((entry) => entry.itemId == itemId);
    if (index < 0) {
      throw StateError('Item $itemId is not loaded');
    }
    seekedItems.add(itemId);
    seekCauses.add(cause);
    _currentLocalIndex = index;
    // Like the engine: an item change is emitted only when it changes.
    final changed = _committedCurrentItemId != itemId;
    _committedCurrentItemId = itemId;
    _position = position;
    if (changed) _currentItemIdController.add(itemId);
  }

  int? get currentIndex => _currentLocalIndex;

  @override
  int? get currentItemId => _committedCurrentItemId;

  String? get currentUuid {
    if (_currentLocalIndex == null ||
        _currentLocalIndex! < 0 ||
        _currentLocalIndex! >= _loadedEntries.length) {
      return null;
    }
    return _loadedEntries[_currentLocalIndex!].uuidId;
  }

  @override
  Duration get position => _position;

  @override
  int playlistRevision = 0;

  /// 7P.1: the playlist revision of the latest seed (what a typed command
  /// failure of the current playlist carries).
  int seedRevision = 0;

  final _loadEventsController = StreamController<EngineLoadEvent>.broadcast();

  @override
  Stream<EngineLoadEvent> get loadEvents => _loadEventsController.stream;

  void emitLoadEvent(EngineLoadEvent event) => _loadEventsController.add(event);

  final _sourceFailuresController =
      StreamController<EngineSourceFailure>.broadcast();

  @override
  Stream<EngineSourceFailure> get sourceFailures =>
      _sourceFailuresController.stream;

  /// A raw failure of [itemId] (default: the current item) as the real
  /// engine reports it.
  void emitSourceFailure(
      {int? itemId, int? sourceId, bool uncertain = false, int code = 0}) {
    final item = itemId ?? _committedCurrentItemId;
    final entry = _loadedEntries.where((e) => e.itemId == item).firstOrNull;
    _sourceFailuresController.add(EngineSourceFailure(
      playlistRevision: playlistRevision,
      source: uncertain || entry == null
          ? null
          : EngineSourceIdentity(
              // Like the engine: a source keeps its id across reports.
              sourceId: sourceId ?? entry.itemId + _failureSourceIds,
              sessionId: null,
              itemId: entry.itemId,
              trackUuid: entry.uuidId,
              // Like the engine: what the loaded source plays (7P.2: the
              // kind the core applied wins over the recorded download).
              localPath: (entry.filePath?.isEmpty ?? true) ||
                      _appliedKinds[entry.itemId] == PlaybackSourceKind.remote
                  ? null
                  : entry.filePath),
      uncertain: uncertain,
      errorCode: code,
    ));
  }

  static const _failureSourceIds = 1000;

  final _commandFailuresController =
      StreamController<EngineCommandFailure>.broadcast();

  @override
  Stream<EngineCommandFailure> get commandFailures =>
      _commandFailuresController.stream;

  /// 7P.1 (m5): native application of issued work; a test holds or fails
  /// it with [appliedGate].
  Completer<bool>? appliedGate;

  @override
  Future<bool> whenApplied() => appliedGate?.future ?? Future.value(true);

  /// 7P.1: a typed native command failure as the real engine reports it.
  void emitCommandFailure(EngineCommandFailure failure) =>
      _commandFailuresController.add(failure);

  @override
  final int runtimeId = 1;

  @override
  Stream<PlaybackObservation> get observations =>
      _observationsController.stream;

  @override
  int get queueLength => _loadedEntries.length;

  @override
  List<int> get loadedItemIds =>
      _loadedEntries.map((entry) => entry.itemId).toList(growable: false);

  @override
  bool hasItem(int itemId) =>
      _loadedEntries.any((entry) => entry.itemId == itemId);

  /// 7P.2: kinds a seed applied over the recorded download (by item).
  final Map<int, PlaybackSourceKind> _appliedKinds = {};

  @override
  PlaybackSourceKind? sourceKindOf(int itemId) {
    final entry =
        _loadedEntries.where((e) => e.itemId == itemId).firstOrNull;
    if (entry == null) return null;
    return _appliedKinds[itemId] ??
        (sourceAvailability(entry)
            ? PlaybackSourceKind.local
            : PlaybackSourceKind.remote);
  }

  /// The play itself is not reported (tests emit `playing` by hand), but it
  /// is a change: the next pause or stop reports again, as after the real
  /// engine's own play report.
  @override
  Future<void> play() async {
    playCalls++;
    wantsPlaying = true;
    _lastTransport = EngineTransportState(true, _processing);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    wantsPlaying = false;
    _reportNotPlaying();
  }

  /// The processing state a pause or stop is reported with: the last one
  /// the test reported through [emitPlayerState]; `ready` after a seed (a
  /// seeded load that settled); `idle` before any seed and after a stop.
  EngineProcessingState _processing = EngineProcessingState.idle;
  EngineTransportState? _lastTransport;

  /// Like `JustAudioEngine.pause` and `stop`, which report the cleared
  /// desired transport inside the call (`_emitTransport`): once per change,
  /// and never after dispose.
  void _reportNotPlaying() {
    final next = EngineTransportState(false, _processing);
    if (next == _lastTransport || _disposed) return;
    emitPlayerState(next);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
    _positionController.add(position);
  }

  /// When set, the next setVolume waits on it (a slow platform call).
  Completer<void>? setVolumeGate;

  @override
  Future<void> setVolume(double volume) async {
    final gate = setVolumeGate;
    if (gate != null) {
      setVolumeGate = null;
      await gate.future;
    }
    lastVolume = volume;
  }

  /// Reports like the engine's stop: not playing at once, then the plugin's
  /// own `idle` (just_audio is idle after a stop).
  @override
  Future<void> stop() async {
    stopCalls++;
    wantsPlaying = false;
    _reportNotPlaying();
    _processing = EngineProcessingState.idle;
    _reportNotPlaying();
  }

  /// Never throws, like `JustAudioEngine.setLoopMode` (a native failure is
  /// reported on [commandFailures], not thrown).
  @override
  Future<void> setLoopMode(EngineLoopMode mode) async {
    lastLoopMode = mode;
  }

  @override
  Stream<EngineTransportState> get transportStateStream =>
      _playerStateController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;


  @override
  Stream<int?> get currentItemIdStream => _currentItemIdController.stream;

  @override
  Stream<UnavailableAdvance> get unavailableAdvanceStream =>
      _unavailableAdvanceController.stream;

  void emitPlayerState(EngineTransportState state) {
    _processing = state.processingState;
    _lastTransport = state;
    _playerStateController.add(state);
  }

  List<int> get loadedPlayPositions =>
      _loadedEntries.map((entry) => entry.playPosition).toList();

  Object? replaceFutureEntriesError;

  /// The engine moved to [itemId] but its item-change event has not been
  /// processed yet (it is still in flight).
  void commitSilently(int itemId) {
    _committedCurrentItemId = itemId;
    _currentLocalIndex = _loadedEntries.indexWhere((e) => e.itemId == itemId);
  }

  void emitPosition(Duration position) {
    _position = position;
    _positionController.add(position);
  }

  void emitDuration(Duration? duration) {
    emitObservation(duration: duration);
  }

  final _observationsController =
      StreamController<PlaybackObservation>.broadcast();
  int _observationSequence = 0;

  /// A settled playing+ready observation of the current item.
  void emitPlayingObservation() => emitObservation(playing: true);

  /// A settled observation of [itemId] (default: the committed current item).
  void emitObservation(
      {int? itemId, Duration? duration, bool uncertain = false, bool playing = false}) {
    final item = itemId ?? _committedCurrentItemId;
    final entry = _loadedEntries.where((e) => e.itemId == item).firstOrNull;
    _observationsController.add(PlaybackObservation(
      runtimeId: runtimeId,
      sequence: ++_observationSequence,
      playlistRevision: playlistRevision,
      source: entry == null
          ? null
          : EngineSourceIdentity(
              sourceId: entry.itemId,
              sessionId: null,
              itemId: entry.itemId,
              trackUuid: entry.uuidId),
      position: _position,
      duration: duration,
      playing: playing,
      processingState: EngineProcessingState.ready,
      transitionCause: null,
      rate: 1.0,
      uncertain: uncertain,
    ));
  }

  void emitUnavailableAdvance(UnavailableAdvance event) {
    _unavailableAdvanceController.add(event);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playerStateController.close();
    _positionController.close();
    _observationsController.close();
    _sourceFailuresController.close();
    _commandFailuresController.close();
    _loadEventsController.close();
    _currentItemIdController.close();
    _unavailableAdvanceController.close();
  }

  static List<QueuePlaybackEntry> _sorted(List<QueuePlaybackEntry> entries) {
    final sorted = List<QueuePlaybackEntry>.from(entries);
    sorted.sort((a, b) => a.playPosition.compareTo(b.playPosition));
    return sorted;
  }

  int _insertionIndexFor(int playPosition) {
    for (var i = 0; i < _loadedEntries.length; i++) {
      if (_loadedEntries[i].playPosition > playPosition) {
        return i;
      }
    }
    return _loadedEntries.length;
  }
}

class RefreshedSource {
  final int itemId;
  final bool oldHadFile;
  final bool newHasFile;
  final QueuePlaybackEntry? entry;

  const RefreshedSource({
    required this.itemId,
    required this.oldHadFile,
    required this.newHasFile,
    this.entry,
  });
}

class SeedCall {
  final List<QueuePlaybackEntry> entries;
  final int currentItemId;
  final int? sessionId;
  final PlaybackTransitionCause cause;
  final Duration initialPosition;
  final bool autoPlay;
  final bool shuffleEnabled;

  /// 7P.2: the kind the core asked the engine to apply to the current item.
  final PlaybackSourceKind? currentSourceKind;

  const SeedCall({
    required this.entries,
    required this.currentItemId,
    required this.sessionId,
    required this.cause,
    required this.initialPosition,
    required this.autoPlay,
    required this.shuffleEnabled,
    this.currentSourceKind,
  });
}

/// A fake engine that also takes the gate's media-token work (OPEN-M-11
/// step D).
class TokenAwareFakeEngine extends FakePlaybackEngine implements MediaTokenSources {
  final tokenCalls = <String>[];
  @override
  Future<void> refreshWithheldMediaTokens() async => tokenCalls.add('refresh');
  @override
  Future<void> releaseRemoteSources({required bool includeCurrent}) async =>
      tokenCalls.add(includeCurrent ? 'release everything' : 'release ahead');
}
