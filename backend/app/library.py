"""Owner binding: a Library exposes owned Database methods with owner_id fixed."""

import functools
import threading
from pathlib import Path, PurePath, PureWindowsPath

from fastapi import Request

from app.auth.principal import auth_error, current_principal
from app.core.api_errors import api_error
from app.core.operator_log import operator_logger
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
        "undo_inplace_conversion",
        "settle_swapped_conversion_job",
        "refresh_track_audio_properties",
        "list_journal_entries",
        "has_journal_entry_for_uuid",
        "track_path_in_use",
        "track_identities_in_folder",
        "live_track_paths",
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
        "release_removed_upload_source",
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

    ``tests/test_ownership_inventory.py`` holds the same list from the other
    side: every public Database method classified, and the owned methods a
    Library does not offer, each with its reason.
    """

    def __init__(self, db, owner_id, root=None):
        if not isinstance(owner_id, int) or isinstance(owner_id, bool):
            raise TypeError(f"owner_id must be an int, got {owner_id!r}")
        self._db = db
        self.owner_id = owner_id
        self.root = root

    @property
    def unbound_database(self):
        """The Database itself, not bound to this owner: every owner's rows are
        within reach of it. Only for the file operations that must look beyond
        the owner (is a path another track's of any owner; the durable point;
        the recovery of a journal row, which names the row's own owner). Every
        use is listed in ``tests/test_ownership_inventory.py``; no route uses it.
        """
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


def is_plain_folder_name(folder) -> bool:
    """Whether a stored library folder is one plain path component: a
    non-empty string, not ``.`` or ``..``, with no separator, never absolute."""
    return not (
        not isinstance(folder, str)
        or folder in ("", ".", "..")
        or "/" in folder
        or "\\" in folder
        or PurePath(folder).is_absolute()
        or PureWindowsPath(folder).is_absolute()
    )


def library_root(music_library_dir, user) -> Path:
    """The user's library root: music_library_dir / user["library_folder"]."""
    folder = user["library_folder"]
    if not is_plain_folder_name(folder):
        raise PathEscapesRoot(f"library_folder is not a plain component: {folder!r}")
    root = Path(music_library_dir) / folder
    assert_within(root, music_library_dir)
    return root


def current_library(request: Request) -> Library:
    principal = current_principal(request)
    folder = (request.scope.get("state") or {}).get("library_folder")
    if folder is None:
        raise auth_error("auth_required")
    try:
        root = library_root(request.app.state.settings.music_library_dir, {"library_folder": folder})
    except PathEscapesRoot:
        _report_unusable_folder(request.app.state, principal.user_id, folder)
        raise api_error(
            503, "library_folder_unusable",
            "This account's music folder on the server is not usable. The server's admin needs"
            " to fix it.",
            retryable=False,
        ) from None
    return Library(request.app.state.database, principal.user_id, root=root)


# Guards the per-server set of users whose unusable library folder was
# already reported: every request of theirs refuses, the operator needs to
# read it once per server start.
_reported_lock = threading.Lock()


def _report_unusable_folder(state, user_id: int, folder) -> None:
    with _reported_lock:
        reported = getattr(state, "reported_unusable_folders", None)
        if reported is None:
            reported = state.reported_unusable_folders = set()
        if user_id in reported:
            return
        reported.add(user_id)
    # A stored name that is not a plain folder name could be an absolute path.
    shown = folder if is_plain_folder_name(folder) else "(not a plain folder name)"
    operator_logger.warning(
        "The music library folder of user %s (%s in the music folder) is not usable: it is not"
        " a plain folder name or it leads outside the music folder. That user's library answers"
        " 503 until it is fixed.",
        user_id, shown,
    )
