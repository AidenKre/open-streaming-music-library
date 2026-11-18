"""Phase 6.5B.1b: the worker's fingerprint write and the queue's fingerprint work
(spec §4.2, §6.1 ``track_audio_fingerprint``, §6.4 "Write (CAS)" and "Queue";
review 6.5-U06; coordinator decision "matching and the fingerprint layer").

The fingerprint write rides the existing CAS (generation, owner, master path,
no edit_journal row, a second equal stat inside the transaction). The
identity row's fingerprint columns and the fingerprint row are written in the
same transaction, and a print reaching ``current`` sends matching back to
pending. Rows are read with plain SQL.
"""

import sqlite3
import struct

import pytest

from tests.identity_worker_fixtures import add_journal, add_track, identity, sql
from tests.owned_database import add_test_user

NOW = 1_800_000_000
ITEMS = tuple(i << 18 for i in range(200))
BLOB = struct.pack("<200I", *ITEMS)
OLD_BLOB = struct.pack("<3I", 1, 2, 3)

ATTEMPT_RESET = {"attempts": 0, "next_attempt_at": None, "failure_reason": None}


def _fp(state="current", *, duration=30.0, data=BLOB, items=200, algorithm="chromaprint-2"):
    if state in ("too_short", "failed"):
        duration = data = items = None
    return {"fp_state": state, "fp_algorithm": algorithm, "fp_backend": "fpcalc",
            "fp_duration_s": duration, "fp_item_count": items, "fp_data": data}


def _track(db, *, owner_id=None, **identity_values):
    values = {"generation": 3, "exact_state": "current", "exact_digest": "aa" * 32,
              "exact_kind": "pcm_sha256", "fp_state": "pending", "match_state": "current"}
    values.update(identity_values)
    return add_track(db, "/m/1.flac", owner_id=owner_id, identity=values)


def _put_fingerprint(db, uuid_id, data=OLD_BLOB):
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', 'chromaprint-1', 12.0, 3, ?)", (uuid_id, data))


def _fingerprint_row(db, uuid_id):
    rows = sql(db, "SELECT backend, algorithm, duration_s, item_count, data FROM track_audio_fingerprint "
                   "WHERE uuid_id = ?", (uuid_id,))
    return rows[0] if rows else None


def _cas(db, uuid_id, fingerprint, *, generation=3, file_path="/m/1.flac", verify=None, owner_id=None,
         values=None):
    return db.update_identity_if_unchanged(
        uuid_id, generation=generation, file_path=file_path,
        values=ATTEMPT_RESET if values is None else values, verify=verify,
        owner_id=db.owner_id if owner_id is None else owner_id, fingerprint=fingerprint,
    )


# --- a written print -------------------------------------------------------------------------------


def test_a_current_print_writes_both_rows_and_re_queues_matching(db):
    uuid_id = _track(db, attempts=2, failure_reason="timeout")
    assert _cas(db, uuid_id, _fp("current")) is True

    row = identity(db, uuid_id)
    assert (row["fp_state"], row["fp_algorithm"], row["match_state"]) == ("current", "chromaprint-2", "pending")
    assert (row["attempts"], row["failure_reason"], row["generation"]) == (0, None, 3)
    assert _fingerprint_row(db, uuid_id) == {
        "backend": "fpcalc", "algorithm": "chromaprint-2", "duration_s": 30.0, "item_count": 200, "data": BLOB,
    }


def test_a_recomputed_print_replaces_the_old_row(db):
    uuid_id = _track(db)
    _put_fingerprint(db, uuid_id)
    assert _cas(db, uuid_id, _fp("current")) is True
    assert _fingerprint_row(db, uuid_id)["data"] == BLOB


def test_a_low_information_print_is_stored_but_does_not_re_queue_matching(db):
    # Matching never uses it; only reaching or leaving 'current' re-queues.
    uuid_id = _track(db)
    assert _cas(db, uuid_id, _fp("low_information")) is True
    row = identity(db, uuid_id)
    assert (row["fp_state"], row["match_state"]) == ("low_information", "current")
    assert _fingerprint_row(db, uuid_id)["data"] == BLOB


@pytest.mark.parametrize("state", ["too_short", "failed"])
def test_a_print_with_no_blob_stores_none_and_removes_an_old_one(db, state):
    uuid_id = _track(db)
    _put_fingerprint(db, uuid_id)
    assert _cas(db, uuid_id, _fp(state)) is True
    row = identity(db, uuid_id)
    assert (row["fp_state"], row["fp_algorithm"], row["match_state"]) == (state, "chromaprint-2", "current")
    assert _fingerprint_row(db, uuid_id) is None


@pytest.mark.parametrize("state", ["pending", "unavailable", "bogus"])
def test_only_a_final_fingerprint_state_can_be_written(db, state):
    uuid_id = _track(db)
    before = identity(db, uuid_id)
    with pytest.raises(ValueError):
        _cas(db, uuid_id, {**_fp("too_short"), "fp_state": state})
    assert identity(db, uuid_id) == before


@pytest.mark.parametrize("change", [
    {"fp_data": None}, {"fp_duration_s": None}, {"fp_duration_s": 0.0}, {"fp_algorithm": None},
], ids=["no-blob", "no-duration", "zero-duration", "no-algorithm"])
def test_a_malformed_print_changes_neither_row(db, change):
    uuid_id = _track(db)
    _put_fingerprint(db, uuid_id)
    before = identity(db, uuid_id)
    with pytest.raises((ValueError, sqlite3.IntegrityError)):
        _cas(db, uuid_id, {**_fp("current"), **change})
    assert identity(db, uuid_id) == before
    assert _fingerprint_row(db, uuid_id)["data"] == OLD_BLOB


