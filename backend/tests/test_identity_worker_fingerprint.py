"""Phase 6.5B.1b: the worker computes the fingerprint layer (spec §4.2, §6.4
"Computation", "Write (CAS)"; review 6.5-U06, 6.5-U07; coordinator decisions
on empty prints, an unknown duration (DEV-6.5-08) and re-matching).

One row per step, in this order: a pending exact layer first, then a pending
fingerprint (once the exact layer is current or unsupported), then matching.
A fingerprint reaching ``current`` sends matching back to pending in the same
transaction, so a new track is matched once, after its print exists. A fake
fingerprinter returns scripted prints; the classification is the real one.
"""

import struct

import pytest

from app.services.fingerprinter import FingerprintFailure, RawFingerprint
from tests.identity_worker_fakes import (
    FLAT_ITEMS,
    TOOLS,
    VARIED_ITEMS,
    FakeCompute,
    FakeFingerprinter,
    bytes_digest,
    make_worker,
)
from tests.identity_worker_fixtures import add_journal, add_track, identity, set_identity, sql
from tests.owned_database import add_test_user

VARIED_BLOB = struct.pack("<200I", *VARIED_ITEMS)
FLAT_BLOB = struct.pack("<200I", *FLAT_ITEMS)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _file(music, name="a.flac", content=b"audio bytes"):
    path = music / name
    path.write_bytes(content)
    return path


def _settled(db, path, **values):
    """A track whose exact layer is current and whose fingerprint is pending."""
    row = {"exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path),
           "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
           "fp_state": "pending", "match_state": "current", "generation": 2}
    row.update(values)
    return add_track(db, path, identity=row)


def _fingerprint_row(db, uuid_id):
    rows = sql(db, "SELECT backend, algorithm, duration_s, item_count, data FROM track_audio_fingerprint "
                   "WHERE uuid_id = ?", (uuid_id,))
    return rows[0] if rows else None


def _worker(db, fp=None, **kwargs):
    return make_worker(db, fingerprinter=fp if fp is not None else FakeFingerprinter(), **kwargs)


# --- a computed print ----------------------------------------------------------------------------


def test_a_pending_fingerprint_is_computed_stored_and_re_queues_matching(db, music):
    path = _file(music)
    uuid_id = _settled(db, path)
    fp = FakeFingerprinter()
    worker = _worker(db, fp)

    worker.process_one()

    row = identity(db, uuid_id)
    assert (row["fp_state"], row["fp_algorithm"], row["match_state"]) == ("current", "chromaprint-2", "pending")
    assert (row["attempts"], row["next_attempt_at"], row["failure_reason"]) == (0, None, None)
    assert (row["exact_state"], row["exact_digest"], row["generation"]) == ("current", bytes_digest(path), 2)
    assert _fingerprint_row(db, uuid_id) == {
        "backend": "fakeprint", "algorithm": "chromaprint-2", "duration_s": 30.0, "item_count": 200,
        "data": VARIED_BLOB,
    }
    [call] = fp.calls
    assert (call["path"], call["low_priority"], call["registry"]) == (str(path), True, worker.registry)
    assert call["job_id"] is not None


def test_a_low_information_print_is_stored_without_re_queueing_matching(db, music):
    uuid_id = _settled(db, _file(music))
    fp = FakeFingerprinter()
    fp.results.append(RawFingerprint(FLAT_ITEMS, 30.0))
    _worker(db, fp).process_one()

    row = identity(db, uuid_id)
    assert (row["fp_state"], row["fp_algorithm"], row["match_state"]) == (
        "low_information", "chromaprint-2", "current")
    assert _fingerprint_row(db, uuid_id)["data"] == FLAT_BLOB


@pytest.mark.parametrize("result", [
    RawFingerprint(VARIED_ITEMS[:50], 7.0), FingerprintFailure("empty_fingerprint"),
], ids=["few-items", "empty"])
def test_a_too_short_print_stores_no_blob_and_is_final(db, music, result):
    uuid_id = _settled(db, _file(music))
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', 'chromaprint-1', 9.0, 1, x'00000000')", (uuid_id,))
    fp = FakeFingerprinter()
    fp.results.append(result)
    worker = _worker(db, fp)

    worker.process_one()
    later = worker.process_one()

    row = identity(db, uuid_id)
    assert (row["fp_state"], row["fp_algorithm"], row["attempts"]) == ("too_short", "chromaprint-2", 0)
    assert _fingerprint_row(db, uuid_id) is None
    assert len(fp.calls) == 1 and later.outcome == "idle"


