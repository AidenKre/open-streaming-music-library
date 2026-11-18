import 'package:frontend/providers/providers.dart';

/// Whether the sync run that [finished] describes touched any of [uuids]:
/// today the only thing a sync publishes about tracks is
/// `deletedTrackUuids`, so a sync that changed nothing (every resume, every
/// window refocus) touches nothing and leaves an open review as it was.
///
/// The one place to widen when the sync also publishes upserts.
bool syncTouched(TrackSyncState finished, Iterable<String> uuids) =>
    uuids.any(finished.deletedTrackUuids.contains);
