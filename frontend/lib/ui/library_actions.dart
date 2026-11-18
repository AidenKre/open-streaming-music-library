import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/history_intent.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/collection_ordering.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/settings_service.dart';

/// Every library action a surface offers on a [LibraryScope] (SC-06): the
/// one controller behind TrackTile, LibraryCard and their pages' row taps.
///
/// Stateless and navigation-free (navigation is the view's, via
/// `library_routes.dart`; busy state belongs to the page controller that
/// shows it). Each method resolves membership through the model
/// (`BrowseRepository.getTracksForScope`, passing only whether streams are
/// unavailable now: offline, or the server check failed) and submits typed
/// requests to `PlaybackRequests.submit`, whose outcome it returns. Play and
/// Shuffle replace the queue with an album or artist; Play Next and Add to
/// Queue enqueue any scope.
abstract interface class LibraryActionControls {
  Future<PlaybackOutcome> playNext(LibraryScope scope);

  Future<PlaybackOutcome> addToQueue(LibraryScope scope);

  /// Replace the queue with an album or artist [collection], in its
  /// canonical order (shuffle off for the new session).
  Future<PlaybackOutcome> play(LibraryScope collection);

  /// Replace the queue with [collection] from a random member, followed by a
  /// random permutation of the rest.
  Future<PlaybackOutcome> shuffle(LibraryScope collection);

  /// Play an explicit ordered list (e.g. search results) from
  /// [startIndex].
  Future<PlaybackOutcome> playFromList(
    List<TrackUI> tracks,
    int startIndex, {
    required String source,
  });

  /// A browse row tap: play [album]'s list (or, null, the library's) from
  /// [track], in the list's [CollectionOrdering], keeping the list's
  /// [downloadedOnly] filter so the queue is what the list shows.
  Future<PlaybackOutcome> playQuery(
    TrackUI track, {
    AlbumScope? album,
    required bool downloadedOnly,
  });

  /// Download the scope's missing tracks at the default download quality.
  Future<void> download(LibraryScope scope);

  Future<void> downloadAtQuality(LibraryScope scope, String quality);

  /// Delete the scope's local downloads (never anything on the server).
  Future<void> deleteDownloads(LibraryScope scope);
}

final libraryActionsProvider = Provider<LibraryActionControls>(
  (ref) => LibraryActions(ref),
);

class LibraryActions implements LibraryActionControls {
  LibraryActions(this._ref);

  final Ref _ref;

  // Offline, or the server check failed (sign-off OPEN-M-11): the one rule
  // every play path reads, so only members that can play now are queued.
  Future<List<TrackUI>> _members(LibraryScope scope) => _ref
      .read(browseRepositoryProvider)
      .getTracksForScope(scope,
          offline: _ref.read(streamsUnavailableProvider)());

  // Download and Delete act on the whole collection, offline or not: Delete
  // must reach damaged files and fence queued downloads of every member, and
  // Download fetches the missing members.
  Future<List<TrackUI>> _allMembers(LibraryScope scope) => _ref
      .read(browseRepositoryProvider)
      .getTracksForScope(scope, offline: false);

  @override
  Future<PlaybackOutcome> playNext(LibraryScope scope) =>
      _enqueue(scope, EnqueuePosition.next);

  @override
  Future<PlaybackOutcome> addToQueue(LibraryScope scope) =>
      _enqueue(scope, EnqueuePosition.end);

  @override
  Future<PlaybackOutcome> play(LibraryScope collection) => _submitMembers(
        collection,
        (uuids, intent) => PlayCollection(collection, uuids,
            shuffle: ShuffleStart.canonical, intent: intent),
      );

  @override
  Future<PlaybackOutcome> shuffle(LibraryScope collection) => _submitMembers(
        collection,
        (uuids, intent) => PlayCollection(collection, uuids,
            shuffle: ShuffleStart.random, intent: intent),
      );

  Future<PlaybackOutcome> _enqueue(
          LibraryScope scope, EnqueuePosition position) =>
      _submitMembers(scope,
          (uuids, intent) => Enqueue(uuids, position, intent: intent));

  /// The shared pipeline: membership, then the server binding, then one
  /// submit. An ended session or an empty membership is [RejectedEmpty]
  /// without submitting (an empty request would still admit a revision and
  /// supersede an in-flight one). A throw from the membership or binding
  /// read is [Failed]; the submit reports its own outcomes.
  Future<PlaybackOutcome> _submitMembers(
    LibraryScope scope,
    PlaybackRequest Function(List<String> uuids, HistoryIntent? intent) build,
  ) async {
    final List<TrackUI> tracks;
    final ServerBindingRecord? binding;
    try {
      tracks = await _members(scope);
      if (!_ref.mounted || tracks.isEmpty) return const RejectedEmpty();
      binding = await _ref.read(serverBindingRepositoryProvider).current();
    } catch (error) {
      return Failed(error);
    }
    if (!_ref.mounted) return const RejectedEmpty();
    return _ref.read(playbackRequestsProvider).submit(build(
          [for (final t in tracks) t.uuidId],
          HistoryIntent.forScope(scope, binding),
        ));
  }

