import 'dart:async';
import 'dart:developer' as developer;

import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/quality_presets.dart';

class UnavailableAdvance {
  final int itemId;
  final int playPosition;

  const UnavailableAdvance({required this.itemId, required this.playPosition});
}

class ConcatenatingPlayerController {
  final ja.AudioPlayer _player;
  final StreamController<int?> _currentItemIdController =
      StreamController<int?>.broadcast();
  final StreamController<UnavailableAdvance> _unavailableAdvanceController =
      StreamController<UnavailableAdvance>.broadcast();
  List<QueuePlaybackEntry> _loadedEntries = const [];
  StreamSubscription<int?>? _currentIndexSubscription;
  int? _committedCurrentItemId;
  int _structuralMutationDepth = 0;
  bool _isDisposed = false;
  /// Resolves the global offline-mode flag. When `true`, advances onto an
  /// entry without a verified local file are reported via
  /// [unavailableAdvanceStream] instead of being committed as the current
  /// item; the coordinator decides what to do next.
  final bool Function() _isOfflineFn;

  /// Quality preset applied to NEW source URIs. Existing in-flight sources
  /// keep whatever quality they were created with — quality switches take
  /// effect at the next track boundary.
  String _streamQuality = originalQuality;

  ConcatenatingPlayerController(this._player, {bool Function()? isOfflineFn})
      : _isOfflineFn = isOfflineFn ?? (() => false) {
    _currentIndexSubscription = _player.currentIndexStream.listen(
      _onCurrentIndexChanged,
    );
  }

  factory ConcatenatingPlayerController.create({
    bool Function()? isOfflineFn,
  }) {
    return ConcatenatingPlayerController(
      ja.AudioPlayer(),
      isOfflineFn: isOfflineFn,
    );
  }

  Future<void> setSeed(
    List<QueuePlaybackEntry> entries, {
    required int currentItemId,
    Duration initialPosition = Duration.zero,
    bool autoPlay = false,
    bool shuffleEnabled = false,
  }) async {
    if (_isDisposed) return;

    final sortedEntries = _sortedEntries(entries);
    final localIndex = sortedEntries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (localIndex < 0) {
      throw StateError('Current item is missing from the seeded player queue');
    }

    await _runStructuralMutation(() async {
      _loadedEntries = sortedEntries;
      await _player.setAudioSources(
        _loadedEntries.map(_sourceForEntry).toList(growable: false),
        initialIndex: localIndex,
        initialPosition: initialPosition,
      );
    }, preservedCurrentItemId: currentItemId);

    if (autoPlay) {
      await play();
    }
  }

  Future<void> addEntries(List<QueuePlaybackEntry> entries) async {
    if (_isDisposed || entries.isEmpty) return;

    final additions = entries
        .where((entry) => !hasItem(entry.itemId))
        .toList(growable: false);
    if (additions.isEmpty) return;

    await _runStructuralMutation(() async {
      for (final entry in _sortedEntries(additions)) {
        final insertionIndex = _insertionIndexFor(entry.playPosition);
        _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
          ..insert(insertionIndex, entry);
        await _player.insertAudioSource(insertionIndex, _sourceForEntry(entry));
      }
    }, preservedCurrentItemId: _committedCurrentItemId);
  }

