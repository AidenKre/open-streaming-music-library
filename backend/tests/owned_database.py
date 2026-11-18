"""``OwnedTestDatabase``: the direct-database tests' owner adapter (spec §4.6).

Phase M makes every owned ``Database`` method take a required keyword-only
``owner_id``. The hundreds of existing direct-database call sites predate
owners, so the test helpers build an ``OwnedTestDatabase`` instead: it seeds
one test user on ``initialize()`` and passes that user's id to every
owner-requiring method the caller did not give an owner. An explicit
``owner_id`` always wins, so multi-user tests can use the same instance.

Production code never uses this class. ``OWNER_METHODS`` grows as later
pieces make more methods owner-scoped.
"""

import functools
import sqlite3

from app.database.database import Database

TEST_OWNER_USERNAME = "owner"

# Every Database method that requires ``owner_id``.
OWNER_METHODS: tuple[str, ...] = (
    "add_track",
    "insert_conversion_job",
    "insert_journal_entry",
    "insert_history_events",
    "get_tracks",
    "get_tracks_count",
    "get_track_by_uuid",
    "apply_track_metadata_edit",
    "get_track_file_path",
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
    "settle_swapped_conversion_job",
    "bump_track_revision",
    "complete_conversion_job",
    "list_journal_entries",
    "has_journal_entry_for_uuid",
    "delete_journal_entry",
    "get_tracks_missing_cover_art",
    "update_track_cover_art_id",
    "get_user_setting",
    "set_user_setting",
    "filter_owned_track_uuids",
    "owns_cover_art",
    "mark_audio_identity_stale",
    "write_conversion_identity",
    "get_audio_identity",
    "set_duplicate_candidate_status",
    "get_identity_coverage_summary",
)


class OwnedTestDatabase(Database):
    # None until initialize() seeds the owner (a few tests never initialize).
    owner_id: int | None = None

    def initialize(self) -> bool:
        result = super().initialize()
        self.owner_id = self._seed_test_owner()
        return result

    def _seed_test_owner(self) -> int:
        conn = sqlite3.connect(self.context.database_path)
        try:
            conn.execute(
                "INSERT OR IGNORE INTO users (username, username_key, password_hash, "
                "library_folder, created_at) VALUES (?, ?, 'unused', ?, 0)",
                (TEST_OWNER_USERNAME, TEST_OWNER_USERNAME, TEST_OWNER_USERNAME),
            )
            conn.commit()
            return conn.execute(
                "SELECT id FROM users WHERE username_key = ?", (TEST_OWNER_USERNAME,)
            ).fetchone()[0]
        finally:
            conn.close()


def add_test_user(db: Database, username: str) -> int:
    """Create another user row (two-user tests) and return its id."""
    conn = sqlite3.connect(db.context.database_path)
    try:
        uid = conn.execute(
            "INSERT INTO users (username, username_key, password_hash, "
            "library_folder, created_at) VALUES (?, ?, 'unused', ?, 0)",
            (username, username.lower(), username.lower()),
        ).lastrowid
        conn.commit()
        return uid
    finally:
        conn.close()


def _with_default_owner(name: str):
    method = getattr(Database, name)

    @functools.wraps(method)
    def wrapper(self, *args, **kwargs):
        kwargs.setdefault("owner_id", self.owner_id)
        return method(self, *args, **kwargs)

    return wrapper


for _name in OWNER_METHODS:
    setattr(OwnedTestDatabase, _name, _with_default_owner(_name))
