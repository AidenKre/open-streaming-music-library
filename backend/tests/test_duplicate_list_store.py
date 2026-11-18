"""Phase 8A.4: the owned duplicate-pair reads behind ``/tracks/duplicates``
(spec §4 duplicates rows; SC-25 with DEV-6.5-02; SC-16l; review 8-U10, 8-U09).

- ``list_duplicate_candidates(*, owner_id, status, after, limit)``: one owner's
  pairs of one status, in ``(band_rank, sort_score DESC, uuid_a, uuid_b)``
  order, keyset-paged after ``(band_rank, sort_score, uuid_a, uuid_b)``; both
  members joined through ``live_tracks``, so a pair with a member pending
  deletion is not listed; each member carries its track summary, with an
  unknown audio property left null.

Pairs are planted with plain SQL and the expected order is built here in
Python, never from the production query.
"""

import sqlite3

import pytest

from app.library import Library
from tests.identity_worker_fixtures import add_track, make_db, sql
from tests.owned_database import add_test_user
from tests.pending_deletion import clear_pending_deletion, mark_pending_deletion


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


def tracks(db, count, owner_id=None, prefix="t"):
    return [add_track(db, f"/m/{prefix}{i}.flac", owner_id=owner_id) for i in range(count)]


def plant(db, a, b, *, kind="exact", band_rank=0, score=1.0, status="open", owner_id=None,
          detected_at=100):
    ua, ub = sorted((a, b))
    sql(db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
            "sort_score, matcher_version, detected_at, status) VALUES (?, ?, ?, ?, ?, ?, 'm', ?, ?)",
        (owner_id or db.owner_id, ua, ub, kind, band_rank, score, detected_at, status))
    return (band_rank, score, ua, ub)


def expected_order(keys):
    """The spec's order, written independently: band ascending, score
    descending, then the canonical uuids ascending."""
    return sorted(keys, key=lambda k: (k[0], -k[1], k[2], k[3]))


def key_of(row):
    return (row["band_rank"], row["sort_score"], row["uuid_a"], row["uuid_b"])


def traverse(db, status="open", limit=7, owner_id=None):
    seen, after = [], None
    for _ in range(1000):
        rows = db.list_duplicate_candidates(
            status=status, after=after, limit=limit,
            **({} if owner_id is None else {"owner_id": owner_id}))
        assert len(rows) <= limit
        seen += [key_of(r) for r in rows]
        if len(rows) < limit:
            return seen
        after = key_of(rows[-1])
    raise AssertionError("the traversal never ended")


def all_pairs(uuids):
    return [(a, b) for i, a in enumerate(uuids) for b in uuids[i + 1:]]


def planted_tiers(db):
    """More than 25 exact pairs at an equal sort_score (1.0), fingerprint pairs
    tied at 0.95 and 0.9 in band 1, and tied at 0.7 in band 2."""
    pairs = all_pairs(tracks(db, 12))  # 66 pairs
    keys = []
    for a, b in pairs[:30]:
        keys.append(plant(db, a, b))
    for i, (a, b) in enumerate(pairs[30:50]):
        keys.append(plant(db, a, b, kind="fingerprint", band_rank=1, score=0.95 if i % 2 else 0.9))
    for a, b in pairs[50:]:
        keys.append(plant(db, a, b, kind="fingerprint", band_rank=2, score=0.7))
    return keys


# --- order and keyset ------------------------------------------------------------------------


@pytest.mark.parametrize("limit", [1, 7, 25, 100])
def test_tied_pairs_are_traversed_completely_in_the_spec_order(db, limit):
    keys = planted_tiers(db)

    seen = traverse(db, limit=limit)

    assert seen == expected_order(keys)
    assert len(seen) == len(set(seen)) == 66


def test_a_page_starting_inside_a_tie_continues_with_the_next_uuids(db):
    keys = expected_order(planted_tiers(db))
    # Start after the 26th exact pair: the tie at band 0, score 1.0 continues.
    rows = db.list_duplicate_candidates(status="open", after=keys[25], limit=10)

    assert [key_of(r) for r in rows] == keys[26:36]