def test_the_fingerprint_row_fails_the_whole_write(db, monkeypatch):
    # One transaction: if the fingerprint row cannot be written, the identity
    # row keeps its old state too. A trigger stands in for any failure there.
    uuid_id = _track(db)
    before = identity(db, uuid_id)
    sql(db, "CREATE TRIGGER no_fp BEFORE INSERT ON track_audio_fingerprint "
            "BEGIN SELECT RAISE(ABORT, 'nope'); END")
    with pytest.raises(sqlite3.DatabaseError):
        _cas(db, uuid_id, _fp("current"))
    assert identity(db, uuid_id) == before


# --- the CAS also fences the fingerprint ------------------------------------------------------------


@pytest.mark.parametrize("refusal", ["generation", "path", "journal", "verify", "owner"])
def test_a_refused_write_changes_neither_row(db, refusal):
    other = add_test_user(db, "alex")
    uuid_id = _track(db)
    _put_fingerprint(db, uuid_id)
    kwargs = {}
    if refusal == "generation":
        kwargs["generation"] = 2
    elif refusal == "path":
        kwargs["file_path"] = "/m/old.flac"
    elif refusal == "journal":
        add_journal(db, uuid_id)
    elif refusal == "verify":
        kwargs["verify"] = lambda: False
    else:
        kwargs["owner_id"] = other
    before = identity(db, uuid_id)

    assert _cas(db, uuid_id, _fp("current"), **kwargs) is False
    assert identity(db, uuid_id) == before
    assert _fingerprint_row(db, uuid_id)["data"] == OLD_BLOB


def test_without_a_fingerprint_argument_the_fingerprint_row_is_untouched(db):
    uuid_id = _track(db)
    _put_fingerprint(db, uuid_id)
    assert db.update_identity_if_unchanged(
        uuid_id, generation=3, file_path="/m/1.flac", values=ATTEMPT_RESET, owner_id=db.owner_id,
    ) is True
    assert _fingerprint_row(db, uuid_id)["data"] == OLD_BLOB
    assert identity(db, uuid_id)["fp_state"] == "pending"


# --- the insert primitive stores a carried print (SC-25 seam for Phase 7) ---------------------------

from app.database.database import Database  # noqa: E402
from app.services.audio_identity import (  # noqa: E402
    KIND_PCM,
    AudioIdentity,
    ExactAudioHash,
    FingerprintIdentity,
    FingerprintUnavailable,
)


def _staged(fingerprint):
    return AudioIdentity(exact=ExactAudioHash(KIND_PCM, "cc" * 32, 44100, 2, 16),
                         tool_versions="ffmpeg 9.0.2; fpcalc 1.6.2", computed_at=NOW, fingerprint=fingerprint)


def _insert(db, uuid_id, identity_value, *, present):
    with db._connection(commit=True) as conn:
        Database._insert_audio_identity_in(conn, uuid_id, identity_value, fingerprinter_present=present)


@pytest.mark.parametrize("present", [True, False])
def test_an_insert_with_a_computed_print_stores_it_as_is(db, present):
    uuid_id = add_track(db, "/m/1.flac", identity={"_none": True})
    _insert(db, uuid_id, _staged(FingerprintIdentity("current", "fpcalc", "chromaprint-2", 30.0, ITEMS)),
            present=present)
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["fp_state"], row["fp_algorithm"], row["match_state"]) == (
        "current", "current", "chromaprint-2", "pending")
    assert _fingerprint_row(db, uuid_id) == {
        "backend": "fpcalc", "algorithm": "chromaprint-2", "duration_s": 30.0, "item_count": 200, "data": BLOB}


def test_an_insert_with_a_too_short_print_stores_no_blob(db):
    uuid_id = add_track(db, "/m/1.flac", identity={"_none": True})
    _insert(db, uuid_id, _staged(FingerprintIdentity("too_short", "fpcalc", "chromaprint-2", None, ())),
            present=True)
    assert (identity(db, uuid_id)["fp_state"], _fingerprint_row(db, uuid_id)) == ("too_short", None)


@pytest.mark.parametrize("fingerprint", [None, FingerprintUnavailable("timeout")])
@pytest.mark.parametrize("present, expected", [(True, "pending"), (False, "unavailable")])
def test_an_insert_without_a_computed_print_follows_the_fingerprinter_flag(db, fingerprint, present, expected):
    uuid_id = add_track(db, "/m/1.flac", identity={"_none": True})
    _insert(db, uuid_id, _staged(fingerprint), present=present)
    assert (identity(db, uuid_id)["fp_state"], identity(db, uuid_id)["fp_algorithm"]) == (expected, None)
    assert _fingerprint_row(db, uuid_id) is None


def test_the_conversion_writer_ignores_a_carried_print_and_keeps_its_rule(db):
    # A conversion computes no print; even if an identity carried one, the
    # conversion writer's own rule (keep when the audio is unchanged) decides.
    uuid_id = _track(db, fp_state="current", fp_algorithm="chromaprint-2")
    _put_fingerprint(db, uuid_id)
    with db._connection(commit=True) as conn:
        assert Database._write_conversion_identity_in(
            conn, uuid_id, _staged(FingerprintIdentity("low_information", "fpcalc", "chromaprint-2", 3.0, ITEMS)),
            audio_unchanged=True)
    assert (identity(db, uuid_id)["fp_state"], _fingerprint_row(db, uuid_id)["data"]) == ("current", OLD_BLOB)
