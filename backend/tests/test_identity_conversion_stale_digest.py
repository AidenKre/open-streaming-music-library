"""A stored source digest that no longer describes the master (spec §6.3).

The lossless check may use the stored digest when the row is ``current``. If
that digest is stale (a file hashed while still being written, or replaced
out of band), a correct conversion would fail with "did not match" for ever.
So on a mismatch whose source digest came from storage, the job hashes the
source once more and fails only if the fresh digest mismatches too. When the
fresh digest differs from the stored one, the row is marked stale so the
worker recomputes it. Expected digests come from ffmpeg run directly.
"""

from pathlib import Path

import pytest

import app.services.conversion as conv_mod
import tests.conversion_fixtures as conv
from app.services.conversion import TRACK_CHANGED_ERROR
from app.services.audio_identity import compute_identity
from tests.sqlite_helpers import sql_dicts
from tests.tool_call_capture import tool_call
from tests.identity_conversion_fixtures import _lossless_world, fixtures  # noqa: F401  (fixture)
from tests.identity_rows import _identity
from tests.test_identity_conversion import (
    MISMATCH,
    _mismatched,
    _pcm_digest,
)

STALE = "f" * 64


@pytest.mark.requires_ffmpeg
def test_a_correct_conversion_passes_over_a_stale_stored_digest(tmp_path, fixtures):
    fixture = fixtures["flac24.flac"]
    expected = _pcm_digest(fixture.path)
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixture, "alac", stored=STALE)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    assert [(name, hint) for name, hint, _ in spy.computed_source()] == [("song.flac", "flac")]
    row = _identity(db, track.uuid_id)
    assert (row["exact_state"], row["exact_digest"]) == ("current", expected)
    master = Path(db.get_track_by_uuid(track.uuid_id).file_path)
    assert master.suffix == ".m4a" and _pcm_digest(master) == expected


@pytest.mark.requires_ffmpeg
def test_a_real_mismatch_over_a_stale_digest_still_fails_and_marks_the_row_stale(tmp_path, fixtures):
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)
    spy.rewrite_temp = _mismatched
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", MISMATCH)
    conv._assert_track_untouched(db, track, source, original)
    assert db.list_journal_entries() == []
    assert len(spy.computed_source()) == 1
    row = _identity(db, track.uuid_id)
    # The stored digest was wrong: the worker must recompute every layer.
    assert (row["generation"], row["exact_state"], row["fp_state"], row["match_state"]) \
        == (before["generation"] + 1, "pending", "pending", "pending")
    assert wakeup.seen == [(before["generation"] + 1, 0)]  # woken after the mark committed


@pytest.mark.requires_ffmpeg
def test_a_mismatch_over_a_correct_stored_digest_fails_and_leaves_the_row(tmp_path, fixtures):
    fixture = fixtures["flac24.flac"]
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixture, "alac", stored=_pcm_digest(fixture.path))
    spy.rewrite_temp = _mismatched

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", MISMATCH)
    assert len(spy.computed_source()) == 1  # re-hashed once, agreed with storage
    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []


@pytest.mark.requires_ffmpeg
def test_a_track_change_during_the_re_hash_is_a_track_change_not_absorbed(tmp_path, fixtures):
    """Another writer bumps the generation while the source is hashed again: the
    job must not adopt that generation as its own."""
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)
    real = spy.__call__

    class BumpingSpy(type(spy)):
        def __call__(self, path, codec_hint, **kwargs):
            identity = real(path, codec_hint, **kwargs)
            if ".tagged." not in Path(path).name:
                sql_dicts(db, "UPDATE track_audio_identity SET generation = generation + 1 "
                         "WHERE uuid_id = ?", (track.uuid_id,))
            return identity

    orch.compute_identity = BumpingSpy()
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", TRACK_CHANGED_ERROR)
    conv._assert_track_untouched(db, track, source, original)
    assert db.list_journal_entries() == []


UNVERIFIED = ("Conversion stopped: the converted audio could not be verified against the "
              "original, so the original was kept.")


def _failing_source_rehash(spy, reason):
    """The spy, except that hashing the source (not the converted temp) fails with ``reason``."""
    from app.services.audio_identity import AudioIdentity, ExactUnavailable

    real = spy.__call__

    def failing_source(path, codec_hint, **kwargs):
        if ".tagged." in Path(path).name:
            return real(path, codec_hint, **kwargs)
        # The real source hash used to be computed here and thrown away; the
        # call is still recorded on the spy, nothing hashes the file.
        spy.calls.append((Path(path).name, codec_hint, tool_call(compute_identity, path, codec_hint, **kwargs)))
        return AudioIdentity(exact=ExactUnavailable("failed", reason),
                             tool_versions=None, computed_at=1)

    return failing_source


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("reason", ["timeout", "decode_error", "tool_missing"])
def test_a_re_hash_that_cannot_run_after_a_mismatch_fails_the_job_unverified(tmp_path, fixtures, reason):
    """The converted audio did not match the stored digest, and nothing clears
    that evidence: the job fails, the original stays, the message says the
    conversion could not be verified (not that it did not match), and the row
    is marked stale so the worker recomputes it and a retry can pass."""
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)
    orch.compute_identity = _failing_source_rehash(spy, reason)
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", UNVERIFIED)
    conv._assert_track_untouched(db, track, source, original)
    assert db.list_journal_entries() == []
    assert not list(source.parent.glob("*.m4a"))  # no converted copy left beside the original
    row = _identity(db, track.uuid_id)
    assert (row["generation"], row["exact_state"], row["fp_state"], row["match_state"]) \
        == (before["generation"] + 1, "pending", "pending", "pending")
    assert wakeup.seen == [(before["generation"] + 1, 0)]  # woken after the mark committed


