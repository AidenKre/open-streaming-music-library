"""Phase 6.5B.1b: the startup reconcile's fingerprint transitions (spec §6.4
"Startup reconcile step", §4.2; review 6.5-U06).

- With a fingerprinter, ``unavailable`` becomes ``pending``; without one,
  ``pending`` becomes ``unavailable``. Stored prints (``current`` etc.) are
  kept either way, so tool present / absent / present never flaps them.
- A different active algorithm re-queues every non-pending print, including
  ``too_short``, ``low_information`` and ``failed``; a version-only change does
  not. A ``current`` print leaving ``current`` re-queues matching.
- A failed print is retried when the tool versions changed (with a
  fingerprinter), and a print that failed for a missing master is retried
  once the master is back.
- The row's attempts / next_attempt_at / failure_reason belong to the
  fingerprint only while the exact layer is current or unsupported; while the
  exact layer is pending or failed they are the exact layer's and are kept.
- Every transition is idempotent: a second run changes nothing.
"""

import pytest

from app.database import ANY_OWNER
from app.services.identity_worker import reconcile_audio_identity
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, sql

TOOLS = "ffmpeg 9.0.2; fpcalc 1.6.2"
ALG = "chromaprint-2"
EXACT_CURRENT = {"exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A,
                 "match_state": "current", "tool_versions": TOOLS}


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _reconcile(db, *, present, algorithm=ALG, tools=TOOLS, **kwargs):
    reconcile_audio_identity(
        db, tool_versions=tools, fingerprinter_present=present,
        fingerprint_algorithm=algorithm if present else None, **kwargs,
    )


def _table(db):
    return sql(db, "SELECT * FROM track_audio_identity ORDER BY uuid_id")


def _twice(db, **kwargs):
    """Run the reconcile twice; the second run must change nothing."""
    _reconcile(db, **kwargs)
    once = _table(db)
    _reconcile(db, **kwargs)
    assert _table(db) == once


def _cols(db, uuid_id, *names):
    row = identity(db, uuid_id)
    return tuple(row[n] for n in names)


# --- tool appears / disappears ---------------------------------------------------------------------------


def test_a_fingerprinter_appearing_queues_every_unavailable_print(db):
    settled = add_track(db, "/m/a.flac", identity={**EXACT_CURRENT, "fp_state": "unavailable"})
    hashing = add_track(db, "/m/b.flac", identity={
        "exact_state": "pending", "fp_state": "unavailable", "attempts": 1, "next_attempt_at": 123,
        "failure_reason": "timeout"})
    kept = add_track(db, "/m/c.flac", identity={**EXACT_CURRENT, "fp_state": "current", "fp_algorithm": ALG})

    _twice(db, present=True)

    assert _cols(db, settled, "fp_state", "match_state") == ("pending", "current")
    # The exact layer's attempt columns are not the fingerprint's to touch.
    assert _cols(db, hashing, "fp_state", "attempts", "next_attempt_at", "failure_reason") == (
        "pending", 1, 123, "timeout")
    assert _cols(db, kept, "fp_state") == ("current",)


def test_a_fingerprinter_disappearing_parks_every_pending_print(db):
    backing_off = add_track(db, "/m/a.flac", identity={
        **EXACT_CURRENT, "fp_state": "pending", "attempts": 2, "next_attempt_at": 9_999_999_999,
        "failure_reason": "timeout"})
    hashing = add_track(db, "/m/b.flac", identity={
        "exact_state": "pending", "fp_state": "pending", "attempts": 1, "next_attempt_at": 123,
        "failure_reason": "decode_error"})
    unreadable = add_track(db, "/m/c.flac", identity={
        "exact_state": "failed", "fp_state": "pending", "attempts": 3, "failure_reason": "decode_error",
        "match_state": "current", "tool_versions": TOOLS})
    kept = {state: add_track(db, f"/m/{state}.flac", identity={
        **EXACT_CURRENT, "fp_state": state, "fp_algorithm": ALG})
        for state in ("current", "too_short", "low_information", "failed")}

    _twice(db, present=False)

    # The fingerprint's own backoff goes with it; nothing is left due or pending.
    assert _cols(db, backing_off, "fp_state", "attempts", "next_attempt_at", "failure_reason") == (
        "unavailable", 0, None, None)
    assert _cols(db, hashing, "fp_state", "attempts", "next_attempt_at", "failure_reason") == (
        "unavailable", 1, 123, "decode_error")
    assert _cols(db, unreadable, "fp_state", "attempts", "failure_reason") == ("unavailable", 3, "decode_error")
    assert {s: identity(db, u)["fp_state"] for s, u in kept.items()} == {s: s for s in kept}


