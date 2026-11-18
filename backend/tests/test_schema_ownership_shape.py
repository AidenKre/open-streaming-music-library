"""The fresh schema's ownership shape, its audio-identity and duplicate
tables, and ``live_tracks``.

Expected values are written out from the spec table, not read from init.sql:
owner columns with no default, per-owner artist uniqueness, AUTOINCREMENT ids
that are never reused, the owner-leading indexes, and the removed
``queue_sync_state`` table and ``tracks.file_hash`` column.
"""

import sqlite3

import pytest

from app.models import Track, TrackMetaData
from tests.schema_fixtures import open_database
from tests.track_paths import PATH_COLUMNS, PATH_MARKS, path_values

OWNED_TABLES = (
    "artists", "tracks", "track_tombstones", "history_events",
    "conversion_jobs", "edit_journal", "track_duplicate_candidates",
)
USER_ID_TABLES = ("user_settings", "auth_sessions", "user_delete_art_capture")
AUTOINCREMENT_TABLES = ("users", "artists", "albums", "tracks", "cover_arts", "conversion_jobs")

# (table, indexed columns in order) that the spec requires.
REQUIRED_INDEXES = {
    ("tracks", ("owner_id", "revision")),
    ("track_tombstones", ("owner_id", "revision")),
    ("history_events", ("owner_id", "revision")),
    ("conversion_jobs", ("owner_id", "id")),
    ("trackmetadata", ("cover_art_id",)),
    ("auth_sessions", ("user_id",)),
}


@pytest.fixture(scope="module")
def conn(tmp_path_factory):
    path = tmp_path_factory.mktemp("v14") / "database.db"
    open_database(path)
    conn = sqlite3.connect(path)
    yield conn
    conn.close()


def _columns(conn, table):
    return {row[1]: row for row in conn.execute(f"PRAGMA table_info({table})")}


def _table_sql(conn, table):
    return conn.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
    ).fetchone()[0]


def _indexes(conn):
    found = set()
    tables = [r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' "
        "AND name NOT LIKE 'fts_%'"
    )]
    for table in tables:
        for _, name, *_ in conn.execute(f"PRAGMA index_list({table})"):
            cols = tuple(r[2] for r in conn.execute(f"PRAGMA index_info({name})"))
            found.add((table, cols))
    return found


@pytest.mark.parametrize("table", OWNED_TABLES)
def test_owned_tables_have_a_required_owner_without_default(conn, table):
    _, _, col_type, notnull, default, _ = _columns(conn, table)["owner_id"]
    assert (col_type.upper(), notnull, default) == ("INTEGER", 1, None)
    fks = [(r[2], r[3], r[4]) for r in conn.execute(f"PRAGMA foreign_key_list({table})")]
    assert ("users", "owner_id", "id") in fks


@pytest.mark.parametrize("table", USER_ID_TABLES)
def test_user_tables_reference_users_without_default(conn, table):
    _, _, col_type, notnull, default, _ = _columns(conn, table)["user_id"]
    assert (col_type.upper(), notnull, default) == ("INTEGER", 1, None)
    fks = [(r[2], r[3], r[4]) for r in conn.execute(f"PRAGMA foreign_key_list({table})")]
    assert fks == [("users", "user_id", "id")]


def test_no_column_anywhere_defaults_an_owner(conn):
    for (table,) in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'").fetchall():
        for name, row in _columns(conn, table).items():
            if name in ("owner_id", "user_id"):
                assert row[4] is None, (table, name)


def test_albums_inherit_ownership_through_a_required_artist(conn):
    assert "owner_id" not in _columns(conn, "albums")
    assert _columns(conn, "albums")["artist_id"][3] == 1


def test_artist_names_are_unique_per_owner(conn):
    uniques = set()
    for _, name, unique, *_ in conn.execute("PRAGMA index_list(artists)"):
        if unique:
            uniques.add(tuple(r[2] for r in conn.execute(f"PRAGMA index_info({name})")))
    assert ("owner_id", "name_lower") in uniques
    assert ("name_lower",) not in uniques


@pytest.mark.parametrize("table", AUTOINCREMENT_TABLES)
def test_ids_are_autoincrement(conn, table):
    assert "AUTOINCREMENT" in " ".join(_table_sql(conn, table).upper().split())


