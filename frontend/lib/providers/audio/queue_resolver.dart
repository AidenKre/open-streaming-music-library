import 'dart:math';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_state.dart';

abstract class AudioQueueLookup {
  Future<({List<TrackUI> previous, List<TrackUI> next})> resolveCandidates({
    required TrackUI current,
    required QueueContext context,
    required ShuffleSlice shuffle,
    required QueueRepeatMode repeatMode,
    required int limit,
  });

  Future<List<TrackUI>> resolveUpcoming({
    required TrackUI track,
    required QueueContext context,
    required ShuffleSlice shuffle,
    required QueueRepeatMode repeatMode,
  });
}

List<RowFilterParameter> cursorFromTrack(
  TrackUI track,
  List<OrderParameter> orderParams,
) {
  return orderParams.map((o) {
    final value = switch (o.column) {
      'artist' => track.artist,
      'album' => track.album,
      'disc_number' => track.discNumber,
      'track_number' => track.trackNumber,
      'uuid_id' => track.uuidId,
      'title' => track.title,
      'album_artist' => track.albumArtist,
      'year' => track.year,
      'date' => track.date,
      'genre' => track.genre,
      'codec' => track.codec,
      'duration' => track.duration,
      'bitrate_kbps' => track.bitrateKbps,
      'sample_rate_hz' => track.sampleRateHz,
      'channels' => track.channels,
      'created_at' => track.createdAt,
      'last_updated' => track.lastUpdated,
      _ => null,
    };
    return RowFilterParameter(column: o.column, value: value);
  }).toList();
}

List<String> uniqueUuids(Iterable<String> uuids, {String? excludeUuid}) {
  final seen = <String>{};
  if (excludeUuid != null) {
    seen.add(excludeUuid);
  }

  final unique = <String>[];
  for (final uuid in uuids) {
    if (seen.add(uuid)) {
      unique.add(uuid);
    }
  }
  return unique;
}

List<String> shuffleWithCurrentFirst(
  List<String> uuids,
  String? currentUuid,
  int seed,
) {
  final shuffled = List<String>.from(uuids);
  shuffled.shuffle(Random(seed));
  if (currentUuid != null) {
    shuffled.remove(currentUuid);
    shuffled.insert(0, currentUuid);
  }
  return shuffled;
}

/// Resolves queue ordering and upcoming tracks from the database.
/// Has NO dependency on just_audio — pure database + state logic.
class QueueResolver implements AudioQueueLookup {
  final AppDatabase _db;

  QueueResolver(this._db);

  Future<List<TrackUI>> tracksForUuidsInOrder(List<String> uuids) async {
    if (uuids.isEmpty) return const [];

    final rows = await _db.getTracksByUuids(
      uuids.toSet().toList(growable: false),
    );
    final byUuid = <String, TrackUI>{};
    for (final row in rows) {
      final track = TrackUI.fromQueryRow(row);
      byUuid[track.uuidId] = track;
    }

    return uuids
        .where(byUuid.containsKey)
        .map((uuid) => byUuid[uuid]!)
        .toList();
  }

  Future<List<TrackUI>> loadShuffleCandidates(
    TrackUI current, {
    required bool forward,
    required int limit,
    required bool allowWrap,
    required List<String> shuffledUuids,
    required int shuffleIndex,
  }) async {
    if (limit <= 0 || shuffledUuids.isEmpty) return const [];

    final currentIndex = _resolveShuffleIndex(
      current,
      shuffledUuids: shuffledUuids,
      shuffleIndex: shuffleIndex,
    );
    if (currentIndex < 0) return const [];

    final total = shuffledUuids.length;
    final uuids = <String>[];
    for (var step = 1; step <= limit; step++) {
      var index = forward ? currentIndex + step : currentIndex - step;
      if (index < 0 || index >= total) {
        if (!allowWrap) break;
        index = ((index % total) + total) % total;
      }
      uuids.add(shuffledUuids[index]);
    }

    return tracksForUuidsInOrder(
      uniqueUuids(uuids, excludeUuid: current.uuidId),
    );
  }

  Future<List<TrackUI>> loadNextCursorCandidates(
    TrackUI current,
    QueueContext context, {
    required int limit,
    required bool allowWrap,
  }) async {
    if (limit <= 0) return const [];

    final cursor = cursorFromTrack(current, context.orderParams);
    final rows = await _db.getTracks(
      orderBy: context.orderParams,
      cursorFilters: cursor,
      artist: context.artist,
      album: context.album,
      limit: limit,
    );
    final tracks = rows.map(TrackUI.fromQueryRow).toList();
    if (tracks.length < limit && allowWrap) {
      final wrapRows = await _db.getTracks(
        orderBy: context.orderParams,
        artist: context.artist,
        album: context.album,
        limit: limit - tracks.length,
      );
      tracks.addAll(wrapRows.map(TrackUI.fromQueryRow));
    }
    return tracksForUuidsInOrder(
      uniqueUuids(
        tracks.map((track) => track.uuidId),
        excludeUuid: current.uuidId,
      ),
    );
  }

