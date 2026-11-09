import 'dart:developer' as developer;
import 'dart:math';

import 'package:frontend/repositories/queue_repository.dart';

/// A proposed forward extension of the window. The playback core applies
/// it in its lane (after checking it is still current) and only then
/// acknowledges it; the proposer has no engine dependency.
class QueueWindowProposal {
  const QueueWindowProposal(
    this.entries,
    this.nextForwardPlayPosition, {
    required this.windowRevision,
    this.context,
  });
  final List<QueuePlaybackEntry> entries;
  final int nextForwardPlayPosition;

  /// The window revision this proposal extends; stale after a replacement.
  final int windowRevision;

  /// The core's own snapshot (session, queue and source configuration)
  /// taken when the proposal was started.
  final Object? context;
}

/// The engine window (SC-27 invariant 7): one contiguous interval of play
/// positions `[windowStartPlayPosition, nextForwardHydrationPlayPosition)`
/// around the current item. A distant jump replaces it (the core rebases);
/// forward hydration extends its end. Every replacement bumps
/// [windowRevision], so a hydration proposal started before it is stale.
class QueueWindow {
  QueueWindow(this._repository);
  final QueueRepository _repository;
  static const seedPreviousCount = 12;
  static const seedNextCount = 48;
  static const hydrationChunk = 50;
  static const hydrationThreshold = 24;

  /// End of the window (exclusive).
  int nextForwardHydrationPlayPosition = 0;
  int? _start;
  int _revision = 0;
  Future<void>? _hydrateFuture;
  bool _disposed = false;

  int get windowRevision => _revision;

  /// First loaded play position; null when nothing is loaded.
  int? get windowStartPlayPosition => _start;

  /// Whether the window holds every position of a [totalCount] queue.
  bool coversQueue(int totalCount) =>
      _start == 0 && nextForwardHydrationPlayPosition >= totalCount;

  void reset() {
    _start = null;
    nextForwardHydrationPlayPosition = 0;
    _revision++;
  }

  void dispose() => _disposed = true;

  /// The core replaced what the engine holds with `[start, end)`.
  void replaceWindow({required int start, required int end}) {
    _start = start;
    nextForwardHydrationPlayPosition = end;
    _revision++;
  }

  /// Acknowledges an applied extension. Returns false (and changes
  /// nothing) for a proposal of an older window.
  bool acknowledge(QueueWindowProposal proposal) {
    if (proposal.windowRevision != _revision) return false;
    nextForwardHydrationPlayPosition =
        max(nextForwardHydrationPlayPosition, proposal.nextForwardPlayPosition);
    return true;
  }

  Future<List<QueuePlaybackEntry>> seedEntriesForPlayPosition(
          int sessionId, int position) =>
      _repository.getPlaybackEntries(sessionId,
          startPlayPosition: max(0, position - seedPreviousCount),
          limit: seedPreviousCount + seedNextCount + 1);

  /// Starts one forward chunk when the window's end is near. A request
  /// made while a chunk is in flight is kept (latest wins) and runs after
  /// it. [apply] reports whether the core applied the proposal; only an
  /// applied chunk continues on its own.
  void scheduleForwardHydration({
    required int sessionId,
    required int totalCount,
    required int currentPlayPosition,
    Object? context,
    required Future<bool> Function(QueueWindowProposal) apply,
  }) {
    final request = _HydrationRequest(
        sessionId, totalCount, currentPlayPosition, context, apply);
    if (_disposed) return;
    if (_hydrateFuture != null) {
      _pending = request;
      return;
    }
    _startChunk(request);
  }

  _HydrationRequest? _pending;

  void _startChunk(_HydrationRequest request) {
    if (nextForwardHydrationPlayPosition >= request.totalCount) return;
    if (nextForwardHydrationPlayPosition - request.currentPlayPosition >
        hydrationThreshold) {
      return;
    }
    final future = _hydrateForwardChunk(request);
    _hydrateFuture = future;
    future.then((applied) {
      if (identical(_hydrateFuture, future)) _hydrateFuture = null;
      if (_disposed) return;
      final pending = _pending;
      _pending = null;
      if (pending != null) {
        _startChunk(pending);
      } else if (applied) {
        _startChunk(request);
      }
    });
  }

  Future<bool> _hydrateForwardChunk(_HydrationRequest request) async {
    final revision = _revision;
    try {
      final entries = await _repository.getPlaybackEntries(request.sessionId,
          startPlayPosition: nextForwardHydrationPlayPosition,
          limit: hydrationChunk);
      if (revision != _revision || _disposed) return false; // replaced
      final next = entries.isEmpty
          ? request.totalCount
          : entries.last.playPosition + 1;
      return await request.apply(QueueWindowProposal(entries, next,
          windowRevision: revision, context: request.context));
    } catch (error, stackTrace) {
      // A failed read ends this chunk (the next schedule request retries);
      // apply failures are reported by the core's error sink.
      developer.log('Window hydration read failed', name: 'QueueWindow',
          error: error, stackTrace: stackTrace);
      return false;
    }
  }
}

class _HydrationRequest {
  const _HydrationRequest(this.sessionId, this.totalCount,
      this.currentPlayPosition, this.context, this.apply);
  final int sessionId;
  final int totalCount;
  final int currentPlayPosition;
  final Object? context;
  final Future<bool> Function(QueueWindowProposal) apply;
}
