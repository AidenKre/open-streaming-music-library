"""Phase M.0c (SC-28 rule 2, spec §4.6 "Table registry test", review M-U07).

Every table in ``sqlite_master`` is classified; an unclassified table fails.
"Owned through" entries are verified against ``PRAGMA foreign_key_list`` or
their named link. The registry yields the children-first delete order that
hard delete (M.2b) follows.
"""

import sqlite3

import pytest

from app.database import table_registry as registry
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def conn():
    connection = sqlite3.connect(":memory:")
    connection.executescript(INIT_SQL.read_text())
    try:
        yield connection
    finally:
        connection.close()


def _tables(conn):
    return {
        row[0]
        for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }


def test_the_fresh_schema_verifies_cleanly(conn):
    assert registry.verify(conn) == []


def test_every_table_in_the_schema_has_a_class(conn):
    for table in _tables(conn):
        assert registry.classify(table) is not None, table


@pytest.mark.parametrize(
    "table, kind",
    [
        ("users", registry.OWNER_TABLE),
        ("user_settings", registry.OWNED_BY_USER_ID),
        ("auth_sessions", registry.OWNED_BY_USER_ID),
        # Decision O5 (DEV-M-05): the CLI delete's art capture is owned by user_id.
        ("user_delete_art_capture", registry.OWNED_BY_USER_ID),
        ("artists", registry.OWNED),
        ("tracks", registry.OWNED),
        ("track_tombstones", registry.OWNED),
        ("history_events", registry.OWNED),
        ("conversion_jobs", registry.OWNED),
        ("edit_journal", registry.OWNED),
        ("trackmetadata", registry.OWNED_THROUGH),
        ("albums", registry.OWNED_THROUGH),
        ("history_hook_failures", registry.OWNED_THROUGH),
        # Phase 6.5 (plan D15, DEV-6.5-02): per-track identity rows.
        ("track_audio_identity", registry.OWNED_THROUGH),
        ("track_audio_fingerprint", registry.OWNED_THROUGH),
        # Plan O2: the candidate store carries its own owner.
        ("track_duplicate_candidates", registry.OWNED),
        # Phase 7A.1c (decision O2): upload rows carry their own owner, because
        # client uuids are unique per owner only.
        ("upload_batches", registry.OWNED),
        ("upload_items", registry.OWNED),
        ("upload_item_audio_identity", registry.OWNED),
        # SC-16c receipts (keyed by owner, O2) and the SC-16g ledger.
        ("operation_receipts", registry.OWNED),
        ("storage_reservations", registry.OWNED),
        ("upload_item_acknowledgements", registry.OWNED),
        ("upload_commit_journal", registry.OWNED),
        # Phase 8A.2a: deletion jobs are keyed (owner_id, operation_uuid) like their receipt.
        ("deletion_jobs", registry.OWNED),
        ("deletion_job_items", registry.OWNED),
        ("deletion_journal", registry.OWNED),
        # Phase 9D.1b: one Last.fm connection per user (spec §7.3).
        ("lastfm_connections", registry.OWNED),
        ("scrobble_outbox", registry.OWNED),
        ("fts_tracks", registry.OWNED_THROUGH),
        ("fts_artists", registry.OWNED_THROUGH),
        ("fts_albums", registry.OWNED_THROUGH),
        ("fts_tracks_data", registry.INTERNAL),
        ("fts_albums_config", registry.INTERNAL),
        ("fts_artists_docsize", registry.INTERNAL),
        ("fts_tracks_idx", registry.INTERNAL),
        ("sqlite_sequence", registry.INTERNAL),
        ("app_settings", registry.SERVER_WIDE),
        ("revision_counter", registry.SERVER_WIDE),
        ("cover_arts", registry.SERVER_WIDE),
    ],
)
def test_the_spec_classification(table, kind):
    assert registry.classify(table).kind == kind


@pytest.mark.parametrize(
    "child, parent", [
        ("trackmetadata", "tracks"),
        ("albums", "artists"),
        ("history_hook_failures", "history_events"),
        ("track_audio_identity", "tracks"),
        ("track_audio_fingerprint", "track_audio_identity"),
        ("fts_tracks", "tracks"),
        ("fts_artists", "artists"),
        ("fts_albums", "albums"),
    ],
)
def test_owned_through_entries_name_their_parent(child, parent):
    assert registry.classify(child).parent == parent


def test_an_unclassified_table_fails_verification(conn):
    conn.execute("CREATE TABLE playlists (id INTEGER PRIMARY KEY, owner_id INTEGER)")

    problems = registry.verify(conn)

    assert any("playlists" in p for p in problems)


def test_a_new_shadow_looking_table_is_not_silently_internal(conn):
    # Only the shadow tables of the registered FTS tables are internal.
    conn.execute("CREATE VIRTUAL TABLE fts_playlists USING fts5(name, content='')")

    problems = registry.verify(conn)

    assert any("fts_playlists" in p for p in problems)