def test_only_the_asked_status_is_listed(db):
    a, b, c = tracks(db, 3)
    open_key = plant(db, a, b)
    dismissed_key = plant(db, a, c, status="dismissed")

    assert traverse(db, status="open") == [open_key]
    assert traverse(db, status="dismissed") == [dismissed_key]


def test_another_owners_pairs_are_never_listed_and_their_keys_are_no_handle(db):
    sam = add_test_user(db, "sam")
    theirs = tracks(db, 4, owner_id=sam, prefix="s")
    their_keys = [plant(db, a, b, owner_id=sam) for a, b in all_pairs(theirs)]
    mine = tracks(db, 3)
    my_keys = [plant(db, a, b) for a, b in all_pairs(mine)]

    assert traverse(db) == expected_order(my_keys)
    assert traverse(db, owner_id=sam) == expected_order(their_keys)
    # A cursor at sam's key only positions alex's own rows.
    after = expected_order(their_keys)[0]
    listed = [key_of(r) for r in db.list_duplicate_candidates(status="open", after=after, limit=10)]
    assert set(listed) <= set(my_keys)
    assert listed == [k for k in expected_order(my_keys) if k > after]


def test_a_library_lists_its_owners_pairs(db):
    a, b = tracks(db, 2)
    key = plant(db, a, b)

    rows = Library(db, db.owner_id).list_duplicate_candidates(status="open", after=None, limit=5)

    assert [key_of(r) for r in rows] == [key]


# --- liveness -----------------------------------------------------------------------------------


def test_a_pair_with_a_member_pending_deletion_is_hidden_until_the_deletion_rolls_back(db):
    a, b, c = tracks(db, 3)
    ab = plant(db, a, b)
    bc = plant(db, b, c, kind="fingerprint", band_rank=1, score=0.9)
    ac = plant(db, a, c)

    mark_pending_deletion(db.context.database_path, b)
    assert traverse(db) == [ac]

    clear_pending_deletion(db.context.database_path, b)
    assert traverse(db) == expected_order([ab, bc, ac])


# --- the row ------------------------------------------------------------------------------------


def test_a_row_carries_the_pair_and_both_track_summaries_with_unknowns_left_null(db):
    full, bare = tracks(db, 2)
    sql(db, "UPDATE trackmetadata SET title = 'Lucky', artist = 'Radiohead', album = 'OK Computer', "
            "codec = 'flac', bitrate_kbps = 912.5, sample_rate_hz = 44100, channels = 2, "
            "duration = 259.4 WHERE uuid_id = ?", (full,))
    sql(db, "UPDATE trackmetadata SET codec = NULL, bitrate_kbps = NULL, sample_rate_hz = NULL, "
            "channels = NULL, duration = NULL WHERE uuid_id = ?", (bare,))
    sql(db, "UPDATE tracks SET revision = 41, created_at = 1700000000 WHERE uuid_id = ?", (full,))
    sql(db, "UPDATE tracks SET revision = 42, created_at = 1700000500 WHERE uuid_id = ?", (bare,))
    plant(db, full, bare, kind="fingerprint", band_rank=1, score=0.93, detected_at=1700000999)

    [row] = db.list_duplicate_candidates(status="open", after=None, limit=5)

    assert {k: row[k] for k in ("kind", "band_rank", "sort_score", "detected_at", "status")} == {
        "kind": "fingerprint", "band_rank": 1, "sort_score": 0.93, "detected_at": 1700000999,
        "status": "open"}
    assert (row["uuid_a"], row["uuid_b"]) == tuple(sorted((full, bare)))
    summaries = {row["track_a"]["uuid_id"]: row["track_a"], row["track_b"]["uuid_id"]: row["track_b"]}
    assert set(summaries) == {full, bare}
    assert summaries[row["uuid_a"]] is row["track_a"]
    assert summaries[full] == {
        "uuid_id": full, "revision": 41, "title": "Lucky", "artist": "Radiohead",
        "album": "OK Computer", "codec": "flac", "bitrate_kbps": 912.5, "sample_rate_hz": 44100,
        "channels": 2, "duration_s": 259.4, "added_at": 1700000000, "file_path": "/m/t0.flac"}
    assert summaries[bare] == {
        "uuid_id": bare, "revision": 42, "title": None, "artist": None, "album": None,
        "codec": None, "bitrate_kbps": None, "sample_rate_hz": None, "channels": None,
        "duration_s": None, "added_at": 1700000500, "file_path": "/m/t1.flac"}


