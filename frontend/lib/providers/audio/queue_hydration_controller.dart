import 'dart:math';

import 'package:frontend/providers/audio/concatenating_player_controller.dart';
import 'package:frontend/repositories/queue_repository.dart';

class QueueHydrationController {
  static const seedPreviousCount = 12;
  static const seedNextCount = 48;
  static const _hydrateChunkSize = 50;
  static const _hydrateThreshold = 24;

  final QueueRepository _queueRepo;
  final ConcatenatingPlayerController _player;

  Future<void>? _hydrateFuture;
  bool _disposed = false;
  int _nextForwardHydrationPlayPosition = 0;

  QueueHydrationController(this._queueRepo, this._player);

  int get nextForwardHydrationPlayPosition => _nextForwardHydrationPlayPosition;

  set nextForwardHydrationPlayPosition(int value) {
    _nextForwardHydrationPlayPosition = value;
  }

  void reset() {
    _nextForwardHydrationPlayPosition = 0;
  }

  void dispose() {
    _disposed = true;
  }

  Future<List<QueuePlaybackEntry>> seedEntriesForPlayPosition(
    int sessionId,
    int playPosition,
  ) {
    final start = max(0, playPosition - seedPreviousCount);
    return _queueRepo.getPlaybackEntries(
      sessionId,
      startPlayPosition: start,
      limit: seedPreviousCount + seedNextCount + 1,
    );
  }

  Future<void> ensureItemLoaded(
    int sessionId,
    QueuePlaybackEntry entry,
  ) async {
    if (_player.hasItem(entry.itemId)) return;
    await ensureItemsLoadedAroundPlayPosition(sessionId, entry.playPosition);
  }

  Future<void> ensureItemsLoadedAroundPlayPosition(
    int sessionId,
    int playPosition,
  ) async {
    final entries = await seedEntriesForPlayPosition(sessionId, playPosition);
    if (entries.isEmpty) return;

    await _player.addEntries(entries);
    final loadedMax = entries.map((entry) => entry.playPosition).reduce(max);
    if (loadedMax + 1 > _nextForwardHydrationPlayPosition) {
      _nextForwardHydrationPlayPosition = loadedMax + 1;
    }
  }

  void scheduleForwardHydration({
    required int sessionId,
    required int totalCount,
    required int currentPlayPosition,
  }) {
    if (_disposed || _hydrateFuture != null) return;
    if (_nextForwardHydrationPlayPosition >= totalCount) return;
    if ((_nextForwardHydrationPlayPosition - currentPlayPosition) >
        _hydrateThreshold) {
      return;
    }

    final future = _hydrateForwardChunk(sessionId, totalCount);
    _hydrateFuture = future;
    future.whenComplete(() {
      if (identical(_hydrateFuture, future)) {
        _hydrateFuture = null;
      }
      if (!_disposed) {
        scheduleForwardHydration(
          sessionId: sessionId,
          totalCount: totalCount,
          currentPlayPosition: currentPlayPosition,
        );
      }
    });
  }

  Future<void> _hydrateForwardChunk(int sessionId, int totalCount) async {
    if (_nextForwardHydrationPlayPosition >= totalCount) return;

    final entries = await _queueRepo.getPlaybackEntries(
      sessionId,
      startPlayPosition: _nextForwardHydrationPlayPosition,
      limit: _hydrateChunkSize,
    );
    if (entries.isEmpty) {
      _nextForwardHydrationPlayPosition = totalCount;
      return;
    }

    await _player.addEntries(entries);
    _nextForwardHydrationPlayPosition = entries.last.playPosition + 1;
  }
}