def test_an_owned_through_foreign_key_that_is_gone_fails(conn):
    # Rebuild albums without its artist FK: the registry's claim is now false.
    conn.executescript(
        """
        PRAGMA foreign_keys=OFF;
        DROP INDEX idx_albums_regular; DROP INDEX idx_albums_singles;
        DROP INDEX idx_albums_name_lower; DROP INDEX idx_albums_artist_id;
        ALTER TABLE albums RENAME TO albums_old;
        CREATE TABLE albums (id INTEGER PRIMARY KEY, name TEXT, artist_id INTEGER NOT NULL);
        DROP TABLE albums_old;
        """
    )

    problems = registry.verify(conn)

    assert any("albums" in p and "artists" in p for p in problems)


def test_a_named_link_column_that_is_gone_fails(conn):
    conn.executescript(
        """
        DROP TABLE history_hook_failures;
        CREATE TABLE history_hook_failures (id INTEGER PRIMARY KEY, subscriber TEXT);
        """
    )

    problems = registry.verify(conn)

    assert any("history_hook_failures" in p for p in problems)


def test_an_owned_table_without_an_owner_fk_to_users_fails(conn):
    conn.executescript(
        """
        DROP TABLE edit_journal;
        CREATE TABLE edit_journal (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL);
        """
    )

    problems = registry.verify(conn)

    assert any("edit_journal" in p for p in problems)


def test_a_user_id_table_without_its_fk_to_users_fails(conn):
    conn.executescript(
        """
        DROP TABLE user_delete_art_capture;
        CREATE TABLE user_delete_art_capture (user_id INTEGER NOT NULL, cover_art_id INTEGER);
        """
    )

    problems = registry.verify(conn)

    assert any("user_delete_art_capture" in p for p in problems)


# Review r1 #3: server-wide tables must stay free of per-user links.
def test_a_server_wide_table_with_an_owner_column_fails(conn):
    conn.execute("ALTER TABLE app_settings ADD COLUMN owner_id INTEGER")

    problems = registry.verify(conn)

    assert any("app_settings" in p for p in problems)


def test_a_server_wide_table_with_a_foreign_key_to_a_per_user_table_fails(conn):
    conn.executescript(
        """
        DROP TABLE revision_counter;
        CREATE TABLE revision_counter (id INTEGER PRIMARY KEY, value INTEGER,
            track_id INTEGER REFERENCES tracks(id));
        """
    )

    problems = registry.verify(conn)

    assert any("revision_counter" in p for p in problems)


# ── delete order ────────────────────────────────────────────────────────────

def _fk_edges(conn):
    """(child, parent) for every foreign key between tables in the delete order."""
    edges = set()
    for table in _tables(conn):
        for row in conn.execute(f"PRAGMA foreign_key_list('{table}')"):
            edges.add((table, row[2]))
    return edges


def test_the_delete_order_is_children_first_and_ends_with_users(conn):
    order = registry.delete_order()

    # Children first; among tables whose children are all gone, by name.
    assert order == [
        "auth_sessions",
        "conversion_jobs",
        "deletion_journal",
        "deletion_job_items",
        "deletion_jobs",
        "edit_journal",
        "fts_albums",
        "fts_artists",
        "fts_tracks",
        "history_hook_failures",
        "history_events",
        "lastfm_connections",
        "scrobble_outbox",
        "storage_reservations",
        "track_audio_fingerprint",
        "track_audio_identity",
        "track_duplicate_candidates",
        "track_tombstones",
        "trackmetadata",
        "albums",
        "artists",
        "tracks",
        "upload_commit_journal",
        "operation_receipts",
        "upload_item_acknowledgements",
        "upload_item_audio_identity",
        "upload_items",
        "upload_batches",
        "user_delete_art_capture",
        "user_settings",
        "users",
    ]


def test_every_foreign_key_child_is_deleted_before_its_parent(conn):
    order = registry.delete_order()
    position = {table: i for i, table in enumerate(order)}

    for child, parent in _fk_edges(conn):
        if child == parent:
            continue  # a self-reference (a ZIP child's archive) is one DELETE
        if child in position and parent in position:
            assert position[child] < position[parent], (child, parent)


def test_the_delete_order_covers_exactly_the_per_user_tables(conn):
    per_user = {
        table for table in _tables(conn)
        if registry.classify(table) is not None
        and registry.classify(table).kind in (
            registry.OWNER_TABLE, registry.OWNED_BY_USER_ID,
            registry.OWNED, registry.OWNED_THROUGH,
        )
    }

    assert set(registry.delete_order()) == per_user
    assert "cover_arts" not in registry.delete_order()  # shared, server-wide


