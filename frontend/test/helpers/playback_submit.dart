import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/database/database.dart' show OrderParameter;
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/playback_requests.dart';

/// Test shorthands for the request shapes the removed QueuePlayer (then AudioCoordinator) entry points
/// built (D34). Each submits through [PlaybackRequests] and rethrows a
/// Failed outcome, as those entry points did.
Future<void> _submit(ProviderContainer c, PlaybackRequest request) async {
  final outcome = await c.read(playbackRequestsProvider).submit(request);
  if (outcome is Failed) throw outcome.error;
}

Future<void> play(ProviderContainer c, TrackUI track) =>
    _submit(c, PlayList([track.uuidId], 0, const ListSource('single')));

Future<void> playFromQueue(
  ProviderContainer c, {
  required TrackUI track,
  required String sourceType,
  int? artistId,
  int? albumId,
  List<OrderParameter> orderParams = const [],
  bool downloadedOnly = false,
}) =>
    _submit(
        c,
        PlayQuery(
          source:
              BrowseSource(sourceType, artistId: artistId, albumId: albumId),
          currentUuid: track.uuidId,
          order: orderParams,
          downloadedOnly: downloadedOnly,
        ));

Future<void> playFromTrackList(
  ProviderContainer c,
  List<String> uuids,
  TrackUI startTrack, {
  required String sourceType,
}) =>
    _submit(
        c,
        PlayList(uuids, max(0, uuids.indexOf(startTrack.uuidId)),
            ListSource(sourceType)));

Future<void> playNext(ProviderContainer c, List<TrackUI> tracks) => _submit(
    c, Enqueue([for (final t in tracks) t.uuidId], EnqueuePosition.next));

Future<void> addToQueue(ProviderContainer c, List<TrackUI> tracks) => _submit(
    c, Enqueue([for (final t in tracks) t.uuidId], EnqueuePosition.end));
