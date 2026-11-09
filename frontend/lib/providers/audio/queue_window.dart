import 'dart:math';

import 'package:frontend/repositories/queue_repository.dart';

/// A proposed extension. The playback core applies it before acknowledging
/// coverage; the proposer has no engine dependency (SC-27 invariant 7).
class QueueWindowProposal {
  const QueueWindowProposal(this.entries, this.nextForwardPlayPosition, {
    this.replaceCoverage = false,
  });
  final List<QueuePlaybackEntry> entries;
  final int nextForwardPlayPosition;
  final bool replaceCoverage;
}

class QueueWindow {
  QueueWindow(this._repository);
  final QueueRepository _repository;
  static const seedPreviousCount = 12;
  static const seedNextCount = 48;
  int nextForwardHydrationPlayPosition = 0;
  Future<void>? _hydrateFuture;
  bool _disposed = false;

  void reset() => nextForwardHydrationPlayPosition = 0;
  void dispose() => _disposed = true;
  void acknowledge(QueueWindowProposal proposal) {
    nextForwardHydrationPlayPosition = proposal.replaceCoverage
        ? proposal.nextForwardPlayPosition
        : max(nextForwardHydrationPlayPosition, proposal.nextForwardPlayPosition);
  }

  Future<List<QueuePlaybackEntry>> seedEntriesForPlayPosition(int sessionId, int position) =>
      _repository.getPlaybackEntries(sessionId,
        startPlayPosition: max(0, position - seedPreviousCount),
        limit: seedPreviousCount + seedNextCount + 1);

  Future<QueueWindowProposal?> proposeItemLoad(int sessionId, QueuePlaybackEntry entry, {
    required bool alreadyLoaded,
  }) async {
    if (alreadyLoaded) return null;
    final entries = await seedEntriesForPlayPosition(sessionId, entry.playPosition);
    if (entries.isEmpty) return null;
    return QueueWindowProposal(entries,
        entries.map((entry) => entry.playPosition).reduce(max) + 1);
  }

  void scheduleForwardHydration({
    required int sessionId,
    required int totalCount,
    required int currentPlayPosition,
    required Future<void> Function(QueueWindowProposal) apply,
  }) {
    if (_disposed || _hydrateFuture != null) return;
    if (nextForwardHydrationPlayPosition >= totalCount) return;
    if (nextForwardHydrationPlayPosition - currentPlayPosition > 24) return;
    final future = _hydrateForwardChunk(sessionId, totalCount, apply);
    _hydrateFuture = future;
    future.whenComplete(() {
      if (identical(_hydrateFuture, future)) _hydrateFuture = null;
      if (!_disposed) {
        scheduleForwardHydration(sessionId: sessionId, totalCount: totalCount,
            currentPlayPosition: currentPlayPosition, apply: apply);
      }
    });
  }

  Future<void> _hydrateForwardChunk(int sessionId, int totalCount,
      Future<void> Function(QueueWindowProposal) apply) async {
    if (nextForwardHydrationPlayPosition >= totalCount) return;
    final entries = await _repository.getPlaybackEntries(sessionId,
        startPlayPosition: nextForwardHydrationPlayPosition, limit: 50);
    final next = entries.isEmpty ? totalCount : entries.last.playPosition + 1;
    await apply(QueueWindowProposal(entries, next, replaceCoverage: true));
  }
}
