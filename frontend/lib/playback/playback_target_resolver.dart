import 'dart:io';

import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/playback_issue_bus.dart';
import 'package:frontend/repositories/queue_repository.dart';

export 'package:frontend/playback/playback_issue_bus.dart' show LocalFileMissing, PlaybackIssue;
// Its home is the engine interface; re-exported for existing importers.
export 'package:frontend/playback/playback_engine.dart' show PlaybackSourceKind;


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
      {Future<bool> Function(String)? fileExists,
      LocalSourcePolicy? localSources})
      : _fileExists = fileExists ?? ((path) => File(path).exists()),
        _localSources = localSources ?? LocalSourcePolicy();

  final QueueRepository _repository;
  final Future<bool> Function(String) _fileExists;

  /// Whether an entry plays from its download (shared with the engine).
  final LocalSourcePolicy _localSources;

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

  /// Offline: the members of [uuids] that play from a local file (the rule
  /// of a landing target, [_localFile]), in order and with duplicates, and
  /// the issues found on the way. Uuids the library doesn't know are
  /// dropped.
  Future<({List<String> playable, List<PlaybackIssue> issues})>
      filterPlayableOffline(List<String> uuids) async {
    final sources = await _repository.getLocalSourcesForUuids(uuids);
    final issues = <PlaybackIssue>[];
    final local = <String, bool>{};
    for (final uuid in sources.keys) {
      final source = sources[uuid]!;
      local[uuid] = await _localFile(
              uuid, source.filePath, source.downloadedCodec, issues) !=
          null;
    }
    return (
      playable: [
        for (final uuid in uuids)
          if (local[uuid] ?? false) uuid
      ],
      issues: List<PlaybackIssue>.unmodifiable(issues),
    );
  }

  /// The one local-playability rule: the path [uuid] plays from when the
  /// download is usable, decodable, not suspected and on disk; a recorded
  /// path missing on disk adds a [LocalFileMissing] issue.
  Future<String?> _localFile(String uuid, String? filePath,
      String? downloadedCodec, List<PlaybackIssue> issues) async {
    final path = _localSources.localPathOf(
        uuid: uuid, filePath: filePath, downloadedCodec: downloadedCodec);
    if (path == null) return null;
    if (await _fileExists(path)) return path;
    issues.add(LocalFileMissing(uuid, path));
    return null;
  }

  Future<PlaybackTarget> _target(
      QueuePlaybackEntry entry, List<PlaybackIssue> issues) async {
    final path = await _localFile(
        entry.uuidId, entry.filePath, entry.downloadedCodec, issues);
    return PlaybackTarget(
        entry, path != null ? PlaybackSourceKind.local : PlaybackSourceKind.remote);
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