def test_present_absent_present_does_not_flap_a_library(db):
    rows = {
        "pending": add_track(db, "/m/a.flac", identity={**EXACT_CURRENT, "fp_state": "pending"}),
        "current": add_track(db, "/m/b.flac", identity={**EXACT_CURRENT, "fp_state": "current", "fp_algorithm": ALG}),
        "too_short": add_track(db, "/m/c.flac", identity={**EXACT_CURRENT, "fp_state": "too_short", "fp_algorithm": ALG}),
    }
    start = _table(db)

    _reconcile(db, present=True)
    assert _table(db) == start
    _reconcile(db, present=False)
    assert identity(db, rows["pending"])["fp_state"] == "unavailable"
    assert identity(db, rows["current"])["fp_state"] == "current"
    _reconcile(db, present=True)
    assert _table(db) == start


# --- algorithm change --------------------------------------------------------------------------------------


@pytest.mark.parametrize("state", ["current", "too_short", "low_information", "failed"])
def test_a_new_algorithm_re_queues_every_settled_print(db, state):
    uuid_id = add_track(db, "/m/a.flac", identity={
        **EXACT_CURRENT, "fp_state": state, "fp_algorithm": "chromaprint-1",
        "attempts": 3 if state == "failed" else 0, "failure_reason": "decode_error" if state == "failed" else None})

    _twice(db, present=True)

    assert _cols(db, uuid_id, "fp_state", "attempts", "next_attempt_at", "failure_reason") == (
        "pending", 0, None, None)
    # Only a print leaving 'current' re-queues matching.
    assert identity(db, uuid_id)["match_state"] == ("pending" if state == "current" else "current")
    assert identity(db, uuid_id)["exact_state"] == "current"


def test_a_settled_print_with_no_recorded_algorithm_is_re_queued(db):
    uuid_id = add_track(db, "/m/a.flac", identity={**EXACT_CURRENT, "fp_state": "low_information",
                                                   "fp_algorithm": None})
    _twice(db, present=True)
    assert identity(db, uuid_id)["fp_state"] == "pending"


def test_a_new_algorithm_keeps_the_exact_layers_attempts(db):
    uuid_id = add_track(db, "/m/a.flac", identity={
        "exact_state": "pending", "fp_state": "current", "fp_algorithm": "chromaprint-1",
        "attempts": 2, "next_attempt_at": 555, "failure_reason": "timeout"})
    _twice(db, present=True)
    assert _cols(db, uuid_id, "fp_state", "attempts", "next_attempt_at", "failure_reason") == (
        "pending", 2, 555, "timeout")


@pytest.mark.parametrize("state", ["current", "too_short", "low_information"])
def test_a_version_only_change_keeps_every_print(db, state):
    uuid_id = add_track(db, "/m/a.flac", identity={
        **EXACT_CURRENT, "fp_state": state, "fp_algorithm": ALG, "tool_versions": "ffmpeg 9.0.2; fpcalc 1.5.0"})
    _twice(db, present=True)
    assert _cols(db, uuid_id, "fp_state", "match_state") == (state, "current")


def test_without_a_fingerprinter_no_algorithm_re_queues_anything(db):
    uuid_id = add_track(db, "/m/a.flac", identity={**EXACT_CURRENT, "fp_state": "current",
                                                   "fp_algorithm": "chromaprint-1"})
    _twice(db, present=False)
    assert _cols(db, uuid_id, "fp_state", "match_state") == ("current", "current")


# --- failed prints ------------------------------------------------------------------------------------------


def test_a_failed_print_is_retried_after_a_tool_version_change(db):
    uuid_id = add_track(db, "/m/a.flac", identity={
        **EXACT_CURRENT, "fp_state": "failed", "fp_algorithm": ALG, "attempts": 3,
        "failure_reason": "decode_error", "tool_versions": "ffmpeg 9.0.2; fpcalc 1.5.0"})
    _twice(db, present=True)
    assert _cols(db, uuid_id, "fp_state", "attempts", "next_attempt_at", "failure_reason", "exact_state") == (
        "pending", 0, None, None, "current")


def test_a_failed_print_with_the_same_tools_stays_failed(db):
    uuid_id = add_track(db, "/m/a.flac", identity={
        **EXACT_CURRENT, "fp_state": "failed", "fp_algorithm": ALG, "attempts": 3, "failure_reason": "decode_error"})
    _twice(db, present=True)
    assert _cols(db, uuid_id, "fp_state", "attempts") == ("failed", 3)


