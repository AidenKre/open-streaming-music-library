import 'dart:io';

import 'package:frontend/repositories/queue_repository.dart';

enum PlaybackSourceKind { local, remote }

sealed class PlaybackResolutionIssue {
  const PlaybackResolutionIssue();
}

final class LocalFileMissing extends PlaybackResolutionIssue {
  const LocalFileMissing(this.trackUuid, this.path);
  final String trackUuid;
  final String path;
}

class PlaybackTarget {
  const PlaybackTarget(this.entry, this.sourceKind);
  final QueuePlaybackEntry entry;
  final PlaybackSourceKind sourceKind;
}

/// A decision retains issues even when there is no playable target.
class PlaybackTargetResolution {
  const PlaybackTargetResolution(this.target, {this.issues = const []});
  final PlaybackTarget? target;
  final List<PlaybackResolutionIssue> issues;
}

/// SC-27 invariant 8: decides, never applies or publishes. File checks stay
/// synchronous during the 5B.0b extraction; 5B.0d makes them asynchronous.
class PlaybackTargetResolver {
  PlaybackTargetResolver(this._repository, {bool Function(String)? fileExists})
      : _fileExists = fileExists ?? ((path) => File(path).existsSync());

  final QueueRepository _repository;
  final bool Function(String) _fileExists;

  Future<PlaybackTargetResolution> resolveStart({
    required int sessionId,
    required int preferredItemId,
    required int totalCount,
    required bool offline,
  }) async {
    if (totalCount <= 0) return const PlaybackTargetResolution(null);
    final issues = <PlaybackResolutionIssue>[];
    final preferred = await _repository.getPlaybackEntryForItem(sessionId, preferredItemId);
    if (preferred != null) {
      final target = _target(preferred, issues);
      if (!offline || target.sourceKind == PlaybackSourceKind.local) {
        return PlaybackTargetResolution(target, issues: List.unmodifiable(issues));
      }
    }
    if (!offline) return PlaybackTargetResolution(null, issues: List.unmodifiable(issues));
    final from = preferred?.playPosition ?? 0;
    final forward = await _walk(sessionId, from, PlayOrderDirection.forward,
        'off', totalCount, false, issues);
    final target = forward ?? await _walk(sessionId, from,
        PlayOrderDirection.backward, 'off', totalCount, false, issues);
    return PlaybackTargetResolution(target, issues: List.unmodifiable(issues));
  }

  Future<PlaybackTargetResolution> resolveAdvance({
    required int sessionId,
    required int fromPlayPosition,
    required PlayOrderDirection direction,
    required String repeatMode,
    required int totalCount,
    required bool offline,
    bool includeStart = false,
  }) async {
    if (totalCount <= 0) return const PlaybackTargetResolution(null);
    final issues = <PlaybackResolutionIssue>[];
    PlaybackTarget? target;
    if (offline) {
      target = await _walk(sessionId, fromPlayPosition, direction, repeatMode,
          totalCount, includeStart, issues);
    } else {
      final step = direction == PlayOrderDirection.forward ? 1 : -1;
      var position = fromPlayPosition + (includeStart ? 0 : step);
      if (position < 0 || position >= totalCount) {
        if (repeatMode != 'all') return const PlaybackTargetResolution(null);
        position = step > 0 ? 0 : totalCount - 1;
      }
      final entries = await _repository.getPlaybackEntries(sessionId,
          startPlayPosition: position, limit: 1);
      if (entries.isNotEmpty) target = _target(entries.first, issues);
    }
    return PlaybackTargetResolution(target, issues: List.unmodifiable(issues));
  }

  PlaybackTarget _target(QueuePlaybackEntry entry, List<PlaybackResolutionIssue> issues) {
    final path = entry.filePath;
    if (path != null && path.isNotEmpty) {
      if (_fileExists(path)) return PlaybackTarget(entry, PlaybackSourceKind.local);
      issues.add(LocalFileMissing(entry.uuidId, path));
    }
    return PlaybackTarget(entry, PlaybackSourceKind.remote);
  }

  Future<PlaybackTarget?> _walk(int sessionId, int from, PlayOrderDirection direction,
      String repeatMode, int totalCount, bool includeStart,
      List<PlaybackResolutionIssue> issues) async {
    final entries = await _repository.getPlaybackEntries(sessionId);
    if (entries.isEmpty) return null;
    final byPosition = {for (final entry in entries) entry.playPosition: entry};
    final step = direction == PlayOrderDirection.forward ? 1 : -1;
    var position = from + (includeStart ? 0 : step);
    for (var visited = 0; visited < totalCount; visited++, position += step) {
      if (position < 0 || position >= totalCount) {
        if (repeatMode != 'all') return null;
        position = position < 0 ? totalCount - 1 : 0;
      }
      final entry = byPosition[position];
      if (entry == null) continue;
      final target = _target(entry, issues);
      if (target.sourceKind == PlaybackSourceKind.local) return target;
    }
    return null;
  }
}
