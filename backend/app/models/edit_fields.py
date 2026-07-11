"""The single source of truth for user-editable track tag fields.

One spec per field drives everything that must stay in lockstep:
``EDITABLE_METADATA_COLUMNS`` (the DB spine's edit allowlist),
``EDITABLE_FIELD_META`` / ``GET /app/info`` (the advertised schema the client
form renders from), the ffmpeg tag-key mapping in the master-file writer, and
an import-time assert against ``TrackPatchRequest``'s declared fields.
Adding an editable field in a later phase means adding one spec here (plus a
typed field on ``TrackPatchRequest``) — a lagging copy now fails at import,
not with a request-time KeyError.

Deliberately a leaf module (stdlib imports only) so the database layer,
services, and API models can all import it without cycles.
"""

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class EditFieldSpec:
    key: str
    """DB column name == PATCH body key == /app/info field key."""

    label: str
    """Human-readable label the client form displays."""

    value_type: str
    """Open/extensible set consumed by the client's schema-driven form
    (text/int/year today; e.g. a future ``image`` slots in without refactor)."""

    ffmpeg_key: Optional[str] = None
    """The file tag name when it differs from the column (``None`` = same).
    ``year``/``date`` are special-cased by the tag writer (both target the
    file's single ``date`` tag), not here."""


# In display order — /app/info advertises fields in this order.
EDIT_FIELD_SPECS: tuple[EditFieldSpec, ...] = (
    EditFieldSpec("title", "Title", "text"),
    EditFieldSpec("artist", "Artist", "text"),
    EditFieldSpec("album", "Album", "text"),
    EditFieldSpec("album_artist", "Album Artist", "text"),
    EditFieldSpec("year", "Year", "year"),
    EditFieldSpec("date", "Date", "text"),
    EditFieldSpec("genre", "Genre", "text"),
    EditFieldSpec("track_number", "Track Number", "int", ffmpeg_key="track"),
    EditFieldSpec("disc_number", "Disc Number", "int", ffmpeg_key="disc"),
)