def test_required_indexes_exist(conn):
    assert REQUIRED_INDEXES <= _indexes(conn)


def test_artists_tracks_and_tombstones_carry_only_the_indexes_their_reads_use(conn):
    # Every read of these tables is owner-scoped or by uuid (pre-merge A2-02):
    # an index on revision, deleted_at or name_lower alone is only write cost.
    # The one on the folded path is unique (no two tracks name one file) and is
    # the read behind ``track_path_in_use``; the one on the folded folder is the
    # read behind ``track_identities_in_folder`` (pre-merge PM-BE-PATHKEY).
    found = {(t, cols) for t, cols in _indexes(conn)
             if t in ("artists", "tracks", "track_tombstones")}
    assert found == {
        ("artists", ("owner_id", "name_lower")),
        ("tracks", ("uuid_id",)),
        ("tracks", ("uuid_id", "owner_id")),
        ("tracks", ("owner_id", "revision")),
        ("tracks", ("file_path_fold",)),
        ("tracks", ("file_folder_fold",)),
        ("track_tombstones", ("uuid_id",)),
        ("track_tombstones", ("owner_id", "revision")),
    }


def test_one_master_admin_is_a_partial_unique_index(conn):
    sql = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'one_master_admin'"
    ).fetchone()[0]
    assert " ".join(sql.split()) == (
        "CREATE UNIQUE INDEX one_master_admin ON users(is_master_admin) "
        "WHERE is_master_admin = 1"
    )


def test_removed_schema_is_gone(conn):
    tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    assert "queue_sync_state" not in tables
    assert "file_hash" not in _columns(conn, "tracks")


def test_a_deleted_tracks_id_is_never_reused(tmp_path):
    db = open_database(tmp_path / "database.db")

    def add(title):
        track = Track(
            file_path=tmp_path / f"{title}.flac",
            metadata=TrackMetaData(title=title, artist="A", codec="flac"),
        )
        assert db.add_track(track)
        return track.uuid_id

    def ids():
        conn = sqlite3.connect(db.context.database_path)
        try:
            return [r[0] for r in conn.execute("SELECT id FROM tracks ORDER BY id")]
        finally:
            conn.close()

    add("one")
    newest = add("two")
    [_, highest] = ids()
    assert db.delete_track(newest)
    add("three")
    assert ids()[-1] > highest


def test_user_delete_art_capture_keys_art_per_user_without_an_art_fk(conn):
    """Plan O5 / DEV-M-05: the CLI delete's art capture. No FK to cover_arts,
    so a captured id survives the art row's removal during a resumed delete."""
    cols = _columns(conn, "user_delete_art_capture")
    assert {name: (row[2].upper(), row[3], row[5]) for name, row in cols.items()} == {
        "user_id": ("INTEGER", 1, 1),
        "cover_art_id": ("INTEGER", 1, 2),
    }
    referenced = {r[2] for r in conn.execute("PRAGMA foreign_key_list(user_delete_art_capture)")}
    assert referenced == {"users"}



# --- Phase 6.5A.1: audio identity tables (6.5 spec §6.1) ----------------------------


def _identity_world(conn):
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute(
        "INSERT INTO users (id, username, username_key, password_hash, library_folder, "
        "created_at) VALUES (901, 'fp', 'fp', 'h', 'fp', 0)"
    )
    conn.execute(
        f"INSERT INTO tracks (id, uuid_id, {PATH_COLUMNS}, owner_id) "
        f"VALUES (901, 'fp-u', {PATH_MARKS}, 901)", path_values("/m/a")
    )
    conn.execute(
        "INSERT INTO track_audio_identity (uuid_id, exact_state, fp_state) "
        "VALUES ('fp-u', 'pending', 'current')"
    )


