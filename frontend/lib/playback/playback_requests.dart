import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/history/click_recorder.dart';

import 'package:frontend/database/database.dart' show OrderParameter;
import 'package:frontend/models/history_intent.dart';
import 'package:frontend/models/library_scope.dart';

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

/// An album or artist played as a collection; built from its scope.
final class CollectionSource extends QueueSource {
  const CollectionSource._(this.sourceType, this.artistId, this.albumId);

  /// Only an album or artist scope names a collection; any other scope is a
  /// programming error.
  factory CollectionSource.of(LibraryScope scope) => switch (scope) {
        AlbumScope() =>
          CollectionSource._('album', scope.artistId, scope.albumId),
        ArtistScope() => CollectionSource._('artist', scope.artistId, null),
        _ => throw ArgumentError.value(
            scope, 'collection', 'not an album or artist scope'),
      };

  @override
  final String sourceType;
  @override
  final int? artistId;
  @override
  final int? albumId;
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

/// How a collection request starts: in canonical order, or from a uniformly
/// random member followed by a random permutation of the rest.
enum ShuffleStart { canonical, random }

/// Play an album or artist (a replacement). [uuids] is the already resolved,
/// canonically ordered, availability-filtered membership; the collection
/// follows its own [shuffle] start, not the sticky shuffle.
final class PlayCollection extends PlaybackRequest {
  const PlayCollection(this.collection, this.uuids,
      {required this.shuffle, super.intent});
  final LibraryScope collection;
  final List<String> uuids;
  final ShuffleStart shuffle;
}

/// Play next / add to queue. With no session it starts one (a replacement).
/// Offline, into an active queue, only the members that play from a local
/// file are enqueued (R1-1); none playable is [RejectedUnplayableOffline].
final class Enqueue extends PlaybackRequest {
  const Enqueue(this.uuids, this.position, {super.intent});
  final List<String> uuids;
  final EnqueuePosition position;
}

/// How the playback core handled a conditional enqueue.
enum EnqueueResult { applied, superseded }

/// How the playback core handled a prepared session's activation:
/// `superseded` when a newer request (or stop) won, `stale` when the
/// prepared session itself is gone (the request ends RejectedEmpty). A
/// failed activation throws (the request ends Failed).
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
/// a replacement (or stop) admitted after it supersedes it, including one
/// admitted while its offline file checks run. Offline, into an active
/// queue, an Enqueue keeps only the members that play from a local file
/// (the resolver's rule, R1-1); when none is playable it ends
/// [RejectedUnplayableOffline] with nothing queued and no click.
///
/// SC-27 invariants held here: 5 (newest request wins, via the core's
/// request revision), 8 (it publishes the issues its resolution found, as
/// an applier) and 9 (one emit site: [submit] records exactly one click
/// per accepted request with an intent, outside the playback lane, never
/// awaited by playback).
///
/// [PlayCollection] (album or artist, SC-05/SC-06) is a replacement through
/// [_replace] that ignores sticky shuffle: it follows its own [ShuffleStart]
/// (canonical, or a full random permutation from the injected generator
/// written before activation) and keeps the current repeat mode. The caller
/// resolves the membership; the playback model never queries the library.
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
                      request.downloadedOnly || _ref.read(streamsUnavailableProvider)(),
                  activate: false,
                )),
        Enqueue() => await _enqueue(request),
        PlayCollection() => await _playCollection(request),
      };
    } catch (error) {
      return Failed(error);
    }
  }

  Future<PlaybackOutcome> _playCollection(PlayCollection request) {
    // A scope that is no collection fails here, before anything is admitted
    // or prepared.
    final source = CollectionSource.of(request.collection);
    final random = request.shuffle == ShuffleStart.random;
    return _replace(
      empty: request.uuids.isEmpty,
      prepare: (_, repeat) => _queue.createSessionFromExplicitList(
        sourceType: source.sourceType,
        sourceArtistId: source.artistId,
        sourceAlbumId: source.albumId,
        trackUuids: request.uuids,
        currentIndex: 0,
        repeatMode: repeat,
        shuffleEnabled: random,
        playOrder: random
            ? _ref.read(queueOrderManagerProvider).initializeShuffled(
                List.generate(request.uuids.length, (i) => i))
            : null,
        activate: false,
      ),
    );
  }

  Future<PlaybackOutcome> _enqueue(Enqueue request) async {
    // The add is timed from its submission (OPEN-6-04 grace after the end).
    final sinceSubmitted = _ref.read(clockProvider).stopwatch();
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
      return await _enqueueAdmitted(request, admittedAt, sinceSubmitted);
    } finally {
      settled.complete();
      if (--_pendingEnqueues == 0) _enqueueFallbackRevisions.clear();
    }
  }

  /// Revisions admitted by Enqueues starting a queue: an Enqueue submitted
  /// before them is older, so they never supersede a later Enqueue.
  final _enqueueFallbackRevisions = <int>{};
  int _pendingEnqueues = 0;

  bool _supersededSince(int admittedAt) {
    for (var r = admittedAt + 1; r <= _player.requestRevision; r++) {
      if (!_enqueueFallbackRevisions.contains(r)) return true;
    }
    return false;
  }

  Future<PlaybackOutcome> _enqueueAdmitted(Enqueue request, int admittedAt,
      MonotonicStopwatch sinceSubmitted) async {
    // Its place in the one admission order is its submission: a
    // replacement (or stop) admitted meanwhile is newer and wins, whether
    // or not it has activated yet; an earlier Enqueue's own start is not
    // newer.
    if (_supersededSince(admittedAt)) return const Superseded();
    var uuids = request.uuids;
    // Whether a queue existed when the Enqueue was admitted: one that
    // vanished during the offline filter was stopped.
    final hadSession =
        _ref.read(queuePlayerProvider).queue.sessionId != null;
    if (_ref.read(streamsUnavailableProvider)()) {
      // Offline, with or without an active queue: only what plays from a
      // local file (R1-1, amends DEV-6-02 and 6-R1-03), by the resolver's
      // own rule, before any queue is started.
      final filtered = await _ref
          .read(playbackTargetResolverProvider)
          .filterPlayableOffline(uuids);
      // Re-checked after every await: a replacement or stop admitted
      // meanwhile wins.
      if (_supersededSince(admittedAt)) {
        await _player.reportIssues(filtered.issues, publish: false);
        return const Superseded();
      }
      await _player.reportIssues(filtered.issues);
      if (_supersededSince(admittedAt)) return const Superseded();
      if (filtered.playable.isEmpty) return const RejectedUnplayableOffline();
      uuids = filtered.playable;
    }
    final sessionId = _ref.read(queuePlayerProvider).queue.sessionId;
    // A queue that existed at admission and vanished during the offline
    // filter was stopped: not a reason to start one.
    if (sessionId == null && hadSession) return const Superseded();
    if (sessionId == null) {
      // No queue to add to: start one; a replacement like any other.
      return _replace(
        onAdmitted: _enqueueFallbackRevisions.add,
        empty: false,
        prepare: (shuffle, repeat) => _queue.createSessionFromExplicitList(
              sourceType: const CustomQueueSource().sourceType,
              trackUuids: uuids,
              repeatMode: repeat,
              shuffleEnabled: shuffle,
              activate: false,
            ),
      );
    }
    final result = await _player.enqueue(uuids, request.position,
        expectedSessionId: sessionId, sinceSubmitted: sinceSubmitted);
    return result == EnqueueResult.applied
        ? Accepted(sessionId)
        : const Superseded();
  }

  Future<PlaybackOutcome> _replace({
    void Function(int revision)? onAdmitted,
    required bool empty,
    required Future<int> Function(bool shuffle, String repeatMode) prepare,
  }) async {
    if (empty) return const RejectedEmpty();
    final player = _player;
    final revision = player.admitReplacement();
    onAdmitted?.call(revision);
    final settled = Completer<void>();
    final previous = _replacements;
    _replacements = Future.wait([previous, settled.future]);
    int? prepared;
    try {
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
      } on NothingToQueue {
        return const RejectedEmpty(); // any other error is a failure
      }
      final sessionId = prepared;
      if (!player.isCurrentRequest(revision)) {
        await _discard(sessionId);
        return const Superseded();
      }
      // A removal between resolving and activating makes the activation
      // stale: re-resolve (bounded) or end empty.
      int? previousPlayPosition;
      for (var attempt = 0; attempt <= _maxReResolves; attempt++) {
        final landing = await _resolveLanding(sessionId, revision,
            previousPlayPosition: previousPlayPosition);
        if (landing.outcome != null) {
          await _discard(sessionId);
          return landing.outcome!;
        }
        final target = landing.target!;
        previousPlayPosition = target.entry.playPosition;
        try {
          await _queue.setPreparedCurrentItem(
              sessionId, target.entry.itemId, target.entry.playPosition);
        } on PreparedSessionGone {
          continue; // the target is gone: re-resolve
        }
        final result = await player.activatePreparedSession(sessionId, target,
            autoPlay: true, requestRevision: revision);
        if (result == ActivationResult.accepted) return Accepted(sessionId);
        if (result == ActivationResult.stale) continue;
        await _discard(sessionId);
        return const Superseded();
      }
      // O4: a prepared session that vanished is unavailable, not superseded.
      await _discard(sessionId);
      return const RejectedEmpty();
    } catch (error) {
      final sessionId = prepared;
      if (sessionId != null) await _discard(sessionId);
      rethrow;
    } finally {
      settled.complete();
    }
  }

  static const _maxReResolves = 2;

  /// Resolves where the prepared session lands: a target, or the outcome
  /// that ends the request (superseded, empty, unplayable offline). On a
  /// retry, a current item that was removed is replaced by the entry now at
  /// the previous target's play position (its successor).
  Future<({PlaybackTarget? target, PlaybackOutcome? outcome})>
      _resolveLanding(int sessionId, int revision,
          {int? previousPlayPosition}) async {
    final player = _player;
    final snapshot = await _queue.getSessionSnapshot(sessionId);
    var preferred = snapshot?.currentItem;
    if (snapshot != null &&
        previousPlayPosition != null &&
        snapshot.session.currentItemId == null) {
      final successor = await _queue.getPlaybackEntries(sessionId,
          startPlayPosition: previousPlayPosition, limit: 1);
      if (successor.isNotEmpty) preferred = successor.first;
    }
    if (snapshot == null || preferred == null) {
      return (target: null, outcome: const RejectedEmpty());
    }
    final offline = _ref.read(streamsUnavailableProvider)();
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
      return (target: null, outcome: const Superseded());
    }
    // Published (and confirmed missing downloads reconciled) before the
    // activation reads its entries.
    await player.reportIssues(resolution.issues);
    final target = resolution.target;
    if (target == null) {
      return (
        target: null,
        outcome: offline
            ? const RejectedUnplayableOffline()
            : const RejectedEmpty()
      );
    }
    return (target: target, outcome: null);
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
