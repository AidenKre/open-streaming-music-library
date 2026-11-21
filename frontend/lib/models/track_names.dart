/// Shown in place of a track's name when this device knows none. A track's
/// internal ID is never shown to a person (owner, 2026-11-17).
const unknownTrackName = 'Unknown track';

/// A track's title as a person reads it: [unknownTrackName] when this device
/// has no title (null or empty), never the track's ID.
String trackTitleOrUnknown(String? title) =>
    title == null || title.isEmpty ? unknownTrackName : title;

/// Shown in place of an artist's name when it is not known.
const unknownArtistName = 'Unknown artist';
