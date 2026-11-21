from pathlib import Path

from app.core.owner import ANY_OWNER
from app.database.browse import (
    AlbumOrderParameter,
    AlbumRowFilterParameter,
    ALLOWED_METADATA_COLUMNS,
    ArtistOrderParameter,
    ArtistRowFilterParameter,
    BrowsePart,
    OrderParameter,
    prepare_fts_query,
    RowFilterParameter,
    SearchEntityType,
    SearchParameter,
    SearchResults,
)
from app.database.core import (
    CoverArtGone,
    DatabaseContext,
    effective_artist,
    _fold_path,
    OwnerMismatch,
    STALE_REASONS,
    track_path_values,
    TrackAlreadyDeleted,
    TrackNotFound,
    TrackPathTaken,
)
from app.database.cover_art import (
    CoverArtPart,
)
from app.database.deletion import (
    DeletionPart,
    DeletionRecheckFailed,
    TrackPendingDeletion,
)
from app.database.history import (
    HistoryEventConflict,
    HistoryPart,
)
from app.database.identity import (
    IdentityPart,
)
from app.database.lastfm import (
    LastfmPart,
    LastfmPurgeBusy,
    LastfmPurgeIncomplete,
)
from app.database.schema import (
    DatabaseMissing,
    DatabaseUnreadable,
    SchemaPart,
    SchemaVersionRefused,
)
from app.database.storage import (
    StoragePart,
    StorageTotals,
)
from app.database.tracks import (
    ConversionJobActive,
    ConversionJobNotRunning,
    EDITABLE_METADATA_COLUMNS,
    EmptyTrackEdit,
    normalize_edit_fields,
    RevisionConflict,
    TracksPart,
)
from app.database.uploads import (
    UploadItemsInUse,
    UploadsPart,
)
from app.database.users import (
    UsernameTaken,
    UsersPart,
)


class Database(
    SchemaPart,
    UsersPart,
    LastfmPart,
    StoragePart,
    HistoryPart,
    UploadsPart,
    IdentityPart,
    CoverArtPart,
    TracksPart,
    DeletionPart,
    BrowsePart,
):
    """The server's database: one class, composed from one part per domain.

    A method is defined in exactly one place: in its domain's part
    (``app/database/<domain>.py``) or in ``DatabaseCore``
    (``app/database/core.py``, what several domains share)."""


def server_database(app_data_dir: Path) -> Database:
    """The server's database under ``app_data_dir`` (creates nothing)."""
    return Database(
        DatabaseContext(
            database_path=Path(app_data_dir) / "database" / "database.db",
            init_sql_path=Path(__file__).parent / "init.sql",
        )
    )
