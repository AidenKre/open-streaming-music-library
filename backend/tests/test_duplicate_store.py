"""Phase 6.5A.3: the candidate store write behind the worker's matching step
(spec §6.4 "Matching" steps 2–4, §6.1 candidates table; review 6.5-U10).

``Database.store_duplicate_candidates`` runs one transaction that:

- writes only if the subject row is unchanged since it was read
  (generation, exact state, ``match_state='pending'``, owner, no journal row);
- upserts every library match in canonical ``(min, max)`` order, updating
  kind, band, score and matcher version and **never** ``status``; a partner
  that is no longer a live track of the same owner is skipped (no FK error);
- deletes an ``open`` exact row only when the partner is live, both tracks
  are exact-``current`` and the two hashes do not match (compared, not
  matched); unknown is never "no match";
- sets ``match_state='current'`` and stores the matcher version.

Rows are seeded and read back with plain SQL.
"""

import sqlite3

import pytest

from app.services.audio_identity import KIND_PACKETS, KIND_PCM, AudioIdentity, ExactAudioHash
from app.services.duplicate_detection import (
    DuplicateMatch,
    StagedRef,
    TrackRef,
    find_duplicates,
)
from tests.identity_worker_fixtures import (
    DIGEST_A,
    DIGEST_B,
    add_journal,
    add_track,
    identity,
    set_identity,
    sql,
)
from tests.owned_database import add_test_user
from tests.pending_deletion import mark_pending_deletion

NOW = 1_800_000_000
V1 = "matcher-v1"
V2 = "matcher-v2"


def hashed(digest=DIGEST_A, state="current", kind=KIND_PCM, rate=44100, channels=2, **extra):
    values = {"exact_state": state, "exact_kind": kind, "exact_digest": digest,
              "sample_rate_hz": rate, "channels": channels}
    if digest is None:
        values.update(exact_kind=None, sample_rate_hz=None, channels=None)
    values.update(extra)
    return values


def track(db, name, owner_id=None, **identity_values):
    return add_track(db, f"/m/{name}.flac", owner_id=owner_id, identity=hashed(**identity_values))


def exact(uuid_id):
    return DuplicateMatch(subject=TrackRef(uuid_id), kind="exact", band="exact", score=None)


def pair(a, b):
    return tuple(sorted((a, b)))


def candidates(db):
    return {
        (r["uuid_a"], r["uuid_b"]): r
        for r in sql(db, "SELECT * FROM track_duplicate_candidates")
    }


def seed_pair(db, a, b, *, status="open", kind="exact", owner_id=None, band_rank=0, score=1.0,
              version="old", detected_at=1, status_changed_at=None):
    ua, ub = pair(a, b)
    sql(
        db,
        "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
        "sort_score, matcher_version, detected_at, status, status_changed_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (owner_id or db.owner_id, ua, ub, kind, band_rank, score, version, detected_at, status,
         status_changed_at),
    )


def store(db, uuid_id, matches, *, owner_id=None, generation=None, exact_state=None, version=V1):
    row = identity(db, uuid_id)
    return db.store_duplicate_candidates(
        uuid_id,
        generation=row["generation"] if generation is None else generation,
        exact_state=row["exact_state"] if exact_state is None else exact_state,
        fp_state=row["fp_state"],
        matches=tuple(matches),
        matcher_version=version,
        now=NOW,
        owner_id=owner_id or db.owner_id,
    )


def find(db, uuid_id, owner_id=None):
    row = identity(db, uuid_id)
    subject = ExactAudioHash(row["exact_kind"], row["exact_digest"], row["sample_rate_hz"],
                             row["channels"], row["bits_per_sample"])
    conn = sqlite3.connect(db.context.database_path)
    try:
        return find_duplicates(
            conn, AudioIdentity(exact=subject, tool_versions=None, computed_at=NOW),
            owner_id=owner_id or db.owner_id, exclude=frozenset({uuid_id}),
        ).matches
    finally:
        conn.close()


# --- upsert ----------------------------------------------------------------------------------