def test_without_a_fingerprinter_a_failed_print_stays_failed(db):
    uuid_id = add_track(db, "/m/a.flac", identity={
        **EXACT_CURRENT, "fp_state": "failed", "fp_algorithm": ALG, "attempts": 3,
        "failure_reason": "decode_error", "tool_versions": "ffmpeg 9.0.2; fpcalc 1.5.0"})
    _twice(db, present=False, tools="ffmpeg 9.0.2")
    assert _cols(db, uuid_id, "fp_state", "attempts") == ("failed", 3)


@pytest.mark.parametrize("fp_state, attempts", [("failed", 3), ("pending", 2)])
def test_a_print_that_failed_for_a_missing_master_is_retried_once_it_is_back(db, music, fp_state, attempts):
    back = music / "back.flac"
    back.write_bytes(b"x")
    returned = add_track(db, back, identity={
        **EXACT_CURRENT, "fp_state": fp_state, "fp_algorithm": ALG, "attempts": attempts,
        "next_attempt_at": None if fp_state == "failed" else 9_999_999_999, "failure_reason": "master_missing"})
    gone = add_track(db, music / "gone.flac", identity={
        **EXACT_CURRENT, "fp_state": fp_state, "fp_algorithm": ALG, "attempts": attempts,
        "failure_reason": "master_missing"})

    _twice(db, present=True)

    assert _cols(db, returned, "fp_state", "attempts", "next_attempt_at", "failure_reason", "exact_state") == (
        "pending", 0, None, None, "current")
    assert _cols(db, gone, "fp_state", "attempts") == (fp_state, attempts)


def test_the_fingerprint_reconcile_primitives_take_any_owner_only(db):
    import inspect

    names = [n for n in ("set_fingerprint_availability", "requeue_fingerprint_algorithm")]
    for name in names:
        method = getattr(db, name)
        assert inspect.signature(method).parameters["owner_id"].kind is inspect.Parameter.KEYWORD_ONLY
    with pytest.raises(TypeError):
        db.set_fingerprint_availability(True, owner_id=db.owner_id)
    with pytest.raises(TypeError):
        db.requeue_fingerprint_algorithm(ALG, owner_id=db.owner_id)
    assert db.set_fingerprint_availability(True, owner_id=ANY_OWNER) == 0
    assert db.requeue_fingerprint_algorithm(ALG, owner_id=ANY_OWNER) == 0


def test_a_failing_fingerprint_transition_never_stops_startup(db, monkeypatch, caplog):
    uuid_id = add_track(db, "/m/a.flac", identity={"_none": True})

    def boom(*args, **kwargs):
        raise RuntimeError("disk on fire")

    monkeypatch.setattr(db, "set_fingerprint_availability", boom)
    monkeypatch.setattr(db, "requeue_fingerprint_algorithm", boom)
    _reconcile(db, present=True)  # does not raise
    assert identity(db, uuid_id) is not None  # the other parts still ran


# --- an unreadable file (exact layer failed) never strands its print as pending ---------------------------


UNREADABLE = {"exact_state": "failed", "attempts": 3, "failure_reason": "decode_error", "match_state": "current",
              "tool_versions": TOOLS}


def test_a_fingerprinter_appearing_fails_the_print_of_an_unreadable_file(db):
    # The worker never fingerprints a file whose exact layer failed; 'pending'
    # would be work that never ends. It is retried when the exact layer is.
    uuid_id = add_track(db, "/m/a.flac", identity={**UNREADABLE, "fp_state": "unavailable"})
    _twice(db, present=True)
    assert _cols(db, uuid_id, "fp_state", "fp_algorithm", "attempts", "failure_reason", "exact_state") == (
        "failed", ALG, 3, "decode_error", "failed")


def test_a_new_algorithm_keeps_the_print_of_an_unreadable_file_failed(db):
    uuid_id = add_track(db, "/m/a.flac", identity={**UNREADABLE, "fp_state": "failed",
                                                   "fp_algorithm": "chromaprint-1"})
    _twice(db, present=True)
    assert _cols(db, uuid_id, "fp_state", "fp_algorithm", "attempts", "failure_reason") == (
        "failed", ALG, 3, "decode_error")