def test_rows_deleted_in_that_order_never_violate_a_foreign_key(conn):
    # One user's row in every FK-linked table; deleting in registry order
    # with foreign_keys=ON must succeed.
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(
        """
        INSERT INTO users (id, username, username_key, password_hash, library_folder, created_at)
            VALUES (1, 'sam', 'sam', 'h', 'sam', 0);
        INSERT INTO user_settings VALUES (1, 'k', 'v');
        INSERT INTO auth_sessions VALUES ('t', 'm', 1, 0, NULL);
        INSERT INTO user_delete_art_capture VALUES (1, 5);
        INSERT INTO artists (id, name, owner_id) VALUES (1, 'A', 1);
        INSERT INTO albums (id, name, artist_id) VALUES (1, 'B', 1);
        INSERT INTO tracks (id, uuid_id, file_path, file_path_fold, file_folder_fold, owner_id)
            VALUES (1, 'u', '/m/sam/a', '/m/sam/a', '/m/sam', 1);
        INSERT INTO trackmetadata (track_id, uuid_id, artist_id, album_id, has_album_art)
            VALUES (1, 'u', 1, 1, 0);
        INSERT INTO track_tombstones VALUES ('v', 0, 1, 1);
        INSERT INTO edit_journal (intent, uuid_id, created_at, owner_id) VALUES ('x', 'u', 0, 1);
        INSERT INTO conversion_jobs (uuid_id, target_codec, target_container, owner_id)
            VALUES ('u', 'aac', 'm4a', 1);
        INSERT INTO history_events VALUES ('e', 1, 'listen', 'track', 'u', 0, 1, 2, 0, 1);
        INSERT INTO history_hook_failures (subscriber, event_uuid, error, created_at)
            VALUES ('s', 'e', 'x', 0);
        INSERT INTO track_audio_identity (uuid_id, exact_state, fp_state)
            VALUES ('u', 'pending', 'pending');
        INSERT INTO track_audio_fingerprint VALUES ('u', 'fpcalc', 'chromaprint-2', 1.5, 1, X'00');
        INSERT INTO tracks (id, uuid_id, file_path, file_path_fold, file_folder_fold, owner_id)
            VALUES (2, 'w', '/m/sam/b', '/m/sam/b', '/m/sam', 1);
        INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank,
            sort_score, matcher_version, detected_at) VALUES (1, 'u', 'w', 'exact', 0, 1.0, 'm', 0);
        INSERT INTO upload_batches (owner_id, batch_uuid, created_at, updated_at)
            VALUES (1, 'b', 0, 0);
        INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, kind, filename,
            selection_index, expected_bytes, expected_sha256, state, created_at, updated_at,
            progress_at) VALUES (1, 'z', 'b', 'zip', 'a.zip', 0, 1, '0000000000000000000000000000000000000000000000000000000000000000', 'expanded', 0, 0, 0);
        INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, parent_item_uuid,
            filename, selection_index, member_order_key, state, created_at, updated_at,
            progress_at) VALUES (1, 'c', 'b', 'z', 'a.flac', 0, 'a.flac', 'validating', 0, 0, 0);
        INSERT INTO upload_item_audio_identity (owner_id, item_uuid, exact_state, computed_at,
            fp_state) VALUES (1, 'c', 'unsupported', 0, 'unavailable');
        INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at)
            VALUES (1, 'op', 'upload_commit', 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', 0);
        INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, created_at)
            VALUES (1, 'upload_receive', 'c', 5, 0);
        INSERT INTO upload_item_acknowledgements VALUES (1, 'c', 'library_track', 'u');
        INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state,
            base_review_version, reserved_track_uuid, edits, write_tags,
            acknowledged_duplicates, source_path, created_at, updated_at)
            VALUES (1, 'op', 'c', 'committing', 0, 'n', '{}', 0, '{}', '/s', 0, 0);
        INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at)
            VALUES (1, 'del', 'track_deletion', 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd', 0);
        INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status)
            VALUES (1, 'del', 0, 'accepted');
        INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id, position, base_revision,
            status) VALUES (1, 'del', 'w', 0, 1, 'running');
        INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id, original_path,
            quarantine_path, base_revision, src_dev, src_ino, src_size, master_missing, stage,
            created_at, updated_at) VALUES (1, 'del', 'w', '/m/sam/b', '/m/.deleting/1/del/w', 1,
            1, 2, 3, 0, 'intent', 0, 0);
        INSERT INTO lastfm_connections (owner_id, connection_id, account_name, session_key_enc,
            opted_in, created_at, updated_at) VALUES (1, 'c', 'rj', 'enc', 1, 0, 0);
        INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, created_at)
            VALUES ('e', 1, '{}', 0, 0);
        """
    )

    for table in registry.delete_order():
        if table.startswith("fts_"):
            continue  # contentless FTS rows are deleted by derivation (M.2b)
        conn.execute(f'DELETE FROM "{table}"')

    for table in registry.delete_order():
        if not table.startswith("fts_"):
            assert conn.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0] == 0