  @override
  Future<PlaybackOutcome> playFromList(
    List<TrackUI> tracks,
    int startIndex, {
    required String source,
  }) async {
    // A stale tap (the list changed under it) has nothing to start.
    if (startIndex < 0 || startIndex >= tracks.length) {
      return const RejectedEmpty();
    }
    return _ref.read(playbackRequestsProvider).submit(PlayList(
          [for (final t in tracks) t.uuidId],
          startIndex,
          ListSource(source),
          intent: HistoryIntent.track(tracks[startIndex].uuidId),
        ));
  }

  @override
  Future<PlaybackOutcome> playQuery(
    TrackUI track, {
    AlbumScope? album,
    required bool downloadedOnly,
  }) {
    return _ref.read(playbackRequestsProvider).submit(PlayQuery(
          source: BrowseSource(browseQueueSource(album),
              artistId: album?.artistId, albumId: album?.albumId),
          currentUuid: track.uuidId,
          order: CollectionOrdering.tracksFor(album),
          downloadedOnly: downloadedOnly,
          intent: HistoryIntent.track(track.uuidId),
        ));
  }

  @override
  Future<void> download(LibraryScope scope) async {
    final tracks = await _allMembers(scope);
    if (!_ref.mounted || tracks.isEmpty) return;
    await _ref
        .read(downloadManagerProvider)
        .enqueueTracks(tracks, quality: _ref.read(downloadQualityProvider));
  }

  @override
  Future<void> downloadAtQuality(LibraryScope scope, String quality) async {
    final tracks = await _allMembers(scope);
    if (!_ref.mounted || tracks.isEmpty) return;
    await _ref
        .read(downloadManagerProvider)
        .enqueueTracksAtQuality(tracks, quality: quality);
  }

  @override
  Future<void> deleteDownloads(LibraryScope scope) async {
    final tracks = await _allMembers(scope);
    if (!_ref.mounted || tracks.isEmpty) return;
    await _ref
        .read(downloadManagerProvider)
        .deleteDownloadsForUuids(tracks.map((t) => t.uuidId));
  }
}

/// The queue source of a track tapped in the recents surfaces.
const recentsQueueSource = 'recents';

extension RecentTrackPlay on LibraryActionControls {
  /// A recent track tap: a new single-track queue and one track click.
  Future<PlaybackOutcome> playRecentTrack(TrackUI track) =>
      playFromList([track], 0, source: recentsQueueSource);
}

/// The queue source of a track tapped on the statistics screens.
const listeningStatsQueueSource = 'listening_stats';

extension StatsTrackPlay on LibraryActionControls {
  /// A statistics track tap: a new single-track queue and one track click.
  Future<PlaybackOutcome> playStatsTrack(TrackUI track) =>
      playFromList([track], 0, source: listeningStatsQueueSource);
}

/// Shown when nothing in a collection plays on this device offline (the
/// collection header's disabled note and the menu actions' message).
const nothingPlaysOfflineMessage = 'Nothing here plays offline.';

/// The one outcome to user-facing text mapping for playback requests; null
/// when there is nothing to say.
String? playbackOutcomeMessage(PlaybackOutcome outcome) => switch (outcome) {
      Accepted() || Superseded() => null,
      RejectedEmpty() => 'Nothing to play here right now.',
      RejectedUnplayableOffline() => nothingPlaysOfflineMessage,
      Failed() => "Couldn't start playback.",
    };

/// Shown when a library menu's Download did not go through (U30-A-01). It
/// fails only on a local fault of unknown cause, which a retry is not known
/// to fix, so no "Try again." (sign-off s7-app-texts).
String downloadFailedMessage(LibraryScope scope) => scope is TrackScope
    ? "Couldn't queue the download."
    : "Couldn't queue the downloads.";

/// Shown when no re-download could be queued: a damaged or out-of-date
/// download's re-download, or the library menu's damaged re-download.
const redownloadFailedMessage = "Couldn't queue re-download.";

/// The message after a damaged or out-of-date re-download: null when every
/// track was queued, [redownloadFailedMessage] when none was, else how many
/// of them could not be.
String? redownloadResultMessage(({int failed, int total}) r) =>
    r.failed == 0
        ? null
        : r.failed == r.total
            ? redownloadFailedMessage
            : "Couldn't queue re-download for ${r.failed} of ${r.total} "
                'tracks.';

/// Shown when a library menu's Delete download(s) did not finish
/// (U30-A-01).
String deleteDownloadsFailedMessage(LibraryScope scope) => scope is TrackScope
    ? "Couldn't delete the download."
    : "Couldn't delete the downloads.";

/// Awaits a library menu's Download or Delete: null when it went through
/// (downloads show their progress elsewhere), else [failure].
Future<String?> downloadActionMessage(
  Future<void> Function() action,
  String failure,
) async {
  try {
    await action();
    return null;
  } catch (_) {
    return failure;
  }
}
