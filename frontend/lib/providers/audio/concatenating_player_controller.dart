import 'dart:async';
import 'dart:developer' as developer;

import 'package:just_audio/just_audio.dart' as ja;

import 'package:frontend/providers/audio/track_cache_manager.dart';
import 'package:frontend/repositories/queue_repository.dart';

class ConcatenatingPlayerController {
  final ja.AudioPlayer _player;
  final StreamController<int?> _currentItemIdController =
      StreamController<int?>.broadcast();
  List<QueuePlaybackEntry> _loadedEntries = const [];
  StreamSubscription<int?>? _currentIndexSubscription;
  int? _committedCurrentItemId;
  int _structuralMutationDepth = 0;
  bool _isDisposed = false;

  ConcatenatingPlayerController(this._player) {
    _currentIndexSubscription = _player.currentIndexStream.listen(
      _onCurrentIndexChanged,
    );
  }

  factory ConcatenatingPlayerController.create() {
    return ConcatenatingPlayerController(ja.AudioPlayer());
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

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    unawaited(_currentIndexSubscription?.cancel());
    unawaited(_currentItemIdController.close());
    unawaited(_player.dispose());
  }

  ja.AudioSource _sourceForEntry(QueuePlaybackEntry entry) {
    return ja.AudioSource.uri(
      buildTrackStreamUri(entry.uuidId),
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
    _commitCurrentItem(_itemIdForIndex(index), emit: true);
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