  Future<void> replaceFutureEntries({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    if (_isDisposed) return;

    final currentIndex = _localIndexFor(currentItemId);
    if (currentIndex == null) {
      throw StateError('Current item is not loaded');
    }

    await _runStructuralMutation(() async {
      for (var i = _loadedEntries.length - 1; i > currentIndex; i--) {
        _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
          ..removeAt(i);
        await _player.removeAudioSourceAt(i);
      }

      for (final entry in _sortedEntries(entries)) {
        final insertionIndex = _insertionIndexFor(entry.playPosition);
        _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
          ..insert(insertionIndex, entry);
        await _player.insertAudioSource(insertionIndex, _sourceForEntry(entry));
      }
    }, preservedCurrentItemId: currentItemId);
  }

  Future<void> rebuildAroundCurrent({
    required int currentItemId,
    required List<QueuePlaybackEntry> entries,
  }) async {
    if (_isDisposed) return;

    final currentIndex = _localIndexFor(currentItemId);
    if (currentIndex == null) {
      throw StateError('Current item is not loaded');
    }

    final sortedEntries = _sortedEntries(entries);
    final desiredCurrentIndex = sortedEntries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (desiredCurrentIndex < 0) {
      throw StateError('Current item is missing from rebuilt queue');
    }

    await _runStructuralMutation(() async {
      for (var i = _loadedEntries.length - 1; i > currentIndex; i--) {
        await _player.removeAudioSourceAt(i);
      }
      for (var i = 0; i < currentIndex; i++) {
        await _player.removeAudioSourceAt(0);
      }

      final prefix = sortedEntries
          .take(desiredCurrentIndex)
          .toList(growable: false);
      for (var i = 0; i < prefix.length; i++) {
        await _player.insertAudioSource(i, _sourceForEntry(prefix[i]));
      }

      final suffix = sortedEntries
          .skip(desiredCurrentIndex + 1)
          .toList(growable: false);
      for (var i = 0; i < suffix.length; i++) {
        await _player.insertAudioSource(
          prefix.length + 1 + i,
          _sourceForEntry(suffix[i]),
        );
      }

      _loadedEntries = sortedEntries;
    }, preservedCurrentItemId: currentItemId);
  }

  Future<void> removeItem(int itemId) async {
    if (_isDisposed) return;

    final localIndex = _localIndexFor(itemId);
    if (localIndex == null) return;

    await _runStructuralMutation(() async {
      _loadedEntries = List<QueuePlaybackEntry>.from(_loadedEntries)
        ..removeAt(localIndex);
      await _player.removeAudioSourceAt(localIndex);
    }, preservedCurrentItemId: _committedCurrentItemId);
  }

  void replaceLoadedEntriesMetadata(List<QueuePlaybackEntry> updatedEntries) {
    if (_isDisposed) return;

    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    _loadedEntries = _loadedEntries
        .map((entry) => byItemId[entry.itemId] ?? entry)
        .toList(growable: false);
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
  Future<void> refreshLoadedSourcesForAvailabilityChanges(
    List<QueuePlaybackEntry> updatedEntries,
  ) async {
    if (_isDisposed || _loadedEntries.isEmpty) return;

    final byItemId = {for (final entry in updatedEntries) entry.itemId: entry};
    final currentItemId = _committedCurrentItemId;
    final currentPosition = _player.position;

    final changes = <_SourceAvailabilityChange>[];
    final nextEntries = <QueuePlaybackEntry>[];
    for (var i = 0; i < _loadedEntries.length; i++) {
      final oldEntry = _loadedEntries[i];
      final newEntry = byItemId[oldEntry.itemId] ?? oldEntry;
      nextEntries.add(newEntry);

      final oldKind = _sourceKindFor(oldEntry);
      final newKind = _sourceKindFor(newEntry);
      if (oldKind == newKind && oldEntry.filePath == newEntry.filePath) {
        continue;
      }
      changes.add(_SourceAvailabilityChange(
        index: i,
        entry: newEntry,
        oldKind: oldKind,
        newKind: newKind,
      ));
    }

    if (changes.isEmpty) {
      _loadedEntries = nextEntries;
      return;
    }

    // If the current source was a file that just disappeared and offline mode
    // would refuse to play the streaming replacement, hand off to the
    // coordinator's full-queue rescue rather than rebuilding to a stream that
    // can't actually play.
    final currentChange = currentItemId == null
        ? null
        : changes.where((c) => c.entry.itemId == currentItemId).firstOrNull;
    final rescueTarget = (currentChange != null &&
            currentChange.oldKind == _SourceKind.file &&
            currentChange.newKind == _SourceKind.stream &&
            _isOfflineFn())
        ? currentChange
        : null;

    await _runStructuralMutation(() async {
      _loadedEntries = nextEntries;
      for (final change in changes) {
        if (rescueTarget != null && change.entry.itemId == currentItemId) {
          continue;
        }
        await _player.removeAudioSourceAt(change.index);
        await _player.insertAudioSource(
          change.index,
          _sourceForEntry(change.entry),
        );
      }
      if (rescueTarget == null &&
          currentChange != null &&
          currentItemId != null) {
        final localIndex = _localIndexFor(currentItemId);
        if (localIndex != null) {
          await _player.seek(currentPosition, index: localIndex);
        }
      }
    }, preservedCurrentItemId: currentItemId);

    if (rescueTarget != null) {
      _unavailableAdvanceController.add(UnavailableAdvance(
        itemId: rescueTarget.entry.itemId,
        playPosition: rescueTarget.entry.playPosition,
      ));
    }
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

  Future<void> seekToItem(int itemId, {Duration position = Duration.zero}) {
    final localIndex = _localIndexFor(itemId);
    if (localIndex == null) {
      throw StateError('Cannot seek to an item that has not been hydrated');
    }
    return _player.seek(position, index: localIndex);
  }

  int? get currentIndex => _player.currentIndex;

  int? get currentItemId => _committedCurrentItemId;

  String? get currentUuid {
    final itemId = _committedCurrentItemId;
    if (itemId == null) return null;
    for (final entry in _loadedEntries) {
      if (entry.itemId == itemId) {
        return entry.uuidId;
      }
    }
    return null;
  }

  Duration get position => _player.position;

  int get queueLength => _loadedEntries.length;

  List<int> get loadedItemIds =>
      _loadedEntries.map((entry) => entry.itemId).toList(growable: false);

  bool hasItem(int itemId) => _localIndexFor(itemId) != null;

  Future<void> play() async {
    if (_isDisposed) return;
    unawaited(
      _player.play().catchError((Object error, StackTrace stackTrace) {
        developer.log(
          'Failed to start playback',
          name: 'ConcatenatingPlayerController',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> pause() => _player.pause();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  Future<void> stop() => _player.stop();
  Future<void> setLoopMode(ja.LoopMode mode) => _player.setLoopMode(mode);

  Stream<ja.PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<int?> get currentItemIdStream => _currentItemIdController.stream;
  Stream<UnavailableAdvance> get unavailableAdvanceStream =>
      _unavailableAdvanceController.stream;

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    unawaited(_currentIndexSubscription?.cancel());
    unawaited(_currentItemIdController.close());
    unawaited(_unavailableAdvanceController.close());
    unawaited(_player.dispose());
  }

  /// Update the quality applied to subsequent source builds. Existing
  /// in-flight sources are not rebuilt — the change takes effect on the next
  /// track loaded into the queue.
  void setStreamQuality(String quality) {
    _streamQuality = quality;
  }

  /// Replace only the currently-playing source with one built at [quality]
  /// and seek to [seekTo]. Used for temporary quality changes so the current
  /// track rebuffers at the new quality without touching the rest of the queue.
  Future<void> rebuildCurrentSource(String quality, Duration seekTo) async {
    if (_isDisposed) return;
    final currentItemId = _committedCurrentItemId;
    if (currentItemId == null) return;
    final localIndex = _localIndexFor(currentItemId);
    if (localIndex == null) return;
    final entry = _loadedEntries[localIndex];

    await _runStructuralMutation(() async {
      _streamQuality = quality;
      await _player.removeAudioSourceAt(localIndex);
      await _player.insertAudioSource(localIndex, _sourceForEntry(entry));
      await _player.seek(seekTo, index: localIndex);
    }, preservedCurrentItemId: currentItemId);
  }

  /// Replace all loaded sources with ones built at [quality] and seek to
  /// [seekTo] in the current track. Used for full quality changes so the entire
  /// ahead-buffered window rebuffers at the new quality.
  Future<void> rebuildAllSources(String quality, Duration seekTo) async {
    if (_isDisposed) return;
    final currentItemId = _committedCurrentItemId;
    if (currentItemId == null) return;
    final localIndex = _localIndexFor(currentItemId);
    if (localIndex == null) return;

    await _runStructuralMutation(() async {
      _streamQuality = quality;
      for (var i = 0; i < _loadedEntries.length; i++) {
        await _player.removeAudioSourceAt(0);
      }
      for (var i = 0; i < _loadedEntries.length; i++) {
        await _player.insertAudioSource(i, _sourceForEntry(_loadedEntries[i]));
      }
      await _player.seek(seekTo, index: localIndex);
    }, preservedCurrentItemId: currentItemId);
  }

  ja.AudioSource _sourceForEntry(QueuePlaybackEntry entry) {
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

  int? _localIndexFor(int itemId) {
    final index = _loadedEntries.indexWhere((entry) => entry.itemId == itemId);
    return index < 0 ? null : index;
  }

  int _insertionIndexFor(int playPosition) {
    for (var i = 0; i < _loadedEntries.length; i++) {
      if (_loadedEntries[i].playPosition > playPosition) {
        return i;
      }
    }
    return _loadedEntries.length;
  }

  static List<QueuePlaybackEntry> _sortedEntries(
    List<QueuePlaybackEntry> entries,
  ) {
    final sorted = List<QueuePlaybackEntry>.from(entries);
    sorted.sort((a, b) => a.playPosition.compareTo(b.playPosition));
    return sorted;
  }

  void _onCurrentIndexChanged(int? index) {
    if (_isDisposed || _structuralMutationDepth > 0) {
      return;
    }
    // Offline: don't commit an index whose source has no verified local file.
    // Report it upward so the coordinator can search the full queue (not just
    // what we currently have loaded) for the next locally playable entry.
    if (index != null && _isOfflineFn() && !_isIndexLocallyPlayable(index)) {
      if (index >= 0 && index < _loadedEntries.length) {
        final unavailable = _loadedEntries[index];
        _unavailableAdvanceController.add(UnavailableAdvance(
          itemId: unavailable.itemId,
          playPosition: unavailable.playPosition,
        ));
      }
      return;
    }
    _commitCurrentItem(_itemIdForIndex(index), emit: true);
  }

  bool _isIndexLocallyPlayable(int index) {
    if (index < 0 || index >= _loadedEntries.length) return false;
    return _hasLocalFile(_loadedEntries[index]);
  }

  Future<void> _runStructuralMutation(
    Future<void> Function() action, {
    required int? preservedCurrentItemId,
  }) async {
    _structuralMutationDepth++;
    try {
      await action();
    } finally {
      _structuralMutationDepth--;
      if (_structuralMutationDepth == 0) {
        _commitCurrentItem(preservedCurrentItemId, emit: false);
      }
    }
  }

  void _commitCurrentItem(int? itemId, {required bool emit}) {
    final changed = _committedCurrentItemId != itemId;
    _committedCurrentItemId = itemId;
    if (emit && changed) {
      _currentItemIdController.add(itemId);
    }
  }

  int? _itemIdForIndex(int? index) {
    if (index == null || index < 0 || index >= _loadedEntries.length) {
      return null;
    }
    return _loadedEntries[index].itemId;
  }
}

enum _SourceKind { file, stream }

class _SourceAvailabilityChange {
  final int index;
  final QueuePlaybackEntry entry;
  final _SourceKind oldKind;
  final _SourceKind newKind;

  const _SourceAvailabilityChange({
    required this.index,
    required this.entry,
    required this.oldKind,
    required this.newKind,
  });
}
