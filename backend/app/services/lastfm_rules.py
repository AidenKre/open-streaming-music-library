"""The pure Last.fm rules for a listen and a track's fields (spec §7.7 steps 3
and 5): whether a listen counts, and what is sent for a track. No database and
no state, so the scrobble outbox and Now Playing share them without importing
the database (``lastfm_outbox.py`` re-exports the public names)."""

import unicodedata

MAX_FIELD_LENGTH = 1024


def long_enough_to_scrobble(seconds_played, track_length) -> bool:
    """Last.fm's rule (spec §7.7 step 3); an unknown seconds_played never qualifies."""
    if seconds_played is None:
        return False
    if track_length is None:
        return seconds_played >= 240
    return track_length > 30 and seconds_played >= min(track_length / 2, 240)


def _trim(value) -> str:
    return value.strip() if value else ""


def _is_various(value: str) -> bool:
    lowered = value.lower()
    return lowered == "va" or "various artists" in lowered


def _clean(value: str) -> bool:
    return len(value) <= MAX_FIELD_LENGTH and not any(
        unicodedata.category(char) in ("Cc", "Cs") for char in value
    )


def lastfm_track_fields(fields) -> dict | None:
    """The sendable artist/track/album/albumArtist of a track (spec §7.7 step 5), or None.

    Nothing is derived from a filename or replaced by a placeholder."""
    title = _trim(fields["title"])
    artist = _trim(fields["artist"])
    album = _trim(fields["album"])
    album_artist = _trim(fields["album_artist"])
    if not artist and album_artist and not _is_various(album_artist):
        artist = album_artist
    if not artist or not title:
        return None
    result = {"artist": artist, "track": title}
    if album:
        result["album"] = album
    if album_artist.lower() == "va":
        album_artist = ""
    elif "various artists" in album_artist.lower():
        album_artist = "Various Artists"
    if album_artist and album_artist != artist:
        result["albumArtist"] = album_artist
    if not all(_clean(value) for value in result.values()):
        return None
    return result
