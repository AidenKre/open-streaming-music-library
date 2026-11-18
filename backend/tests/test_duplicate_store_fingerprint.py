"""Phase 6.5B.2b: the candidate store's fingerprint half (spec §6.4 "Matching" step 3;
review 6.5-U10).

- An upsert updates an existing row's kind, band and score, so a pair whose
  exact match is gone but whose prints still match becomes a fingerprint pair.
- An ``open`` fingerprint row is deleted only when the subject's print is
  ``current``, the partner is a live same-owner track whose print is
  ``current`` of the same algorithm, and the partner was compared and did not
  match. Pending, failed, low-information, other-algorithm, identity-less or
  non-live partners keep the pair (unknown is not "no match").
- Exact→MP3 conversion of one member (U10): with a fingerprinter the pair
  becomes a strong fingerprint pair; without one it is removed.
"""

import sqlite3

import pytest

from app.database.database import Database
from app.services.duplicate_detection import DuplicateMatch, TrackRef
from tests.fingerprint_fixtures import ALGO, fp_track
from tests.identity_worker_fakes import FakeFingerprinter, make_worker
from tests.identity_worker_fixtures import add_track, identity, make_db, set_identity, sql

NOW = 1_800_000_000
V1 = "matcher-v1"


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


def mark_stale(db, uuid_id, reason):
    conn = sqlite3.connect(db.context.database_path)
    try:
        Database._mark_audio_identity_stale_in(conn, uuid_id, reason)
        conn.commit()
    finally:
        conn.close()


def pair(a, b):
    return tuple(sorted((a, b)))


def candidates(db):
    return {(r["uuid_a"], r["uuid_b"]): r for r in sql(db, "SELECT * FROM track_duplicate_candidates")}


def seed(db, a, b, *, kind="fingerprint", status="open", band_rank=1, score=0.95):
    ua, ub = pair(a, b)
    sql(db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
            "sort_score, matcher_version, detected_at, status) VALUES (?, ?, ?, ?, ?, ?, 'old', 1, ?)",
        (db.owner_id, ua, ub, kind, band_rank, score, status))


def store(db, uuid_id, matches=(), **override):
    row = identity(db, uuid_id)
    kwargs = dict(generation=row["generation"], exact_state=row["exact_state"], fp_state=row["fp_state"],
                  matches=tuple(matches), matcher_version=V1, now=NOW, owner_id=db.owner_id)
    kwargs.update(override)
    return db.store_duplicate_candidates(uuid_id, **kwargs)


def fp(uuid_id, band="strong", score=0.97):
    return DuplicateMatch(TrackRef(uuid_id), "fingerprint", band, score)


def subject_and_partner(db, **partner):
    x = fp_track(db, "x")
    y = fp_track(db, "y", **partner)
    sql(db, "UPDATE track_audio_identity SET match_state = 'pending'")
    return x, y


# --- the fingerprint delete rule ---------------------------------------------------------------


def test_an_open_fingerprint_pair_is_removed_when_both_prints_are_current_and_no_longer_match(db):
    x, y = subject_and_partner(db)
    seed(db, x, y)

    assert store(db, x) is True

    assert candidates(db) == {}


def test_a_fingerprint_pair_that_still_matches_is_updated_not_removed(db):
    x, y = subject_and_partner(db)
    seed(db, x, y, band_rank=1, score=0.95)

    store(db, x, [fp(y, "possible", 0.86)])

    row = candidates(db)[pair(x, y)]
    assert (row["kind"], row["band_rank"], row["sort_score"], row["status"]) == ("fingerprint", 2, 0.86, "open")


@pytest.mark.parametrize("partner", [
    {"state": "pending"},
    {"state": "failed"},
    {"state": "low_information"},
    {"state": "unavailable", "items": None},
    {"algorithm": "chromaprint-1"},
])
def test_a_fingerprint_pair_survives_a_partner_whose_print_was_not_compared(db, partner):
    x, y = subject_and_partner(db, **partner)
    seed(db, x, y)

    store(db, x)

    assert pair(x, y) in candidates(db)


def test_a_fingerprint_pair_survives_a_partner_with_no_identity_row(db):
    x = fp_track(db, "x")
    sql(db, "UPDATE track_audio_identity SET match_state = 'pending'")
    y = add_track(db, "/m/y.flac", identity={"_none": True})
    seed(db, x, y)

    store(db, x)

    assert pair(x, y) in candidates(db)


