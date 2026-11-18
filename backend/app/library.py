"""Owner binding: a Library exposes owned Database methods with owner_id fixed."""

import functools
from pathlib import Path, PurePath, PureWindowsPath

from fastapi import Request

from app.auth.principal import auth_error, current_principal
from app.services.path_sanitize import PathEscapesRoot, assert_within

OWNED_METHODS = frozenset(
    {
        "add_track",
        "mark_audio_identity_stale",
        "write_conversion_identity",
        "get_audio_identity",
        "set_duplicate_candidate_status",
        "get_identity_coverage_summary",
        # 8A.4: the duplicates API's reads.
        "list_duplicate_candidates",
        "count_duplicate_candidates",
        "insert_conversion_job",
        "insert_journal_entry",
        "insert_history_events",
        "seed_user_setting",
        "get_tracks",
        "get_tracks_count",
        "get_track_by_uuid",
        "apply_track_metadata_edit",
        "get_track_file_path",
        # 8A.3a: reader-side pending-deletion predicate.
        "is_pending_deletion",
        "delete_track",
        "get_track_tombstones",
        "get_all_track_uuids",
        "get_changes",
        "get_artists",
        "get_artists_count",
        "get_albums",
        "get_albums_count",
        "get_search_results",
        "get_history_changes",
        "get_conversion_job",
        "list_conversion_jobs_with_status",
        "list_conversion_jobs",
        "mark_conversion_job_running",
        "mark_conversion_job_failed",
        "mark_conversion_job_cancelled",
        "complete_conversion_job",
        "settle_swapped_conversion_job",
        "bump_track_revision",
        "refresh_track_audio_properties",
        "list_journal_entries",
        "has_journal_entry_for_uuid",
        "track_path_in_use",
        "track_identities_in_folder",
        "delete_journal_entry",
        "get_tracks_missing_cover_art",
        "update_track_cover_art_id",
        "filter_owned_track_uuids",
        "owns_cover_art",
        "get_owned_cover_art",
        "get_user_setting",
        "set_user_setting",
        # 7A.1d: the upload API.
        "allocate_upload_batch",
        "get_upload_batch",
        "list_upload_items",
        "get_upload_item",
        "list_upload_batches",
        "transition_upload_item",
        # 7A.2b: the streamed byte receipt.
        "begin_upload_receipt",
        "complete_upload_receipt",
        "end_upload_receipt",
        "record_upload_progress",
        "cancel_upload_item",
        "get_upload_item_source_path",
        "get_upload_preview",
        "retry_upload_item",
        "accept_upload_commit",
        "resolve_upload_duplicate",
        "release_cancelled_upload_source",
        # 8A.2b: the deletion preview, jobs and receipts API (spec §4).
        "get_deletion_preview_facts",
        "create_deletion_job",
        "get_deletion_job",
        "list_deletion_jobs",
        # 9D.1b: the Last.fm connection and outbox rows behind the routes (spec §7.3, §7.4).
        "get_lastfm_connection",
        "store_lastfm_pending_token",
        "clear_lastfm_pending_token",
        "bind_lastfm_session",
        "enable_lastfm_scrobbling",
        "disconnect_lastfm",
        "get_lastfm_outbox_summary",
    }
)


class Library:
    """Allow-list binding of a Database to one owner (SC-28 rule 3).

    Exposes only the owned Database methods named in the allow-list, with
    ``owner_id`` bound; callers cannot pass their own. ``current_library``
    binds the request principal's Library.
    """

    def __init__(self, db, owner_id, root=None):
        if not isinstance(owner_id, int) or isinstance(owner_id, bool):
            raise TypeError(f"owner_id must be an int, got {owner_id!r}")
        self._db = db
        self.owner_id = owner_id
        self.root = root

    @property
    def database(self):
        """The raw Database, for the journal recovery that takes an explicit owner."""
        return self._db

    def __getattr__(self, name):
        if name not in OWNED_METHODS:
            raise AttributeError(name)
        method = getattr(self._db, name)

        @functools.wraps(method)
        def bound(*args, **kwargs):
            if "owner_id" in kwargs:
                raise TypeError("owner_id is bound by the Library and cannot be passed")
            return method(*args, owner_id=self.owner_id, **kwargs)

        return bound


def library_root(music_library_dir, user) -> Path:
    """The user's library root: music_library_dir / user["library_folder"]."""
    folder = user["library_folder"]
    if (
        not isinstance(folder, str)
        or folder in ("", ".", "..")
        or "/" in folder
        or "\\" in folder
        or PurePath(folder).is_absolute()
        or PureWindowsPath(folder).is_absolute()
    ):
        raise PathEscapesRoot(f"library_folder is not a plain component: {folder!r}")
    root = Path(music_library_dir) / folder
    assert_within(root, music_library_dir)
    return root


def current_library(request: Request) -> Library:
    principal = current_principal(request)
    database = request.app.state.database
    user = database.get_user(principal.user_id)
    if user is None:
        raise auth_error("auth_required")
    return Library(
        database,
        principal.user_id,
        root=library_root(request.app.state.settings.music_library_dir, user),
    )