def test_a_fingerprint_needs_a_known_positive_duration(tmp_path):
    """Unknown is never stored as 0: the duration is the tool's measurement."""
    path = tmp_path / "database.db"
    open_database(path)
    conn = sqlite3.connect(path)
    try:
        _identity_world(conn)
        for bad in (0.0, -1.0, None):
            with pytest.raises(sqlite3.IntegrityError):
                conn.execute(
                    "INSERT INTO track_audio_fingerprint VALUES "
                    "('fp-u', 'fpcalc', 'chromaprint-2', ?, 1, X'00')",
                    (bad,),
                )
        conn.execute(
            "INSERT INTO track_audio_fingerprint VALUES "
            "('fp-u', 'fpcalc', 'chromaprint-2', 30.5, 1, X'00')"
        )
    finally:
        conn.close()


def test_a_fingerprint_goes_with_its_track(tmp_path):
    path = tmp_path / "database.db"
    open_database(path)
    conn = sqlite3.connect(path)
    try:
        _identity_world(conn)
        conn.execute(
            "INSERT INTO track_audio_fingerprint VALUES "
            "('fp-u', 'fpcalc', 'chromaprint-2', 30.5, 1, X'00')"
        )
        conn.execute("DELETE FROM tracks WHERE uuid_id = 'fp-u'")
        assert conn.execute("SELECT count(*) FROM track_audio_identity").fetchone()[0] == 0
        assert conn.execute("SELECT count(*) FROM track_audio_fingerprint").fetchone()[0] == 0
    finally:
        conn.close()


def test_the_fingerprint_duration_is_indexed(conn):
    assert ("track_audio_fingerprint", ("duration_s",)) in _indexes(conn)


# --- the candidate store (plan O2, DEV-6.5-02) ---------------------------------------


def _two_owner_tracks(conn):
    """Sam owns s1 and s2, Alex owns a1."""
    conn.execute("PRAGMA foreign_keys=ON")
    for uid, name in ((911, "sam"), (912, "alex")):
        conn.execute(
            "INSERT INTO users (id, username, username_key, password_hash, library_folder, "
            "created_at) VALUES (?, ?, ?, 'h', ?, 0)",
            (uid, name, name, name),
        )
    for track_id, uuid, owner in ((911, "s1", 911), (912, "s2", 911), (913, "a1", 912)):
        conn.execute(
            f"INSERT INTO tracks (id, uuid_id, {PATH_COLUMNS}, owner_id) "
            f"VALUES (?, ?, {PATH_MARKS}, ?)",
            (track_id, uuid, *path_values(f"/m/{uuid}"), owner),
        )


def _candidate(conn, owner, uuid_a, uuid_b, *, status="open", band_rank=0, score=1.0):
    conn.execute(
        "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
        "sort_score, matcher_version, detected_at, status) VALUES (?, ?, ?, 'exact', ?, ?, "
        "'m1', 0, ?)",
        (owner, uuid_a, uuid_b, band_rank, score, status),
    )


@pytest.fixture
def store(tmp_path):
    path = tmp_path / "database.db"
    open_database(path)
    connection = sqlite3.connect(path)
    _two_owner_tracks(connection)
    try:
        yield connection
    finally:
        connection.close()


def test_a_pair_of_one_owners_tracks_is_stored(store):
    _candidate(store, 911, "s1", "s2")
    assert store.execute(
        "SELECT owner_id, uuid_a, uuid_b, status FROM track_duplicate_candidates"
    ).fetchall() == [(911, "s1", "s2", "open")]


@pytest.mark.parametrize(
    "owner, uuid_a, uuid_b",
    [
        (911, "a1", "s1"),  # partners of two owners
        (912, "s1", "s2"),  # both Sam's, filed under Alex
        (911, "s1", "nope"),  # no such track
    ],
)
def test_a_cross_owner_or_dangling_pair_cannot_be_stored(store, owner, uuid_a, uuid_b):
    with pytest.raises(sqlite3.IntegrityError):
        _candidate(store, owner, uuid_a, uuid_b)


def test_pairs_are_canonical(store):
    with pytest.raises(sqlite3.IntegrityError):
        _candidate(store, 911, "s2", "s1")
    with pytest.raises(sqlite3.IntegrityError):
        _candidate(store, 911, "s1", "s1")


@pytest.mark.parametrize(
    "column, value",
    [("kind", "acoustic"), ("band_rank", 3), ("status", "closed"), ("sort_score", None)],
)
def test_candidate_columns_are_constrained(store, column, value):
    _candidate(store, 911, "s1", "s2")
    with pytest.raises(sqlite3.IntegrityError):
        store.execute(f"UPDATE track_duplicate_candidates SET {column} = ?", (value,))


