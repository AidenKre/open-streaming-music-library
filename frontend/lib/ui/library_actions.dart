import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/history_intent.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/collection_ordering.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/settings_service.dart';

/// Every library action a surface offers on a [LibraryScope] (SC-06): the
/// one controller behind TrackTile, LibraryCard and their pages' row taps.
///
/// Stateless and navigation-free (navigation is the view's, via
/// `library_routes.dart`; busy state belongs to the page controller that
/// shows it). Each method resolves membership through the model
/// (`BrowseRepository.getTracksForScope`, passing only the observed offline
/// state) and submits typed requests to `PlaybackRequests.submit`, whose
/// outcome it returns.
abstract interface class LibraryActionControls {
  Future<PlaybackOutcome> playNext(LibraryScope scope);

  Future<PlaybackOutcome> addToQueue(LibraryScope scope);

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

  Future<List<TrackUI>> _members(LibraryScope scope) => _ref
      .read(browseRepositoryProvider)
      .getTracksForScope(scope, offline: _ref.read(offlineModeProvider));

  @override
  Future<PlaybackOutcome> playNext(LibraryScope scope) async {
    final tracks = await _members(scope);
    if (!_ref.mounted || tracks.isEmpty) return const RejectedEmpty();
    return _ref.read(playbackRequestsProvider).submit(Enqueue(
          [for (final t in tracks) t.uuidId],
          EnqueuePosition.next,
          intent: HistoryIntent.forScope(scope),
        ));
  }

  @override
  Future<PlaybackOutcome> addToQueue(LibraryScope scope) async {
    final tracks = await _members(scope);
    if (!_ref.mounted || tracks.isEmpty) return const RejectedEmpty();
    return _ref.read(playbackRequestsProvider).submit(Enqueue(
          [for (final t in tracks) t.uuidId],
          EnqueuePosition.end,
          intent: HistoryIntent.forScope(scope),
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
          intent: HistoryIntent.forScope(TrackScope(tracks[startIndex])),
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
          intent: HistoryIntent.forScope(TrackScope(track)),
        ));
  }

  @override
  Future<void> download(LibraryScope scope) async {
    final tracks = await _members(scope);
    if (!_ref.mounted || tracks.isEmpty) return;
    await _ref
        .read(downloadManagerProvider)
        .enqueueTracks(tracks, quality: _ref.read(downloadQualityProvider));
  }

  @override
  Future<void> downloadAtQuality(LibraryScope scope, String quality) async {
    final tracks = await _members(scope);
    if (!_ref.mounted || tracks.isEmpty) return;
    await _ref
        .read(downloadManagerProvider)
        .enqueueTracksAtQuality(tracks, quality: quality);
  }

  @override
  Future<void> deleteDownloads(LibraryScope scope) async {
    final tracks = await _members(scope);
    if (!_ref.mounted || tracks.isEmpty) return;
    await _ref
        .read(downloadManagerProvider)
        .deleteDownloadsForUuids(tracks.map((t) => t.uuidId));
  }
}
