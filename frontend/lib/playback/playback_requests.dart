import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/history/click_recorder.dart';

import 'package:frontend/database/database.dart' show OrderParameter;
import 'package:frontend/models/history_intent.dart';

/// Where a queue came from (SC-05: typed, not a free string). Its
/// [sourceType] is what the queue session row records.
sealed class QueueSource {
  const QueueSource();
  String get sourceType;
  int? get artistId => null;
  int? get albumId => null;
}

/// An explicit ordered list (search results, a single track, recents).
final class ListSource extends QueueSource {
  const ListSource(this.sourceType);
  @override
  final String sourceType;
}

/// A browse query (library, artist or album list).
final class BrowseSource extends QueueSource {
  const BrowseSource(this.sourceType, {this.artistId, this.albumId});
  @override
  final String sourceType;
  @override
  final int? artistId;
  @override
  final int? albumId;
}

/// Tracks queued with no session to add them to.
final class CustomQueueSource extends QueueSource {
  const CustomQueueSource();
  @override
  String get sourceType => 'custom';
}

enum EnqueuePosition { next, end }

/// SC-05 `PlaybackRequest`.
sealed class PlaybackRequest {
  const PlaybackRequest({this.intent});
  final HistoryIntent? intent;
}

/// Play an explicit ordered list from [startIndex] (a replacement).
final class PlayList extends PlaybackRequest {
  const PlayList(this.uuids, this.startIndex, this.source, {super.intent});
  final List<String> uuids;
  final int startIndex;
  final QueueSource source;
}

/// Play a browse query from [currentUuid] (a replacement).
final class PlayQuery extends PlaybackRequest {
  const PlayQuery({
    required this.source,
    required this.currentUuid,
    this.order = const [],
    this.downloadedOnly = false,
    super.intent,
  });
  final BrowseSource source;
  final String currentUuid;
  final List<OrderParameter> order;
  final bool downloadedOnly;
}

/// Play next / add to queue. With no session it starts one (a replacement).
final class Enqueue extends PlaybackRequest {
  const Enqueue(this.uuids, this.position, {super.intent});
  final List<String> uuids;
  final EnqueuePosition position;
}

/// How the playback core handled a conditional enqueue.
enum EnqueueResult { applied, superseded }

/// How the playback core handled a prepared session's activation.
/// A failed activation throws (the request ends Failed).
enum ActivationResult { accepted, superseded, stale }

/// SC-05 `PlaybackOutcome`.
sealed class PlaybackOutcome {
  const PlaybackOutcome();
}

final class Accepted extends PlaybackOutcome {
  const Accepted(this.sessionId);
  final int sessionId;
  @override
  String toString() => 'Accepted($sessionId)';
}

final class Superseded extends PlaybackOutcome {
  const Superseded();
  @override
  String toString() => 'Superseded';
}

final class RejectedEmpty extends PlaybackOutcome {
  const RejectedEmpty();
  @override
  String toString() => 'RejectedEmpty';
}

final class RejectedUnplayableOffline extends PlaybackOutcome {
  const RejectedUnplayableOffline();
  @override
  String toString() => 'RejectedUnplayableOffline';
}

final class Failed extends PlaybackOutcome {
  const Failed(this.error);
  final Object error;
  @override
  String toString() => 'Failed($error)';
}