def test_a_pair_goes_when_either_track_goes(store):
    _candidate(store, 911, "s1", "s2")
    store.execute("DELETE FROM tracks WHERE uuid_id = 's2'")
    assert store.execute("SELECT count(*) FROM track_duplicate_candidates").fetchone()[0] == 0


def test_a_track_uuid_is_unique_per_owner_pair(conn):
    uniques = set()
    for _, name, unique, *_ in conn.execute("PRAGMA index_list(tracks)"):
        if unique:
            uniques.add(tuple(r[2] for r in conn.execute(f"PRAGMA index_info({name})")))
    assert ("uuid_id", "owner_id") in uniques


def test_candidate_indexes_lead_with_the_owner_for_the_list(conn):
    indexes = _indexes(conn)
    assert (
        "track_duplicate_candidates",
        ("owner_id", "status", "band_rank", "sort_score", "uuid_a", "uuid_b"),
    ) in indexes
    assert ("track_duplicate_candidates", ("uuid_b",)) in indexes


# 6.5 spec §6.1 "Phase 8 keyset", with the owner predicate SC-28 adds.
KEYSET_PAGE = (
    "SELECT uuid_a, uuid_b FROM track_duplicate_candidates "
    "WHERE owner_id = ? AND status = ? AND (band_rank > ? OR (band_rank = ? AND "
    "(sort_score < ? OR (sort_score = ? AND (uuid_a, uuid_b) > (?, ?))))) "
    "ORDER BY band_rank, sort_score DESC, uuid_a, uuid_b LIMIT 50"
)
KEYSET_ARGS = (911, "open", 0, 0, 1.0, 1.0, "", "")


def test_the_phase_8_keyset_page_uses_the_list_index_without_a_temp_b_tree(store):
    plan = [row[3] for row in store.execute("EXPLAIN QUERY PLAN " + KEYSET_PAGE, KEYSET_ARGS)]
    assert any("idx_tdc_list" in step for step in plan), plan
    assert not any("TEMP B-TREE" in step for step in plan), plan


def test_the_keyset_walks_every_pair_once_in_order(store):
    for uid, uuid, owner in ((914, "s3", 911), (915, "s4", 911)):
        store.execute(
            f"INSERT INTO tracks (id, uuid_id, {PATH_COLUMNS}, owner_id) "
            f"VALUES (?, ?, {PATH_MARKS}, ?)",
            (uid, uuid, *path_values(f"/m/{uuid}"), owner),
        )
    _candidate(store, 911, "s1", "s2", band_rank=0, score=1.0)
    _candidate(store, 911, "s3", "s4", band_rank=1, score=0.9)
    _candidate(store, 911, "s1", "s3", band_rank=1, score=0.9)
    _candidate(store, 911, "s2", "s4", band_rank=2, score=0.8)

    seen, cursor = [], (-1, -1, 2.0, 2.0, "", "")
    while True:
        page = store.execute(
            KEYSET_PAGE.replace("LIMIT 50", "LIMIT 1") .replace(
                "SELECT uuid_a, uuid_b", "SELECT uuid_a, uuid_b, band_rank, sort_score"
            ),
            (911, "open", *cursor),
        ).fetchall()
        if not page:
            break
        a, b, rank, score = page[0]
        seen.append((a, b))
        cursor = (rank, rank, score, score, a, b)
    assert seen == [("s1", "s2"), ("s1", "s3"), ("s3", "s4"), ("s2", "s4")]


def test_live_tracks_is_every_track_with_its_owner(store):
    """6.5 spec §5 "Liveness" (6.5-U11). Phase 8 adds its pending-deletion
    marker to this view; consumers never write their own predicate."""
    columns = [row[1] for row in store.execute("PRAGMA table_info(live_tracks)")]
    assert columns == ["id", "uuid_id", "owner_id", "file_path"]
    assert sorted(store.execute("SELECT uuid_id, owner_id FROM live_tracks")) == [
        ("a1", 912), ("s1", 911), ("s2", 911),
    ]
