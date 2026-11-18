"""Phase 6.5B.1b: the fingerprint layer in the identity queue (spec §6.4 "Queue";
review 6.5-U06; coordinator decisions on matching and the fingerprint layer).

Layer ownership of the row's single attempts / next_attempt_at columns:
while the exact layer is pending they are the exact layer's; once it is
settled (current or unsupported) they are the fingerprint layer's. So:

- fingerprint work is queued only when the worker has a fingerprinter
  (``fingerprint=True``), the exact layer is current or unsupported, and the
  row is due;
- a failed exact layer (the file could not be read) holds its own failure
  in those columns, and the fingerprint waits for the exact layer to be
  revived; it is never queued (no spin);
- matching is never held back by a fingerprint backoff.
"""

import pytest

from app.database import ANY_OWNER
from tests.identity_worker_fixtures import add_journal, add_track, sql

NOW = 1_800_000_000


def _next(db, now=NOW, *, fingerprint=True, skip=None):
    return db.next_identity_work(now, skip=skip or {}, owner_id=ANY_OWNER, fingerprint=fingerprint)


@pytest.mark.parametrize("exact", ["current", "unsupported"])
def test_a_pending_fingerprint_of_a_settled_track_is_work_with_a_fingerprinter(db, exact):
    uuid_id = add_track(db, "/m/1.flac", identity={
        "exact_state": exact, "fp_state": "pending", "match_state": "current"})
    assert _next(db) == uuid_id


def test_without_a_fingerprinter_a_pending_fingerprint_is_not_work(db):
    add_track(db, "/m/1.flac", identity={"exact_state": "current", "fp_state": "pending", "match_state": "current"})
    assert _next(db, fingerprint=False) is None


def test_a_pending_fingerprint_waits_for_its_exact_layer_to_be_settled(db):
    add_track(db, "/m/1.flac", identity={
        "exact_state": "pending", "fp_state": "pending", "match_state": "pending",
        "next_attempt_at": NOW + 60, "attempts": 1})
    assert _next(db) is None


def test_a_failed_exact_layer_never_queues_its_fingerprint(db):
    add_track(db, "/m/1.flac", identity={
        "exact_state": "failed", "fp_state": "pending", "match_state": "current",
        "attempts": 3, "failure_reason": "decode_error"})
    assert _next(db) is None
    assert _next(db, NOW + 10**7) is None


def test_a_fingerprint_in_backoff_waits_until_it_is_due(db):
    uuid_id = add_track(db, "/m/1.flac", identity={
        "exact_state": "current", "fp_state": "pending", "match_state": "current",
        "attempts": 1, "next_attempt_at": NOW + 60})
    assert _next(db, NOW + 59) is None
    assert _next(db, NOW + 60) == uuid_id


@pytest.mark.parametrize("fingerprint", [True, False])
def test_a_fingerprint_backoff_never_holds_back_matching(db, fingerprint):
    uuid_id = add_track(db, "/m/1.flac", identity={
        "exact_state": "current", "fp_state": "pending", "match_state": "pending",
        "attempts": 2, "next_attempt_at": NOW + 3600})
    assert _next(db, fingerprint=fingerprint) == uuid_id


def test_an_exact_backoff_still_holds_back_its_match(db):
    add_track(db, "/m/1.flac", identity={
        "exact_state": "pending", "fp_state": "unavailable", "match_state": "pending",
        "attempts": 1, "next_attempt_at": NOW + 60})
    assert _next(db) is None


@pytest.mark.parametrize("fp_state", ["current", "too_short", "low_information", "failed", "unavailable"])
def test_a_settled_fingerprint_is_not_work(db, fp_state):
    add_track(db, "/m/1.flac", identity={"exact_state": "current", "fp_state": fp_state, "match_state": "current"})
    assert _next(db) is None


def test_fingerprint_work_with_a_file_operation_in_flight_is_skipped(db):
    uuid_id = add_track(db, "/m/1.flac", identity={
        "exact_state": "current", "fp_state": "pending", "match_state": "current"})
    add_journal(db, uuid_id)
    assert _next(db) is None


def test_fingerprint_work_follows_priority_then_row_order(db):
    backfill = add_track(db, "/m/1.flac", identity={
        "exact_state": "current", "fp_state": "pending", "match_state": "current", "priority": 1})
    new = add_track(db, "/m/2.flac", identity={"priority": 0})
    assert _next(db) == new
    sql(db, "UPDATE track_audio_identity SET exact_state = 'current', match_state = 'current', "
            "fp_state = 'too_short' WHERE uuid_id = ?", (new,))
    assert _next(db) == backfill


# --- the subject read gives the fingerprint step what it needs ----------------------------------


def test_the_subject_read_has_the_fingerprint_columns_and_the_known_duration(db):
    uuid_id = add_track(db, "/m/1.flac", identity={
        "exact_state": "current", "fp_state": "pending", "fp_algorithm": "chromaprint-1",
        "next_attempt_at": NOW - 5})
    sql(db, "UPDATE trackmetadata SET duration = 183.5 WHERE uuid_id = ?", (uuid_id,))
    subject = db.get_identity_subject(uuid_id, owner_id=ANY_OWNER)
    assert (subject["fp_state"], subject["fp_algorithm"], subject["next_attempt_at"], subject["duration"]) == (
        "pending", "chromaprint-1", NOW - 5, 183.5)


def test_an_unknown_duration_reads_as_none(db):
    uuid_id = add_track(db, "/m/1.flac")
    assert db.get_identity_subject(uuid_id, owner_id=ANY_OWNER)["duration"] is None