/// The one playback entry point (SC-05/SC-27).
///
/// A replacement request (PlayList, PlayQuery, the no-session Enqueue) is
/// admitted with a new request revision (the newest wins), prepares an
/// inactive session outside the playback lane (sticky shuffle applies at
/// creation), resolves where it lands under the offline policy (publishing
/// the issues it finds, on rejection too), and only then asks the core to
/// activate it. A rejected, superseded or failed request discards its
/// prepared session and leaves the current queue, status and audio
/// untouched. An Enqueue takes its place in the same admission order: it
/// waits for every earlier request and targets the session they produced;
/// a replacement (or stop) admitted after it supersedes it.
///
/// SC-27 invariants held here: 5 (newest request wins, via the core's
/// request revision), 8 (it publishes the issues its resolution found, as
/// an applier) and 9 (one emit site: [submit] records exactly one click
/// per accepted request with an intent, outside the playback lane, never
/// awaited by playback).
///
/// Phase 6 handoff (`PlayCollection`, SC-05/SC-06): a new [PlaybackRequest]
/// arm carries the collection reference and its [HistoryIntent] (album or
/// artist: one collection click, never one per member); it is a
/// replacement through [_replace] with its own `prepare` (collection order,
/// which may ignore sticky shuffle) and a [QueueSource] arm naming the
/// collection. Membership and the SC-04 `catalog_reconciled_at_binding`
/// gate are model work behind that prepare, never a controller's.
class PlaybackRequests {
  PlaybackRequests(this._ref);
  final Ref _ref;
  Future<void> _replacements = Future<void>.value();

  QueuePlayer get _player => _ref.read(queuePlayerProvider.notifier);
  QueueRepository get _queue => _ref.read(queueRepositoryProvider);

  Future<PlaybackOutcome> submit(PlaybackRequest request) async {
    final outcome = await _submit(request);
    final intent = request.intent;
    if (outcome is Accepted && intent != null) {
      // The one click emit site (SC-05): once per accepted request, outside
      // the playback lane, never awaited by playback.
      unawaited(_ref.read(clickRecorderProvider).record(intent).catchError(
          (Object error) => developer.log('Click not recorded',
              name: 'PlaybackRequests', error: error)));
    }
    return outcome;
  }

  Future<PlaybackOutcome> _submit(PlaybackRequest request) async {
    try {
      return switch (request) {
        PlayList() => await _replace(
            empty: request.uuids.isEmpty,
            prepare: (shuffle, repeat) => _queue.createSessionFromExplicitList(
                  sourceType: request.source.sourceType,
                  sourceArtistId: request.source.artistId,
                  sourceAlbumId: request.source.albumId,
                  trackUuids: request.uuids,
                  currentIndex: request.startIndex,
                  repeatMode: repeat,
                  shuffleEnabled: shuffle,
                  activate: false,
                )),
        PlayQuery() => await _replace(
            empty: false,
            prepare: (shuffle, repeat) => _queue.createSessionFromQuery(
                  sourceType: request.source.sourceType,
                  sourceArtistId: request.source.artistId,
                  sourceAlbumId: request.source.albumId,
                  currentUuid: request.currentUuid,
                  orderBy: request.order,
                  repeatMode: repeat,
                  shuffleEnabled: shuffle,
                  // Offline a browse queue holds only what can play.
                  downloadedOnly:
                      request.downloadedOnly || _ref.read(offlineModeProvider),
                  activate: false,
                )),
        Enqueue() => await _enqueue(request),
      };
    } catch (error) {
      return Failed(error);
    }
  }

  Future<PlaybackOutcome> _enqueue(Enqueue request) async {
    if (request.uuids.isEmpty) return const RejectedEmpty();
    final admittedAt = _player.requestRevision;
    // One admission order: behind every earlier request, Enqueues included
    // (a second no-session Enqueue then targets the queue the first made).
    final settled = Completer<void>();
    final earlier = _replacements;
    _replacements = Future.wait([earlier, settled.future]);
    _pendingEnqueues++;
    try {
      await earlier;
      return await _enqueueAdmitted(request, admittedAt);
    } finally {
      settled.complete();
      if (--_pendingEnqueues == 0) _enqueueFallbackRevisions.clear();
    }
  }

  /// Revisions admitted by Enqueues starting a queue: an Enqueue submitted
  /// before them is older, so they never supersede a later Enqueue.
  final _enqueueFallbackRevisions = <int>{};
  int _pendingEnqueues = 0;