# --- the index ----------------------------------------------------------------------------------


def test_a_deep_page_seeks_through_idx_tdc_list(db, monkeypatch):
    keys = expected_order(planted_tiers(db))
    statements = []
    real_connect = sqlite3.connect

    def tracing_connect(*args, **kwargs):
        conn = real_connect(*args, **kwargs)
        conn.set_trace_callback(statements.append)
        return conn

    monkeypatch.setattr(sqlite3, "connect", tracing_connect)
    rows = db.list_duplicate_candidates(status="open", after=keys[40], limit=5)
    monkeypatch.undo()
    assert [key_of(r) for r in rows] == keys[41:46]

    [select] = [s for s in statements if "track_duplicate_candidates" in s and s.lstrip().upper().startswith("SELECT")]
    conn = sqlite3.connect(db.context.database_path)
    try:
        plan = [r[3] for r in conn.execute("EXPLAIN QUERY PLAN " + select)]
    finally:
        conn.close()
    # The pair table is searched (not scanned) through idx_tdc_list, seeking on
    # the owner, the status and the band, and the order needs no sort.
    [pair_search] = [d for d in plan if "idx_tdc_list" in d]
    assert pair_search.startswith("SEARCH"), plan
    assert "owner_id=? AND status=? AND band_rank>?" in pair_search, plan
    assert not any("TEMP B-TREE" in d for d in plan), plan


# --- counts (the summary's per-band numbers) ---------------------------------------------------


def test_counts_are_per_band_and_status_with_real_zeros(db):
    a, b, c, d = tracks(db, 4)
    plant(db, a, b)
    plant(db, a, c)
    plant(db, a, d, status="dismissed")
    plant(db, b, c, kind="fingerprint", band_rank=1, score=0.9, status="dismissed")
    plant(db, b, d, kind="fingerprint", band_rank=1, score=0.95, status="dismissed")

    assert db.count_duplicate_candidates() == {
        "exact": {"open": 2, "dismissed": 1},
        "strong": {"open": 0, "dismissed": 2},
        "possible": {"open": 0, "dismissed": 0},
    }


def test_counts_leave_out_pending_deletion_pairs_and_other_owners(db):
    sam = add_test_user(db, "sam")
    s1, s2 = tracks(db, 2, owner_id=sam, prefix="s")
    plant(db, s1, s2, owner_id=sam)
    a, b, c = tracks(db, 3)
    plant(db, a, b)
    plant(db, b, c, kind="fingerprint", band_rank=2, score=0.7)
    plant(db, a, c, status="dismissed")

    mark_pending_deletion(db.context.database_path, b)
    assert db.count_duplicate_candidates() == {
        "exact": {"open": 0, "dismissed": 1},
        "strong": {"open": 0, "dismissed": 0},
        "possible": {"open": 0, "dismissed": 0},
    }
    assert db.count_duplicate_candidates(owner_id=sam)["exact"] == {"open": 1, "dismissed": 0}

    clear_pending_deletion(db.context.database_path, b)
    assert db.count_duplicate_candidates() == {
        "exact": {"open": 1, "dismissed": 1},
        "strong": {"open": 0, "dismissed": 0},
        "possible": {"open": 1, "dismissed": 0},
    }


def test_an_owner_with_no_pairs_counts_real_zeros(db):
    assert Library(db, db.owner_id).count_duplicate_candidates() == {
        band: {"open": 0, "dismissed": 0} for band in ("exact", "strong", "possible")}
