"""Phase 6.5A.2d: the identity worker's database reads and its CAS write
(spec §6.4 "Queue", "Pre-check", "Write (CAS)"; SC-28 rule 3; review 6.5-U06).

The queue is the table itself: no job table, no lease. In this piece the
worker computes only the exact layer, so a row is work only while
``exact_state = 'pending'`` (6.5A.3 adds ``match_state``, 6.5B.1b the
fingerprint). Background reads span owners, so they take ``ANY_OWNER`` only.
"""

import sqlite3

import pytest

from app.database import ANY_OWNER
from tests.identity_worker_fixtures import (
    DIGEST_A,
    add_journal,
    add_track,
    identity,
    set_identity,
    sql,
)
from tests.owned_database import add_test_user

NOW = 1_800_000_000


def _next(db, now=NOW, skip=None):
    return db.next_identity_work(now, skip=skip or {}, owner_id=ANY_OWNER)


# --- the queue ---------------------------------------------------------------------------


def test_new_and_changed_tracks_come_before_the_backfill_then_in_row_order(db):
    backfill_1 = add_track(db, "/m/1.flac", identity={"priority": 1})
    new_1 = add_track(db, "/m/2.flac", identity={"priority": 0})
    backfill_2 = add_track(db, "/m/3.flac", identity={"priority": 1})
    new_2 = add_track(db, "/m/4.flac", identity={"priority": 0})

    order = []
    for _ in range(4):
        uuid_id = _next(db)
        order.append(uuid_id)
        set_identity(db, uuid_id, exact_state="current", match_state="current")
    assert order == [new_1, new_2, backfill_1, backfill_2]
    assert _next(db) is None


def test_a_row_in_backoff_waits_until_it_is_due(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"next_attempt_at": NOW + 60})
    assert _next(db, NOW + 59) is None
    assert _next(db, NOW + 60) == uuid_id
    assert _next(db, NOW + 61) == uuid_id


def test_a_due_row_later_in_order_is_not_hidden_by_a_waiting_one(db):
    add_track(db, "/m/1.flac", identity={"priority": 0, "next_attempt_at": NOW + 3600})
    due = add_track(db, "/m/2.flac", identity={"priority": 1})
    assert _next(db) == due


@pytest.mark.parametrize("state", ["current", "failed", "unsupported"])
def test_a_pending_fingerprint_alone_is_not_work_without_a_fingerprinter(db, state):
    # The queue read without fingerprint=True (no fingerprinter): a pending
    # print alone would make the worker spin over every row forever. The
    # fingerprinter-on twin is in test_identity_fingerprint_queue.py.
    add_track(db, "/m/1.flac", identity={
        "exact_state": state, "fp_state": "pending", "match_state": "current",
    })
    assert _next(db) is None


@pytest.mark.parametrize("state", ["current", "failed", "unsupported"])
def test_a_pending_match_is_work_once_the_exact_layer_is_settled(db, state):
    # 6.5A.3: the matching step makes match_state='pending' queue work.
    uuid_id = add_track(db, "/m/1.flac", identity={
        "exact_state": state, "fp_state": "pending", "match_state": "pending",
    })
    assert _next(db) == uuid_id


def test_a_track_with_a_file_operation_in_flight_is_skipped(db):
    busy = add_track(db, "/m/1.flac", identity={"priority": 0})
    other = add_track(db, "/m/2.flac", identity={"priority": 1})
    add_journal(db, busy, intent="convert")
    assert _next(db) == other


def test_a_deferred_row_is_skipped_until_its_generation_moves(db):
    first = add_track(db, "/m/1.flac", identity={"priority": 0, "generation": 5})
    second = add_track(db, "/m/2.flac", identity={"priority": 1})
    assert _next(db, skip={first: 5}) == second
    set_identity(db, first, generation=6)  # a writer bumped it: new work
    assert _next(db, skip={first: 5}) == first


def test_the_queue_spans_owners(db):
    other_owner = add_test_user(db, "alex")
    theirs = add_track(db, "/m/alex.flac", owner_id=other_owner, identity={"priority": 0})
    add_track(db, "/m/mine.flac", identity={"priority": 1})
    assert _next(db) == theirs


def test_worker_reads_take_any_owner_only(db):
    # SC-28 rule 3: a background worker reads by uuid with ANY_OWNER and takes
    # the owner from the row.
    uuid_id = add_track(db, "/m/1.flac")
    with pytest.raises(TypeError):
        db.next_identity_work(NOW, skip={}, owner_id=db.owner_id)
    with pytest.raises(TypeError):
        db.get_identity_subject(uuid_id, owner_id=db.owner_id)


@pytest.mark.parametrize("owner", [ANY_OWNER, None, True, "1"])
def test_the_worker_write_names_the_rows_owner(db, owner):
    # Every write names its owner (test_ownership_inventory): never ANY_OWNER.
    uuid_id = add_track(db, "/m/1.flac")
    with pytest.raises(TypeError):
        db.update_identity_if_unchanged(
            uuid_id, generation=1, file_path="/m/1.flac", values={"attempts": 1},
            owner_id=owner,
        )


# --- the subject read --------------------------------------------------------------------


