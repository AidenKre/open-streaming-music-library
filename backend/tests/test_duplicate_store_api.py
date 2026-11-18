"""Phase 6.5A.3: the candidate-store API for consumers (spec §7; review
6.5-U10, U11; plan decision 8: no endpoint).

- ``Database._seed_dismissed_candidates_in(conn, uuid, partner_uuids)``
  (Phase 7 "keep both"): canonical exact pairs inserted as ``dismissed``, or
  an existing open pair dismissed; same owner and live partners only.
- ``set_duplicate_candidate_status(uuid_a, uuid_b, status, *, owner_id)``
  (Phase 8 dismiss/restore, L08): a foreign or unknown pair is "not found"
  and nothing changes (SC-28 rule 4).
- ``get_identity_coverage_summary(*, owner_id)``: per-layer counts per state
  over the owner's live tracks.
"""

import sqlite3

import pytest

from app.database.database import Database
from app.library import Library
from tests.identity_worker_fixtures import DIGEST_A, add_track, make_db, sql
from tests.owned_database import add_test_user


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


def track(db, name, owner_id=None, **identity_values):
    values = {"exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A,
              "sample_rate_hz": 44100, "channels": 2}
    values.update(identity_values)
    return add_track(db, f"/m/{name}.flac", owner_id=owner_id, identity=values)


def pair(a, b):
    return tuple(sorted((a, b)))


def rows(db):
    return {(r["uuid_a"], r["uuid_b"]): r for r in sql(db, "SELECT * FROM track_duplicate_candidates")}


def seed_open(db, a, b, owner_id=None, kind="exact", band_rank=0, score=1.0):
    ua, ub = pair(a, b)
    sql(db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
            "sort_score, matcher_version, detected_at) VALUES (?, ?, ?, ?, ?, ?, 'v', 1)",
        (owner_id or db.owner_id, ua, ub, kind, band_rank, score))


def seed_dismissed(db, uuid_id, partners):
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        conn.execute("BEGIN IMMEDIATE")
        result = Database._seed_dismissed_candidates_in(conn, uuid_id, partners)
        assert conn.in_transaction  # the caller's transaction; never committed here
        conn.commit()
        return result
    finally:
        conn.close()


# --- _seed_dismissed_candidates_in -----------------------------------------------------------


def test_keep_both_seeds_dismissed_exact_pairs_in_canonical_order(db):
    new = track(db, "new")
    a = track(db, "a")
    b = track(db, "b")

    seed_dismissed(db, new, [a, b])

    stored = rows(db)
    assert set(stored) == {pair(new, a), pair(new, b)}
    for r in stored.values():
        assert r["uuid_a"] < r["uuid_b"]
        assert (r["owner_id"], r["kind"], r["band_rank"], r["sort_score"], r["status"]) == (
            db.owner_id, "exact", 0, 1.0, "dismissed")
        assert r["status_changed_at"] is not None
        assert r["detected_at"] is not None


def test_keep_both_dismisses_an_existing_open_pair_and_keeps_its_match_data(db):
    new = track(db, "new")
    a = track(db, "a")
    seed_open(db, new, a, kind="fingerprint", band_rank=1, score=0.95)

    seed_dismissed(db, new, [a])

    r = rows(db)[pair(new, a)]
    assert (r["status"], r["kind"], r["band_rank"], r["sort_score"]) == ("dismissed", "fingerprint", 1, 0.95)
    assert r["status_changed_at"] is not None


def test_keep_both_skips_other_owners_unknown_and_self(db):
    bob = add_test_user(db, "bob")
    new = track(db, "new")
    his = track(db, "his", owner_id=bob)

    seed_dismissed(db, new, [his, "00000000-0000-4000-8000-00000000dead", new])

    assert rows(db) == {}


def test_keep_both_skips_a_partner_that_is_not_live(db):
    new = track(db, "new")
    gone = track(db, "gone")
    sql(db, "DROP VIEW live_tracks")
    sql(db, "CREATE VIEW live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks "
            f"WHERE uuid_id <> '{gone}'")

    seed_dismissed(db, new, [gone])

    assert rows(db) == {}


def test_keep_both_for_an_unknown_subject_changes_nothing(db):
    a = track(db, "a")

    seed_dismissed(db, "00000000-0000-4000-8000-00000000dead", [a])

    assert rows(db) == {}


def test_keep_both_rolls_back_with_the_callers_transaction(db):
    new = track(db, "new")
    a = track(db, "a")
    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.execute("BEGIN IMMEDIATE")
        Database._seed_dismissed_candidates_in(conn, new, [a])
        conn.rollback()
    finally:
        conn.close()

    assert rows(db) == {}


# --- set_duplicate_candidate_status ----------------------------------------------------------