def test_a_fingerprint_pair_survives_a_partner_that_is_not_live(db):
    x, y = subject_and_partner(db)
    seed(db, x, y)
    sql(db, "DROP VIEW live_tracks")
    sql(db, "CREATE VIEW live_tracks AS SELECT id, uuid_id, owner_id, file_path FROM tracks "
            f"WHERE uuid_id <> '{y}'")

    store(db, x)

    assert pair(x, y) in candidates(db)


@pytest.mark.parametrize("state", ["low_information", "too_short", "unavailable", "failed"])
def test_nothing_is_removed_while_the_subjects_own_print_is_not_current(db, state):
    x, y = subject_and_partner(db)
    set_identity(db, x, fp_state=state)
    seed(db, x, y)

    store(db, x)

    assert pair(x, y) in candidates(db)


def test_a_dismissed_fingerprint_pair_is_never_removed(db):
    x, y = subject_and_partner(db)
    seed(db, x, y, status="dismissed")

    store(db, x)

    assert candidates(db)[pair(x, y)]["status"] == "dismissed"


def test_an_exact_pair_is_not_judged_by_the_fingerprint_layer(db):
    # Same digest: the exact layer still matches, so the exact rule keeps it.
    x = fp_track(db, "x", digest="ab" * 32)
    y = fp_track(db, "y", digest="ab" * 32)
    sql(db, "UPDATE track_audio_identity SET match_state = 'pending'")
    seed(db, x, y, kind="exact", band_rank=0, score=1.0)

    store(db, x, [DuplicateMatch(TrackRef(y), "exact", "exact", None)])

    assert candidates(db)[pair(x, y)]["kind"] == "exact"


def test_an_exact_pair_whose_audio_changed_but_prints_match_becomes_a_fingerprint_pair(db):
    x, y = subject_and_partner(db)  # different digests, same print
    seed(db, x, y, kind="exact", band_rank=0, score=1.0)

    store(db, x, [fp(y, "strong", 0.97)])

    row = candidates(db)[pair(x, y)]
    assert (row["kind"], row["band_rank"], row["sort_score"]) == ("fingerprint", 1, 0.97)


def test_a_store_whose_print_state_changed_since_the_read_is_discarded(db):
    x, y = subject_and_partner(db)
    seed(db, x, y)

    assert store(db, x, fp_state="pending") is False

    assert identity(db, x)["match_state"] == "pending"
    assert pair(x, y) in candidates(db)


def test_the_fingerprint_partner_read_looks_up_this_tracks_pairs_only(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        plan = [row[3] for row in conn.execute(
            "EXPLAIN QUERY PLAN " + Database._FINGERPRINT_PARTNERS_SQL, ("u", db.owner_id, ALGO))]
    finally:
        conn.close()

    assert not any("idx_tdc_list" in step for step in plan), plan
    assert not any(step.startswith("SCAN") for step in plan), plan


# --- U10: an exact pair after one member is converted to MP3 -----------------------------------


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _exact_pair_then_convert(db, music, fingerprinter):
    paths = {name: music / f"{name}.flac" for name in ("x", "y")}
    for p in paths.values():
        p.write_bytes(b"same-audio")
    fp_state = "pending" if fingerprinter else "unavailable"
    x, y = (add_track(db, p, identity={"fp_state": fp_state}) for p in paths.values())
    worker = make_worker(db, matcher_version=V1, fingerprinter=fingerprinter)
    _drain(worker)
    assert candidates(db)[pair(x, y)]["kind"] == "exact"
    # y re-encoded to MP3: new bytes in place, then the conversion writer's mark.
    paths["y"].write_bytes(b"mp3-of-the-same-audio")
    mark_stale(db, y, "conversion")
    _drain(worker)
    return x, y


def _drain(worker, limit=200):
    for _ in range(limit):
        if worker.process_one().outcome == "idle":
            return
    raise AssertionError("worker never went idle")


def test_converting_one_member_to_mp3_turns_the_exact_pair_into_a_fingerprint_pair(db, music):
    x, y = _exact_pair_then_convert(db, music, FakeFingerprinter())

    row = candidates(db)[pair(x, y)]
    assert (row["kind"], row["band_rank"], row["sort_score"], row["status"]) == ("fingerprint", 1, 1.0, "open")


def test_converting_one_member_to_mp3_without_a_fingerprinter_removes_the_pair(db, music):
    _exact_pair_then_convert(db, music, None)

    assert candidates(db) == {}