def test_the_subject_read_returns_the_row_the_owner_and_the_codec(db):
    other_owner = add_test_user(db, "alex")
    uuid_id = add_track(db, "/m/alex.m4a", codec="alac", owner_id=other_owner, identity={
        "generation": 7, "exact_digest": DIGEST_A, "exact_kind": "pcm_sha256",
        "fp_state": "current", "attempts": 2,
    })
    subject = db.get_identity_subject(uuid_id, owner_id=ANY_OWNER)
    assert {k: subject[k] for k in (
        "uuid_id", "owner_id", "generation", "file_path", "codec", "exact_state",
        "exact_kind", "exact_digest", "fp_state", "attempts",
    )} == {
        "uuid_id": uuid_id, "owner_id": other_owner, "generation": 7,
        "file_path": "/m/alex.m4a", "codec": "alac", "exact_state": "pending",
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": "current",
        "attempts": 2,
    }


def test_the_subject_read_of_a_deleted_track_is_none(db):
    uuid_id = add_track(db, "/m/1.flac")
    db.delete_track(uuid_id)
    assert db.get_identity_subject(uuid_id, owner_id=ANY_OWNER) is None


# --- the CAS write -----------------------------------------------------------------------

RESULT = {
    "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A,
    "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
    "stat_size": 10, "stat_mtime_ns": 20, "stat_inode": 30,
    "computed_at": NOW, "tool_versions": "ffmpeg 9.0.2",
    "attempts": 0, "next_attempt_at": None, "failure_reason": None,
}


def _cas(db, uuid_id, *, generation=3, file_path="/m/1.flac", values=None, verify=None, owner_id=None):
    return db.update_identity_if_unchanged(
        uuid_id, generation=generation, file_path=file_path,
        values=RESULT if values is None else values, verify=verify,
        owner_id=db.owner_id if owner_id is None else owner_id,
    )


def test_an_unchanged_row_takes_the_result_and_keeps_its_generation(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 3, "attempts": 2})
    assert _cas(db, uuid_id) is True
    row = identity(db, uuid_id)
    assert {k: row[k] for k in RESULT} == RESULT
    assert row["generation"] == 3
    assert (row["match_state"], row["fp_state"], row["priority"]) == ("pending", "unavailable", 1)


def test_a_moved_generation_discards_the_result(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 4})
    before = identity(db, uuid_id)
    assert _cas(db, uuid_id, generation=3) is False
    assert identity(db, uuid_id) == before


def test_a_moved_master_path_discards_the_result(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 3})
    before = identity(db, uuid_id)
    assert _cas(db, uuid_id, file_path="/m/old.flac") is False
    assert identity(db, uuid_id) == before


def test_a_journal_row_discards_the_result(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 3})
    before = identity(db, uuid_id)
    add_journal(db, uuid_id, intent="inplace")
    assert _cas(db, uuid_id) is False
    assert identity(db, uuid_id) == before


def test_a_failed_verification_discards_the_result(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 3})
    before = identity(db, uuid_id)
    assert _cas(db, uuid_id, verify=lambda: False) is False
    assert identity(db, uuid_id) == before


def test_a_vanished_row_is_a_discard_not_an_error(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 3})
    db.delete_track(uuid_id)
    assert _cas(db, uuid_id) is False


def test_verification_runs_inside_the_write_transaction(db):
    # The second stat() must sit inside the write lock, so no writer can
    # commit between the check and the update.
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 3})
    seen = []

    def verify():
        other = sqlite3.connect(db.context.database_path, timeout=0)
        try:
            other.execute("UPDATE track_audio_identity SET priority = 0")
        except sqlite3.OperationalError as e:
            seen.append(str(e))
        finally:
            other.close()
        return True

    assert _cas(db, uuid_id, verify=verify) is True
    assert seen and "locked" in seen[0]


@pytest.mark.parametrize("column", [
    "generation", "uuid_id", "match_state", "matcher_version", "priority", "fp_algorithm",
    "exact_state = 'current', priority",
])
def test_only_worker_columns_can_be_written(db, column):
    uuid_id = add_track(db, "/m/1.flac", identity={"generation": 3})
    before = identity(db, uuid_id)
    with pytest.raises(ValueError):
        _cas(db, uuid_id, values={column: 0})
    assert identity(db, uuid_id) == before


def test_the_cas_write_with_another_owner_changes_nothing(db):
    other_owner = add_test_user(db, "alex")
    theirs = add_track(db, "/m/1.flac", owner_id=other_owner, identity={"generation": 3})
    before = identity(db, theirs)
    assert _cas(db, theirs, owner_id=db.owner_id) is False
    assert identity(db, theirs) == before


def test_the_cas_write_leaves_other_owners_rows_alone(db):
    other_owner = add_test_user(db, "alex")
    mine = add_track(db, "/m/1.flac", identity={"generation": 3})
    theirs = add_track(db, "/m/alex/1.flac", owner_id=other_owner, identity={"generation": 3})
    before = identity(db, theirs)
    assert _cas(db, mine) is True
    assert identity(db, theirs) == before
    assert sql(db, "SELECT count(*) AS n FROM track_audio_identity WHERE exact_state = 'current'")[0]["n"] == 1
