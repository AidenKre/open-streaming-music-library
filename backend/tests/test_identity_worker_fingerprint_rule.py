"""Phase 6.5B.1b: "exact unchanged keeps the fingerprint" can never keep a print
for audio that did change (spec §6.4 "Computation"; review 6.5-U06).

A stored print (current, too_short, low_information) is kept only when the
kept digest and the new digest are both known and equal. Without that proof
(no new digest because the codec is unsupported, or a changed digest) it is
sent back to pending: unknown is not "unchanged". A ``failed`` print is not a
print to keep: a successful exact compute retries it.

When the exact layer finally fails the file cannot be read, so the print is
marked ``failed`` too (with the algorithm, blob removed) instead of waiting
forever as ``pending``; reviving the exact layer retries it. A print the
worker cannot compute (``unavailable``) stays unavailable.
"""

import pytest

from app.services.audio_identity import ExactUnavailable
from tests.identity_worker_fakes import FakeClock, FakeCompute, FakeFingerprinter, bytes_digest, make_worker
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, make_db, sql


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _file(music, name="a.flac", content=b"audio bytes"):
    path = music / name
    path.write_bytes(content)
    return path


SETTLED = ["current", "too_short", "low_information", "failed"]
STORED = ["current", "too_short", "low_information"]


@pytest.mark.parametrize("fp_state", STORED)
def test_an_equal_digest_keeps_a_stored_print(db, music, fp_state):
    path = _file(music)
    uuid_id = add_track(db, path, identity={
        "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path), "fp_state": fp_state,
        "fp_algorithm": "chromaprint-2"})
    make_worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == fp_state


def test_an_equal_digest_retries_a_failed_print(db, music):
    path = _file(music)
    uuid_id = add_track(db, path, identity={
        "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path), "fp_state": "failed",
        "fp_algorithm": "chromaprint-2"})
    make_worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == "pending"


@pytest.mark.parametrize("fp_state", SETTLED)
def test_a_changed_digest_re_pends_a_settled_print(db, music, fp_state):
    uuid_id = add_track(db, _file(music), identity={
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": fp_state})
    make_worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == "pending"


@pytest.mark.parametrize("fp_state", SETTLED)
def test_no_kept_digest_re_pends_a_settled_print(db, music, fp_state):
    uuid_id = add_track(db, _file(music), identity={"exact_digest": None, "fp_state": fp_state})
    make_worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == "pending"


@pytest.mark.parametrize("fp_state", SETTLED)
def test_an_unsupported_result_cannot_prove_the_audio_unchanged(db, music, fp_state):
    uuid_id = add_track(db, _file(music, "a.opus"), codec="opus", identity={
        "exact_digest": None, "fp_state": fp_state, "fp_algorithm": "chromaprint-2"})
    compute = FakeCompute()
    compute.results.append(ExactUnavailable("unsupported", None))
    make_worker(db, compute=compute).process_one()
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["fp_state"], row["match_state"]) == ("unsupported", "pending", "pending")


@pytest.mark.parametrize("fp_state", ["pending", *SETTLED])
def test_a_finally_failed_exact_layer_fails_the_print_too(db, music, fp_state):
    uuid_id = add_track(db, _file(music), identity={
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": fp_state, "attempts": 3})
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', 'chromaprint-1', 9.0, 1, x'00000000')", (uuid_id,))
    compute = FakeCompute()
    compute.results.append(ExactUnavailable("failed", "decode_error"))
    fp = FakeFingerprinter()
    make_worker(db, compute=compute, fingerprinter=fp).process_one()
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["attempts"], row["failure_reason"]) == ("failed", 4, "decode_error")
    assert (row["fp_state"], row["fp_algorithm"], row["match_state"]) == ("failed", "chromaprint-2", "pending")
    assert sql(db, "SELECT 1 FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,)) == []
    assert fp.calls == []  # nothing was fingerprinted: the file could not be read


def test_a_failed_exact_layer_revived_retries_its_failed_print(db, music):
    # e.g. the reconcile reset it after a tool upgrade: the exact layer comes
    # back pending with its attempts reset, and a good hash re-queues the print.
    path = _file(music)
    uuid_id = add_track(db, path, identity={
        "exact_state": "pending", "exact_digest": None, "fp_state": "failed", "fp_algorithm": "chromaprint-2"})
    fp = FakeFingerprinter()
    worker = make_worker(db, fingerprinter=fp)
    worker.process_one()
    assert identity(db, uuid_id)["fp_state"] == "pending"
    worker.process_one()
    assert identity(db, uuid_id)["fp_state"] == "current" and len(fp.calls) == 1


@pytest.mark.parametrize("fp_state", SETTLED)
def test_an_exact_attempt_in_backoff_leaves_the_print_alone(db, music, fp_state):
    # Stale-but-safe until the exact layer settles, like the kept digest.
    uuid_id = add_track(db, _file(music), identity={
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": fp_state})
    compute = FakeCompute()
    compute.results.append(ExactUnavailable("failed", "timeout"))
    make_worker(db, clock=FakeClock(), compute=compute).process_one()
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["attempts"], row["fp_state"]) == ("pending", 1, fp_state)


@pytest.mark.parametrize("case", ["unsupported", "final-failure", "changed"])
def test_an_unavailable_print_stays_unavailable(db, music, case):
    uuid_id = add_track(db, _file(music), identity={
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": "unavailable", "attempts": 3})
    compute = FakeCompute()
    if case == "unsupported":
        compute.results.append(ExactUnavailable("unsupported", None))
    elif case == "final-failure":
        compute.results.append(ExactUnavailable("failed", "decode_error"))
    make_worker(db, compute=compute).process_one()
    assert identity(db, uuid_id)["fp_state"] == "unavailable"


def test_without_a_fingerprinter_a_final_exact_failure_leaves_a_failed_print_failed(db, music):
    # F5: re-pending it would only strand it (nothing computes it).
    uuid_id = add_track(db, _file(music), identity={
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": "failed",
        "fp_algorithm": "chromaprint-2", "attempts": 3})
    compute = FakeCompute()
    compute.results.append(ExactUnavailable("failed", "decode_error"))
    make_worker(db, compute=compute).process_one()
    assert (identity(db, uuid_id)["exact_state"], identity(db, uuid_id)["fp_state"]) == ("failed", "failed")