  Future<List<TrackUI>> loadPreviousCursorCandidates(
    TrackUI current,
    QueueContext context, {
    required int limit,
    required bool allowWrap,
  }) async {
    if (limit <= 0) return const [];

    final reversed = reversedOrder(context.orderParams);
    final cursor = cursorFromTrack(current, reversed);
    final rows = await _db.getTracks(
      orderBy: reversed,
      cursorFilters: cursor,
      artist: context.artist,
      album: context.album,
      limit: limit,
    );
    final tracks = rows.map(TrackUI.fromQueryRow).toList();
    if (tracks.length < limit && allowWrap) {
      final wrapRows = await _db.getTracks(
        orderBy: reversed,
        artist: context.artist,
        album: context.album,
        limit: limit - tracks.length,
      );
      tracks.addAll(wrapRows.map(TrackUI.fromQueryRow));
    }
    return tracksForUuidsInOrder(
      uniqueUuids(
        tracks.map((track) => track.uuidId),
        excludeUuid: current.uuidId,
      ),
    );
  }

  /// Resolves next/prev candidates based on shuffle state and queue context.
  @override
  Future<({List<TrackUI> previous, List<TrackUI> next})> resolveCandidates({
    required TrackUI current,
    required QueueContext context,
    required ShuffleSlice shuffle,
    required QueueRepeatMode repeatMode,
    required int limit,
  }) async {
    final allowWrappedPrevious = repeatMode == QueueRepeatMode.all;
    final allowWrappedNext = repeatMode == QueueRepeatMode.all;

    final List<TrackUI> previous;
    final List<TrackUI> next;

    if (shuffle.shuffleOn && shuffle.shuffledUuids.isNotEmpty) {
      previous = await loadShuffleCandidates(
        current,
        forward: false,
        limit: limit,
        allowWrap: allowWrappedPrevious,
        shuffledUuids: shuffle.shuffledUuids,
        shuffleIndex: shuffle.shuffleIndex,
      );
      next = await loadShuffleCandidates(
        current,
        forward: true,
        limit: limit,
        allowWrap: allowWrappedNext,
        shuffledUuids: shuffle.shuffledUuids,
        shuffleIndex: shuffle.shuffleIndex,
      );
    } else {
      previous = await loadPreviousCursorCandidates(
        current,
        context,
        limit: limit,
        allowWrap: allowWrappedPrevious,
      );
      next = await loadNextCursorCandidates(
        current,
        context,
        limit: limit,
        allowWrap: allowWrappedNext,
      );
    }

    return (previous: previous, next: next);
  }

  /// Resolves the upcoming tracks list (up to 20) for display in the queue view.
  @override
  Future<List<TrackUI>> resolveUpcoming({
    required TrackUI track,
    required QueueContext context,
    required ShuffleSlice shuffle,
    required QueueRepeatMode repeatMode,
  }) async {
    if (shuffle.shuffleOn && shuffle.shuffledUuids.isNotEmpty) {
      final total = shuffle.shuffledUuids.length;
      if (total == 0) {
        return const [];
      }
      final uuids = <String>[];
      for (var step = 1; step <= 20; step++) {
        var index = shuffle.shuffleIndex + step;
        if (index >= total) {
          if (repeatMode != QueueRepeatMode.all) break;
          index %= total;
        }
        uuids.add(shuffle.shuffledUuids[index]);
      }
      final rows = await _db.getTracksByUuids(uuids);
      final map = <String, TrackUI>{};
      for (final row in rows) {
        final t = TrackUI.fromQueryRow(row);
        map[t.uuidId] = t;
      }
      return uniqueUuids(
        uuids,
        excludeUuid: track.uuidId,
      ).where((u) => map.containsKey(u)).map((u) => map[u]!).toList();
    } else {
      final tracks = <TrackUI>[];
      final cursor = cursorFromTrack(track, context.orderParams);
      final rows = await _db.getTracks(
        orderBy: context.orderParams,
        cursorFilters: cursor,
        artist: context.artist,
        album: context.album,
        limit: 20,
      );
      tracks.addAll(rows.map(TrackUI.fromQueryRow));
      if (tracks.length < 20 && repeatMode == QueueRepeatMode.all) {
        final wrapRows = await _db.getTracks(
          orderBy: context.orderParams,
          artist: context.artist,
          album: context.album,
          limit: 20 - tracks.length,
        );
        tracks.addAll(wrapRows.map(TrackUI.fromQueryRow));
      }
      return tracksForUuidsInOrder(
        uniqueUuids(
          tracks.map((candidate) => candidate.uuidId),
          excludeUuid: track.uuidId,
        ),
      );
    }
  }

  int _resolveShuffleIndex(
    TrackUI track, {
    required List<String> shuffledUuids,
    required int shuffleIndex,
  }) {
    if (shuffledUuids.isEmpty) return -1;
    if (shuffleIndex >= 0 &&
        shuffleIndex < shuffledUuids.length &&
        shuffledUuids[shuffleIndex] == track.uuidId) {
      return shuffleIndex;
    }
    return shuffledUuids.indexOf(track.uuidId);
  }
}