@pytest.mark.parametrize("order", ["ab", "ba"])
def test_dismiss_and_restore_by_either_order(db, order):
    a = track(db, "a")
    b = track(db, "b")
    seed_open(db, a, b)
    first, second = (a, b) if order == "ab" else (b, a)

    assert db.set_duplicate_candidate_status(first, second, "dismissed") is True
    r = rows(db)[pair(a, b)]
    assert r["status"] == "dismissed"
    assert r["status_changed_at"] is not None

    assert db.set_duplicate_candidate_status(second, first, "open") is True
    assert rows(db)[pair(a, b)]["status"] == "open"


def test_setting_the_same_status_again_is_found_and_changes_nothing(db):
    a = track(db, "a")
    b = track(db, "b")
    seed_open(db, a, b)
    sql(db, "UPDATE track_duplicate_candidates SET status = 'dismissed', status_changed_at = 5")

    assert db.set_duplicate_candidate_status(a, b, "dismissed") is True
    assert rows(db)[pair(a, b)]["status_changed_at"] == 5


def test_another_owners_pair_is_not_found_and_unchanged(db):
    bob = add_test_user(db, "bob")
    a = track(db, "a", owner_id=bob)
    b = track(db, "b", owner_id=bob)
    seed_open(db, a, b, owner_id=bob)
    before = rows(db)

    assert db.set_duplicate_candidate_status(a, b, "dismissed", owner_id=db.owner_id) is False
    assert rows(db) == before


def test_an_unknown_pair_is_not_found(db):
    a = track(db, "a")
    b = track(db, "b")

    assert db.set_duplicate_candidate_status(a, b, "dismissed") is False
    assert rows(db) == {}


def test_a_pair_with_a_partner_that_is_not_live_is_not_found(db):
    a = track(db, "a")
    b = track(db, "b")
    seed_open(db, a, b)
    sql(db, "DROP VIEW live_tracks")
    sql(db, "CREATE VIEW live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks "
            f"WHERE uuid_id <> '{b}'")

    assert db.set_duplicate_candidate_status(a, b, "dismissed") is False
    assert rows(db)[pair(a, b)]["status"] == "open"


@pytest.mark.parametrize("status", ["closed", "", None, "OPEN"])
def test_an_unknown_status_is_rejected(db, status):
    a = track(db, "a")
    b = track(db, "b")
    seed_open(db, a, b)

    with pytest.raises(ValueError):
        db.set_duplicate_candidate_status(a, b, status)
    assert rows(db)[pair(a, b)]["status"] == "open"


def test_the_library_binding_exposes_the_store_api_for_its_owner_only(db):
    bob = add_test_user(db, "bob")
    a = track(db, "a")
    b = track(db, "b")
    seed_open(db, a, b)

    assert Library(db, bob).set_duplicate_candidate_status(a, b, "dismissed") is False
    assert Library(db, db.owner_id).set_duplicate_candidate_status(a, b, "dismissed") is True


# --- the coverage summary --------------------------------------------------------------------


def test_the_coverage_summary_counts_each_state_per_layer_for_the_owner_only(db):
    bob = add_test_user(db, "bob")
    track(db, "a", fp_state="too_short", match_state="current")
    track(db, "b", exact_state="failed", exact_digest=None, exact_kind=None)
    track(db, "c", exact_state="unsupported", exact_digest=None, exact_kind=None,
          fp_state="pending")
    add_track(db, "/m/no-row.flac", identity={"_none": True})
    track(db, "his", owner_id=bob, exact_state="failed", exact_digest=None, exact_kind=None)

    summary = db.get_identity_coverage_summary()

    assert summary == {
        "exact": {"pending": 1, "current": 1, "failed": 1, "unsupported": 1},
        "fingerprint": {"pending": 2, "current": 0, "unavailable": 1, "too_short": 1,
                        "low_information": 0, "failed": 0},
        "match": {"pending": 3, "current": 1},
    }
    his = Library(db, bob).get_identity_coverage_summary()
    assert his["exact"] == {"pending": 0, "current": 0, "failed": 1, "unsupported": 0}


def test_the_coverage_summary_of_an_empty_library_is_all_zero(db):
    summary = db.get_identity_coverage_summary()

    assert all(n == 0 for layer in summary.values() for n in layer.values())


def test_the_coverage_summary_ignores_tracks_that_are_not_live(db):
    gone = track(db, "gone", exact_state="failed", exact_digest=None, exact_kind=None)
    sql(db, "DROP VIEW live_tracks")
    sql(db, "CREATE VIEW live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks "
            f"WHERE uuid_id <> '{gone}'")

    assert db.get_identity_coverage_summary()["exact"]["failed"] == 0
