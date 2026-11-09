import 'dart:io';

import 'package:frontend/playback/playback_issue_bus.dart';
import 'package:frontend/repositories/queue_repository.dart';

export 'package:frontend/playback/playback_issue_bus.dart' show LocalFileMissing, PlaybackIssue;

enum PlaybackSourceKind { local, remote }


class PlaybackTarget {
  const PlaybackTarget(this.entry, this.sourceKind);
  final QueuePlaybackEntry entry;
  final PlaybackSourceKind sourceKind;
}

/// A decision retains issues even when there is no playable target.
class PlaybackTargetResolution {
  const PlaybackTargetResolution(this.target, {this.issues = const []});
  final PlaybackTarget? target;
  final List<PlaybackIssue> issues;
}

/// SC-27 invariant 8: decides, never applies or publishes; issues come back
/// on success and on rejection. File checks are an async stat, off the
/// event loop.
class PlaybackTargetResolver {
  PlaybackTargetResolver(this._repository,
      {Future<bool> Function(String)? fileExists})
      : _fileExists = fileExists ?? ((path) => File(path).exists());

  final QueueRepository _repository;
  final Future<bool> Function(String) _fileExists;

  Future<PlaybackTargetResolution> resolveStart({
    required int sessionId,
    required int preferredItemId,
    required int totalCount,
    required bool offline,
  }) async {
    if (totalCount <= 0) return const PlaybackTargetResolution(null);
    final issues = <PlaybackIssue>[];
    final preferred = await _repository.getPlaybackEntryForItem(sessionId, preferredItemId);
    if (preferred != null) {
      final target = await _target(preferred, issues);
      if (!offline || target.sourceKind == PlaybackSourceKind.local) {
        return PlaybackTargetResolution(target, issues: List.unmodifiable(issues));
      }
    }
    if (!offline) return PlaybackTargetResolution(null, issues: List.unmodifiable(issues));
    final from = preferred?.playPosition ?? 0;
    // A preferred item no longer in the session: position 0 is a candidate
    // too (the walk would else start past it).
    final forward = await _walk(sessionId, from, PlayOrderDirection.forward,
        'off', totalCount, preferred == null, issues);
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
    final issues = <PlaybackIssue>[];
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
      if (entries.isNotEmpty) target = await _target(entries.first, issues);
    }
    return PlaybackTargetResolution(target, issues: List.unmodifiable(issues));
  }

  Future<PlaybackTarget> _target(
      QueuePlaybackEntry entry, List<PlaybackIssue> issues) async {
    final path = entry.filePath;
    if (path != null && path.isNotEmpty) {
      if (await _fileExists(path)) {
        return PlaybackTarget(entry, PlaybackSourceKind.local);
      }
      issues.add(LocalFileMissing(entry.uuidId, path));
    }
    return PlaybackTarget(entry, PlaybackSourceKind.remote);
  }

  Future<PlaybackTarget?> _walk(int sessionId, int from, PlayOrderDirection direction,
      String repeatMode, int totalCount, bool includeStart,
      List<PlaybackIssue> issues) async {
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
      final target = await _target(entry, issues);
      if (target.sourceKind == PlaybackSourceKind.local) return target;
    }
    return null;
  }
}
