import 'package:frontend/providers/providers.dart';

/// Whether the sync run that [finished] describes touched any of [uuids]:
/// today the only thing a sync publishes about tracks is
/// `deletedTrackUuids`, so a no-op sync touches nothing (U33-B-01).
///
/// The one place to widen when the sync also publishes upserts.
bool syncTouched(TrackSyncState finished, Iterable<String> uuids) =>
    uuids.any(finished.deletedTrackUuids.contains);