def test_a_match_is_stored_in_canonical_order_and_the_track_is_marked_matched(db):
    x = track(db, "x")
    y = track(db, "y")

    assert store(db, x, [exact(y)]) is True

    assert set(candidates(db)) == {pair(x, y)}
    stored = candidates(db)[pair(x, y)]
    assert stored["uuid_a"] < stored["uuid_b"]
    assert {k: stored[k] for k in ("owner_id", "kind", "band_rank", "sort_score",
                                   "matcher_version", "detected_at", "status")} == {
        "owner_id": db.owner_id, "kind": "exact", "band_rank": 0, "sort_score": 1.0,
        "matcher_version": V1, "detected_at": NOW, "status": "open",
    }
    assert identity(db, x)["match_state"] == "current"
    assert identity(db, x)["matcher_version"] == V1


def test_either_side_finds_the_same_single_row(db):
    x = track(db, "x")
    y = track(db, "y")

    store(db, x, [exact(y)])
    store(db, y, [exact(x)])

    assert list(candidates(db)) == [pair(x, y)]


def test_an_existing_row_is_updated_but_its_status_never_changes(db):
    x = track(db, "x")
    y = track(db, "y")
    seed_pair(db, x, y, status="dismissed", kind="fingerprint", band_rank=1, score=0.93,
              version="old", detected_at=5, status_changed_at=7)

    store(db, x, [exact(y)])

    stored = candidates(db)[pair(x, y)]
    assert {k: stored[k] for k in ("kind", "band_rank", "sort_score", "matcher_version")} == {
        "kind": "exact", "band_rank": 0, "sort_score": 1.0, "matcher_version": V1,
    }
    assert (stored["status"], stored["status_changed_at"], stored["detected_at"]) == ("dismissed", 7, 5)


def test_a_partner_deleted_between_find_and_upsert_is_skipped(db):
    x = track(db, "x")
    y = track(db, "y")
    z = track(db, "z")
    matches = find(db, x)
    assert {m.subject for m in matches} == {TrackRef(y), TrackRef(z)}

    assert db.delete_track(y) is True
    assert store(db, x, matches) is True

    assert set(candidates(db)) == {pair(x, z)}
    assert identity(db, x)["match_state"] == "current"


def test_a_partner_of_another_owner_is_never_paired(db):
    bob = add_test_user(db, "bob")
    x = track(db, "x")
    his = track(db, "his", owner_id=bob)

    assert store(db, x, [exact(his)]) is True

    assert candidates(db) == {}


def test_the_schema_itself_rejects_a_cross_owner_pair(db):
    bob = add_test_user(db, "bob")
    x = track(db, "x")
    his = track(db, "his", owner_id=bob)
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("PRAGMA foreign_keys=ON")
    try:
        for owner in (db.owner_id, bob):
            ua, ub = pair(x, his)
            with pytest.raises(sqlite3.IntegrityError, match="FOREIGN KEY"):
                conn.execute(
                    "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, "
                    "band_rank, sort_score, matcher_version, detected_at) "
                    "VALUES (?, ?, ?, 'exact', 0, 1.0, 'v', 0)",
                    (owner, ua, ub),
                )
    finally:
        conn.close()


def test_staged_matches_are_not_stored(db):
    x = track(db, "x")
    staged = DuplicateMatch(subject=StagedRef("item"), kind="exact", band="exact", score=None)

    assert store(db, x, [staged]) is True

    assert candidates(db) == {}


# --- deletion: only compared-and-unmatched, both current, live partners ------------------------


def test_an_open_pair_is_removed_when_both_are_current_and_no_longer_match(db):
    x = track(db, "x")
    y = track(db, "y", digest=DIGEST_B)  # Y was re-encoded since the pair was found
    seed_pair(db, x, y)

    store(db, x, [])

    assert candidates(db) == {}


def test_a_partner_on_another_kind_is_compared_and_unmatched(db):
    x = track(db, "x")
    y = track(db, "y", kind=KIND_PACKETS)  # converted to MP3, no fingerprinter
    seed_pair(db, x, y)

    store(db, x, [])

    assert candidates(db) == {}


def test_a_partner_that_still_matches_is_kept_even_if_the_caller_left_it_out(db):
    x = track(db, "x")
    y = track(db, "y")
    seed_pair(db, x, y)

    store(db, x, [])

    assert set(candidates(db)) == {pair(x, y)}


@pytest.mark.parametrize(
    "partner",
    [
        {"state": "pending", "digest": None},
        {"state": "pending", "digest": DIGEST_B},
        {"state": "failed", "digest": None},
        {"state": "unsupported", "digest": None},
    ],
    ids=["pending-no-digest", "pending-other-digest", "failed", "unsupported"],
)
def test_a_pair_survives_a_partner_that_is_not_current(db, partner):
    x = track(db, "x")
    y = track(db, "y", **partner)
    seed_pair(db, x, y)

    store(db, x, [])

    assert set(candidates(db)) == {pair(x, y)}