  Future<PlaybackOutcome> _enqueueAdmitted(
      Enqueue request, int admittedAt) async {
    // Its place in the one admission order is its submission: a
    // replacement (or stop) admitted meanwhile is newer and wins, whether
    // or not it has activated yet; an earlier Enqueue's own start is not
    // newer.
    for (var r = admittedAt + 1; r <= _player.requestRevision; r++) {
      if (!_enqueueFallbackRevisions.contains(r)) return const Superseded();
    }
    final sessionId = _ref.read(queuePlayerProvider).queue.sessionId;
    if (sessionId == null) {
      // No queue to add to: start one; a replacement like any other.
      return _replace(
        onAdmitted: _enqueueFallbackRevisions.add,
        empty: false,
        prepare: (shuffle, repeat) => _queue.createSessionFromExplicitList(
              sourceType: const CustomQueueSource().sourceType,
              trackUuids: request.uuids,
              repeatMode: repeat,
              shuffleEnabled: shuffle,
              activate: false,
            ),
      );
    }
    final result = await _player.enqueue(request.uuids, request.position,
        expectedSessionId: sessionId);
    return result == EnqueueResult.applied
        ? Accepted(sessionId)
        : const Superseded();
  }

  Future<PlaybackOutcome> _replace({
    void Function(int revision)? onAdmitted,
    required bool empty,
    required Future<int> Function(bool shuffle, String repeatMode) prepare,
  }) async {
    final player = _player;
    final revision = player.admitReplacement();
    onAdmitted?.call(revision);
    final settled = Completer<void>();
    final previous = _replacements;
    _replacements = Future.wait([previous, settled.future]);
    int? prepared;
    try {
      if (empty) return const RejectedEmpty();
      // Never prepared before this scope's startup prune (it would delete
      // the prepared session).
      try {
        await _queue.pruneInactiveSessionsOnce();
      } on BindingFencedException {
        // no session store; preparing fails the same way below
      }
      final state = _ref.read(queuePlayerProvider);
      try {
        prepared = await prepare(
            state.shuffle.shuffleOn, state.queue.repeatMode.name);
      } on StateError {
        return const RejectedEmpty(); // nothing to queue
      }
      final sessionId = prepared;
      if (!player.isCurrentRequest(revision)) {
        await _discard(sessionId);
        return const Superseded();
      }
      final snapshot = await _queue.getSessionSnapshot(sessionId);
      final preferred = snapshot?.currentItem;
      if (snapshot == null || preferred == null) {
        await _discard(sessionId);
        return const RejectedEmpty();
      }
      final offline = _ref.read(offlineModeProvider);
      final resolution = await _ref.read(playbackTargetResolverProvider)
          .resolveStart(
            sessionId: sessionId,
            preferredItemId: preferred.itemId,
            totalCount: snapshot.totalCount,
            offline: offline,
          );
      if (!player.isCurrentRequest(revision)) {
        // Superseded while resolving: no issues reported, but a confirmed
        // missing download is still reconciled.
        await player.reportIssues(resolution.issues, publish: false);
        await _discard(sessionId);
        return const Superseded();
      }
      // Published (and confirmed missing downloads reconciled) before the
      // activation reads its entries.
      await player.reportIssues(resolution.issues);
      final target = resolution.target?.entry;
      if (target == null) {
        await _discard(sessionId);
        return offline
            ? const RejectedUnplayableOffline()
            : const RejectedEmpty();
      }
      final result = await player.activatePreparedSession(sessionId, target,
          autoPlay: true, requestRevision: revision);
      if (result == ActivationResult.accepted) return Accepted(sessionId);
      await _discard(sessionId);
      return const Superseded();
    } catch (error) {
      final sessionId = prepared;
      if (sessionId != null) await _discard(sessionId);
      rethrow;
    } finally {
      settled.complete();
    }
  }

  Future<void> _discard(int sessionId) async {
    try {
      await _queue.discardSession(sessionId);
    } catch (_) {
      // Pruned at the next startup.
    }
  }
}

final playbackRequestsProvider =
    Provider<PlaybackRequests>((ref) => PlaybackRequests(ref));
