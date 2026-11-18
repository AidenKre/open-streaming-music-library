"""Live-gate fix 6-5-L-03, neighbour: prints that gave up for an unknown duration
under the old rule are retried after the fix (spec §6.4 startup reconcile).

Before the fix a file with no header duration ended ``fp_state='failed'`` with
``failure_reason='duration_unknown'`` (or waited on the 1 min / 1 h / 1 day
ladder with that reason). The new rule can measure the duration by decoding,
so the startup reconcile makes those prints eligible again without waiting for
a tool upgrade. It does so once per duration rule (stamped in
``app_settings``, like ``matcher_version``): a file whose duration stays
unknown under the new rule is not re-queued at every start.
"""

import pytest

from app.services.identity_worker import reconcile_audio_identity
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, make_db, sql

TOOLS = "ffmpeg 9.0.2; fpcalc 1.6.2"
ALG = "chromaprint-2"
EXACT_CURRENT = {"exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A,
                 "match_state": "current", "tool_versions": TOOLS}
GAVE_UP = {**EXACT_CURRENT, "fp_state": "failed", "fp_algorithm": ALG, "attempts": 4,
           "failure_reason": "duration_unknown"}
MID_LADDER = {**EXACT_CURRENT, "fp_state": "pending", "fp_algorithm": ALG, "attempts": 2,
              "next_attempt_at": 9_999_999_999, "failure_reason": "duration_unknown"}


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


def _reconcile(db, *, present=True):
    reconcile_audio_identity(
        db, tool_versions=TOOLS if present else "ffmpeg 9.0.2", fingerprinter_present=present,
        fingerprint_algorithm=ALG if present else None,
    )


def _fp(db, uuid_id):
    row = identity(db, uuid_id)
    return (row["fp_state"], row["attempts"], row["next_attempt_at"], row["failure_reason"])


def _stamp(db):
    return sql(db, "SELECT key FROM app_settings WHERE key LIKE '%duration%'")


@pytest.mark.parametrize("state", [GAVE_UP, MID_LADDER], ids=["failed", "mid-ladder"])
def test_a_print_that_gave_up_for_an_unknown_duration_is_retried_without_a_tool_upgrade(db, state):
    uuid_id = add_track(db, "/m/headerless.flac", identity=state)

    _reconcile(db)

    assert _fp(db, uuid_id) == ("pending", 0, None, None)
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"], row["match_state"]) == ("current", DIGEST_A, "current")


def test_other_failures_are_left_alone(db):
    decode = add_track(db, "/m/a.flac", identity={**GAVE_UP, "failure_reason": "decode_error"})
    # The exact layer owns attempts/failure_reason while it is failed: never touched here.
    exact_failed = add_track(db, "/m/b.flac", identity={
        "exact_state": "failed", "fp_state": "failed", "fp_algorithm": ALG, "attempts": 3,
        "failure_reason": "duration_unknown", "match_state": "current", "tool_versions": TOOLS})

    _reconcile(db)

    assert _fp(db, decode) == ("failed", 4, None, "decode_error")
    assert identity(db, exact_failed)["exact_state"] == "failed"
    assert _fp(db, exact_failed) == ("failed", 3, None, "duration_unknown")


def test_the_retry_happens_once_per_duration_rule(db):
    uuid_id = add_track(db, "/m/headerless.flac", identity=GAVE_UP)
    _reconcile(db)
    assert _stamp(db) != []
    # The duration stayed unknown under the new rule too: it gives up again ...
    sql(db, "UPDATE track_audio_identity SET fp_state = 'failed', attempts = 4, "
            "failure_reason = 'duration_unknown' WHERE uuid_id = ?", (uuid_id,))

    _reconcile(db)  # ... and the next start does not re-queue it.

    assert _fp(db, uuid_id) == ("failed", 4, None, "duration_unknown")


def test_without_a_fingerprinter_nothing_is_retried_and_the_retry_waits_for_one(db):
    uuid_id = add_track(db, "/m/headerless.flac", identity=GAVE_UP)

    _reconcile(db, present=False)
    assert _fp(db, uuid_id) == ("failed", 4, None, "duration_unknown")
    assert _stamp(db) == []

    _reconcile(db, present=True)
    assert _fp(db, uuid_id) == ("pending", 0, None, None)


# --- review r-live-fix finding 1: the decoded duration depends on ffmpeg ---------------------------


def _reconcile_tools(db, tools):
    reconcile_audio_identity(db, tool_versions=tools, fingerprinter_present=True, fingerprint_algorithm=ALG)


def test_after_the_rule_stamp_an_ffmpeg_change_retries_a_print_with_an_unknown_duration(db):
    # A failed print is otherwise retried only when fpcalc changes (spec 6.4, per layer),
    # but its duration now also comes from an ffmpeg decode.
    _reconcile_tools(db, TOOLS)  # the stamp is stored: the once-per-rule retry is spent
    uuid_id = add_track(db, "/m/headerless.flac", identity={
        **GAVE_UP, "tool_versions": "ffmpeg 9.0.1; fpcalc 1.6.2"})

    _reconcile_tools(db, TOOLS)  # ffmpeg 9.0.1 -> 9.0.2, fpcalc unchanged

    assert _fp(db, uuid_id) == ("pending", 0, None, None)


def test_with_the_same_ffmpeg_a_print_with_an_unknown_duration_stays_failed(db):
    _reconcile_tools(db, TOOLS)
    uuid_id = add_track(db, "/m/headerless.flac", identity=GAVE_UP)  # recorded with the current tools

    _reconcile_tools(db, TOOLS)

    assert _fp(db, uuid_id) == ("failed", 4, None, "duration_unknown")


def test_an_ffmpeg_change_alone_still_keeps_other_failed_prints(db):
    _reconcile_tools(db, TOOLS)
    uuid_id = add_track(db, "/m/a.flac", identity={
        **GAVE_UP, "failure_reason": "decode_error", "tool_versions": "ffmpeg 9.0.1; fpcalc 1.6.2"})

    _reconcile_tools(db, TOOLS)

    assert _fp(db, uuid_id) == ("failed", 4, None, "decode_error")