def test_a_pair_survives_a_partner_with_no_identity_row(db):
    x = track(db, "x")
    y = add_track(db, "/m/y.flac", identity={"_none": True})
    seed_pair(db, x, y)

    store(db, x, [])

    assert set(candidates(db)) == {pair(x, y)}


@pytest.mark.parametrize("state", ["failed", "unsupported"])
def test_nothing_is_removed_while_the_subject_itself_is_not_current(db, state):
    x = track(db, "x", state=state, digest=None)
    y = track(db, "y", digest=DIGEST_B)
    seed_pair(db, x, y)

    assert store(db, x, []) is True

    assert set(candidates(db)) == {pair(x, y)}
    assert identity(db, x)["match_state"] == "current"


def test_a_dismissed_pair_is_never_removed(db):
    x = track(db, "x")
    y = track(db, "y", digest=DIGEST_B)
    seed_pair(db, x, y, status="dismissed")

    store(db, x, [])

    assert candidates(db)[pair(x, y)]["status"] == "dismissed"


def test_a_fingerprint_pair_is_not_judged_by_the_exact_layer(db):
    x = track(db, "x")
    y = track(db, "y", digest=DIGEST_B)
    seed_pair(db, x, y, kind="fingerprint", band_rank=1, score=0.95)

    store(db, x, [])

    assert set(candidates(db)) == {pair(x, y)}


def test_a_pair_whose_partner_is_not_live_is_kept(db):
    x = track(db, "x")
    y = track(db, "y", digest=DIGEST_B)
    seed_pair(db, x, y)
    mark_pending_deletion(db.context.database_path, y)

    store(db, x, [])

    assert set(candidates(db)) == {pair(x, y)}


def test_pairs_not_involving_the_track_are_untouched(db):
    x = track(db, "x")
    y = track(db, "y", digest=DIGEST_B)
    z = track(db, "z", digest=DIGEST_A)
    seed_pair(db, y, z)  # stale on purpose: only Y's or Z's own refresh may judge it

    store(db, x, [exact(z)])

    assert set(candidates(db)) == {pair(y, z), pair(x, z)}


# --- the compare-and-set ---------------------------------------------------------------------


def _unchanged(db, x, y):
    assert candidates(db) == {}
    assert identity(db, x)["match_state"] == "pending"
    assert identity(db, x)["matcher_version"] is None


def test_a_bumped_generation_discards_the_result(db):
    x = track(db, "x")
    y = track(db, "y")
    generation = identity(db, x)["generation"]
    set_identity(db, x, generation=generation + 1)

    assert store(db, x, [exact(y)], generation=generation) is False
    _unchanged(db, x, y)


def test_a_changed_exact_state_discards_the_result(db):
    x = track(db, "x")
    y = track(db, "y")

    assert store(db, x, [exact(y)], exact_state="pending") is False
    _unchanged(db, x, y)


def test_an_already_matched_row_is_not_rewritten(db):
    x = track(db, "x", match_state="current", matcher_version=V1)
    y = track(db, "y")

    assert store(db, x, [exact(y)], version=V2) is False
    assert candidates(db) == {}
    assert identity(db, x)["matcher_version"] == V1


def test_a_journal_row_discards_the_result(db):
    x = track(db, "x")
    y = track(db, "y")
    add_journal(db, x)

    assert store(db, x, [exact(y)]) is False
    _unchanged(db, x, y)


def test_another_owner_cannot_store_for_the_track(db):
    bob = add_test_user(db, "bob")
    x = track(db, "x")
    y = track(db, "y")

    assert store(db, x, [exact(y)], owner_id=bob) is False
    _unchanged(db, x, y)


@pytest.mark.parametrize("owner", [None, True, "1"])
def test_the_store_requires_a_real_owner(db, owner):
    x = track(db, "x")
    row = identity(db, x)
    with pytest.raises(TypeError):
        db.store_duplicate_candidates(
            x, generation=row["generation"], exact_state="current", fp_state=row["fp_state"], matches=(),
            matcher_version=V1, now=NOW, owner_id=owner,
        )