def test_after_any_reconcile_no_print_waits_behind_a_failed_exact_layer(db):
    for i, fp_state in enumerate(["unavailable", "failed", "current", "too_short"]):
        add_track(db, f"/m/{i}.flac", identity={**UNREADABLE, "fp_state": fp_state, "fp_algorithm": "chromaprint-1"})
    _reconcile(db, present=True)
    stranded = sql(db, "SELECT uuid_id FROM track_audio_identity WHERE exact_state = 'failed' AND fp_state = 'pending'")
    assert stranded == []


def test_a_fingerprinter_appearing_fails_a_pending_print_stranded_behind_a_failed_exact_layer(db):
    # e.g. an exact layer that finally failed while no fingerprinter ran sent
    # its print back to pending.
    uuid_id = add_track(db, "/m/a.flac", identity={**UNREADABLE, "fp_state": "pending"})
    _twice(db, present=True)
    assert _cols(db, uuid_id, "fp_state", "fp_algorithm", "attempts") == ("failed", ALG, 3)


# --- review r1 -------------------------------------------------------------------------------------------


def test_a_print_failed_with_its_unreadable_file_keeps_no_blob(db):
    # F1: the availability transition that fails a print removes its stored blob too.
    uuid_id = add_track(db, "/m/a.flac", identity={**UNREADABLE, "fp_state": "unavailable"})
    sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
            "VALUES (?, 'fpcalc', 'chromaprint-2', 9.0, 1, x'00000000')", (uuid_id,))
    _reconcile(db, present=True)
    assert identity(db, uuid_id)["fp_state"] == "failed"
    assert sql(db, "SELECT 1 FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,)) == []


@pytest.mark.parametrize("stored, current", [
    ("ffmpeg 9.0.2", "ffmpeg 9.0.2; fpcalc 1.6.2"),   # fpcalc appeared
    ("ffmpeg 9.0.2; fpcalc 1.6.2", "ffmpeg 9.0.2"),   # fpcalc disappeared
    ("ffmpeg 9.0.2; fpcalc 1.5.0", "ffmpeg 9.0.2; fpcalc 1.6.2"),  # fpcalc upgraded
])
def test_a_failed_exact_layer_is_retried_only_when_ffmpeg_changed(db, stored, current):
    # F2: fpcalc coming and going between starts never re-decodes exact failures.
    uuid_id = add_track(db, "/m/a.flac", identity={**UNREADABLE, "fp_state": "failed", "fp_algorithm": ALG,
                                                   "tool_versions": stored})
    _twice(db, present="fpcalc" in current, tools=current)
    assert _cols(db, uuid_id, "exact_state", "attempts") == ("failed", 3)


@pytest.mark.parametrize("stored, current", [
    ("ffmpeg 9.0.1", "ffmpeg 9.0.2"),
    ("ffmpeg 9.0.2x", "ffmpeg 9.0.2"),                 # a prefix is not the same version
    ("ffmpeg 9.0.1; fpcalc 1.6.2", "ffmpeg 9.0.2; fpcalc 1.6.2"),
    (None, "ffmpeg 9.0.2"),
])
def test_a_failed_exact_layer_is_retried_when_ffmpeg_changed(db, stored, current):
    uuid_id = add_track(db, "/m/a.flac", identity={**UNREADABLE, "fp_state": "unavailable",
                                                   "tool_versions": stored})
    _reconcile(db, present="fpcalc" in current, tools=current)
    assert _cols(db, uuid_id, "exact_state", "attempts") == ("pending", 0)


@pytest.mark.parametrize("stored, current, retried", [
    ("ffmpeg 9.0.1; fpcalc 1.6.2", "ffmpeg 9.0.2; fpcalc 1.6.2", False),  # only ffmpeg changed
    ("ffmpeg 9.0.2; fpcalc 1.6.2", "ffmpeg 9.0.2; fpcalc 1.6.3", True),
    ("ffmpeg 9.0.2; fpcalc 1.6.2x", "ffmpeg 9.0.2; fpcalc 1.6.2", True),
    ("ffmpeg 9.0.2", "ffmpeg 9.0.2; fpcalc 1.6.2", True),                 # no fpcalc recorded
])
def test_a_failed_print_is_retried_only_when_the_fingerprinter_changed(db, stored, current, retried):
    uuid_id = add_track(db, "/m/a.flac", identity={
        **EXACT_CURRENT, "fp_state": "failed", "fp_algorithm": ALG, "attempts": 3,
        "failure_reason": "decode_error", "tool_versions": stored})
    _reconcile(db, present=True, tools=current)
    assert identity(db, uuid_id)["fp_state"] == ("pending" if retried else "failed")