def test_an_unknown_tool_duration_stores_the_tracks_known_duration(db, music):
    uuid_id = _settled(db, _file(music))
    sql(db, "UPDATE trackmetadata SET duration = 45.25 WHERE uuid_id = ?", (uuid_id,))
    fp = FakeFingerprinter()
    fp.results.append(RawFingerprint(VARIED_ITEMS, None))
    _worker(db, fp).process_one()
    assert _fingerprint_row(db, uuid_id)["duration_s"] == 45.25
    assert identity(db, uuid_id)["fp_state"] == "current"


def test_an_unsupported_exact_layer_still_gets_a_fingerprint(db, music):
    path = _file(music, "a.opus")
    uuid_id = add_track(db, path, codec="opus", identity={
        "exact_state": "unsupported", "fp_state": "pending", "match_state": "current"})
    _worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == "current"


def test_the_written_tool_versions_are_the_workers(db, music):
    uuid_id = _settled(db, _file(music), tool_versions="ffmpeg 8.0")
    _worker(db).process_one()
    assert identity(db, uuid_id)["tool_versions"] == TOOLS


def test_a_track_of_another_owner_is_fingerprinted_under_its_owner(db, music):
    other = add_test_user(db, "alex")
    path = _file(music)
    uuid_id = add_track(db, path, owner_id=other, identity={
        "exact_state": "current", "exact_digest": bytes_digest(path), "fp_state": "pending",
        "match_state": "current"})
    _worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == "current"
    assert _fingerprint_row(db, uuid_id) is not None


# --- step order -------------------------------------------------------------------------------------


def test_a_new_track_is_hashed_then_fingerprinted_then_matched_once(db, music):
    path = _file(music)
    uuid_id = add_track(db, path, identity={"fp_state": "pending", "priority": 0})
    compute, fp = FakeCompute(), FakeFingerprinter()
    worker = _worker(db, fp, compute=compute)

    outcomes = [worker.process_one().outcome for _ in range(4)]

    assert outcomes == ["written", "written", "matched", "idle"]
    assert (len(compute.calls), len(fp.calls)) == (1, 1)
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["fp_state"], row["match_state"]) == ("current", "current", "current")


def test_the_exact_step_never_runs_the_fingerprinter(db, music):
    add_track(db, _file(music), identity={"fp_state": "pending", "match_state": "pending"})
    fp = FakeFingerprinter()
    _worker(db, fp).process_one()
    assert fp.calls == []


def test_without_a_fingerprinter_a_pending_print_is_never_computed(db, music):
    uuid_id = _settled(db, _file(music))
    worker = make_worker(db)
    result = worker.process_one()
    assert result.outcome == "idle" and result.delay_s > 0
    assert identity(db, uuid_id)["fp_state"] == "pending"


def test_matching_does_not_wait_for_a_print_in_backoff(db, music):
    uuid_id = _settled(db, _file(music), match_state="pending", attempts=1,
                       next_attempt_at=10**10, failure_reason="timeout")
    fp = FakeFingerprinter()
    assert _worker(db, fp).process_one().outcome == "matched"
    assert fp.calls == []
    assert identity(db, uuid_id)["match_state"] == "current"


# --- the CAS fences the fingerprint write -------------------------------------------------------------


def test_a_writer_mid_fingerprint_discards_the_print(db, music):
    path = _file(music)
    uuid_id = _settled(db, path)
    fp = FakeFingerprinter()
    fp.mid = lambda: set_identity(db, uuid_id, generation=3, fp_state="pending")  # a stale mark
    worker = _worker(db, fp)

    assert worker.process_one().outcome == "discarded"
    assert identity(db, uuid_id)["fp_state"] == "pending" and _fingerprint_row(db, uuid_id) is None

    worker.process_one()  # recomputed for the new generation
    assert identity(db, uuid_id)["fp_state"] == "current" and len(fp.calls) == 2


def test_a_journal_row_mid_fingerprint_discards_the_print(db, music):
    uuid_id = _settled(db, _file(music))
    fp = FakeFingerprinter()
    fp.mid = lambda: add_journal(db, uuid_id)
    assert _worker(db, fp).process_one().outcome == "discarded"
    assert identity(db, uuid_id)["fp_state"] == "pending" and _fingerprint_row(db, uuid_id) is None


def test_bytes_replaced_mid_fingerprint_discard_the_print(db, music):
    path = _file(music)
    uuid_id = _settled(db, path)
    fp = FakeFingerprinter()
    fp.mid = lambda: path.write_bytes(b"other, longer audio bytes")
    assert _worker(db, fp).process_one().outcome == "discarded"
    assert identity(db, uuid_id)["fp_state"] == "pending" and _fingerprint_row(db, uuid_id) is None