@pytest.mark.requires_ffmpeg
def test_a_killed_re_hash_stops_the_job_and_keeps_the_original(tmp_path, fixtures):
    """A re-hash killed (shutdown or cancel) after a stored-digest mismatch stops
    the job with the "check stopped" text; the master is untouched."""
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)
    orch.compute_identity = _failing_source_rehash(spy, "killed")
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", conv_mod.AUDIO_CHECK_STOPPED_ERROR)
    conv._assert_track_untouched(db, track, source, original)
    assert db.list_journal_entries() == []
    assert not list(source.parent.glob("*.m4a"))


# --- a stored digest whose parameters no longer describe the file ---------------------------------


def _stale_parameters(db, uuid_id):
    sql_dicts(db, "UPDATE track_audio_identity SET exact_digest = ?, sample_rate_hz = 8000 WHERE uuid_id = ?",
         (STALE, uuid_id))


@pytest.mark.requires_ffmpeg
def test_stored_parameters_that_differ_from_the_output_are_checked_against_a_fresh_hash(tmp_path, fixtures):
    """The stored row is not trusted for its parameters either: the source is hashed
    again, the conversion is verified against that, and the row is marked stale."""
    fixture = fixtures["flac24.flac"]
    expected = _pcm_digest(fixture.path)
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixture, "alac", stored=STALE)
    _stale_parameters(db, track.uuid_id)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    assert [(name, hint) for name, hint, _ in spy.computed_source()] == [("song.flac", "flac")]
    assert wakeup.seen[0] == (before["generation"] + 1, 0)  # marked stale, then woken
    row = _identity(db, track.uuid_id)
    assert (row["exact_state"], row["exact_digest"]) == ("current", expected)


@pytest.mark.requires_ffmpeg
def test_a_real_mismatch_behind_stale_stored_parameters_still_fails(tmp_path, fixtures):
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)
    _stale_parameters(db, track.uuid_id)
    spy.rewrite_temp = _mismatched
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", MISMATCH)
    conv._assert_track_untouched(db, track, source, original)


@pytest.mark.requires_ffmpeg
def test_stale_stored_parameters_with_a_re_hash_that_cannot_run_fail_unverified(tmp_path, fixtures):
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)
    _stale_parameters(db, track.uuid_id)
    orch.compute_identity = _failing_source_rehash(spy, "timeout")
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", UNVERIFIED)
    conv._assert_track_untouched(db, track, source, original)


# --- each clause of the fresh-hash decision on its own (review r3, 6-5-R3-03) -------------------


@pytest.mark.requires_ffmpeg
def test_a_correct_stored_digest_with_wrong_stored_parameters_is_still_marked_stale(tmp_path, fixtures):
    """The stored digest is right but its sample rate is not: the row did not describe
    the file, so it is marked stale even though the fresh digest equals the stored one."""
    fixture = fixtures["flac24.flac"]
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixture, "alac", stored=_pcm_digest(fixture.path))
    sql_dicts(db, "UPDATE track_audio_identity SET sample_rate_hz = 8000 WHERE uuid_id = ?", (track.uuid_id,))

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    assert len(spy.computed_source()) == 1  # hashed again
    g = before["generation"]
    assert wakeup.seen == [(g + 1, 0), (g + 2, 0)]  # the stale mark, then the commit


@pytest.mark.requires_ffmpeg
def test_a_real_parameter_change_behind_a_stale_stored_digest_skips_the_check(tmp_path, fixtures, caplog):
    """The stored digest is stale and the conversion really changes the sample rate:
    the fresh hash shows a parameter change, so the check is skipped, not failed."""
    from app.services.audio_identity import AudioIdentity, ExactAudioHash

    caplog.set_level("INFO", logger="app.services.conversion")

    def other_rate(identity):
        exact = identity.exact
        return AudioIdentity(
            exact=ExactAudioHash(exact.kind, "0" * 64, 8000, exact.channels, exact.bits_per_sample),
            tool_versions=identity.tool_versions, computed_at=identity.computed_at,
        )

    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)
    spy.rewrite_temp = other_rate

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    assert len(spy.computed_source()) == 1
    assert any("parameter change" in r.getMessage() for r in caplog.records)


@pytest.mark.requires_ffmpeg
def test_the_fresh_re_hash_runs_under_the_jobs_registry_and_job_id(tmp_path, fixtures):
    """BE-TOOLS review r1 #1: a cancel during the re-hash must reach its ffmpeg."""
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=STALE)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    [(name, _, call)] = spy.computed_source()  # the stored digest disagreed: one fresh hash
    assert name == "song.flac"
    assert (call["registry"], call["job_id"], call["low_priority"]) == (orch._registry, job_id, False)
