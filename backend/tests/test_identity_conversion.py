"""Phase 6.5A.2c: conversion verification and the conversion identity writers
(spec §6.2 conversion rows, §6.3; SC-25 Phase 2 retrofit; review 6.5-U04/U05).

The DB layer first: ``_write_conversion_identity_in`` stores the identity the
job computed for the converted file. It bumps ``generation`` (the new bytes are
in place), writes the exact layer, keeps the fingerprint only when the PCM
digest was verified unchanged, and sends the match back to pending.
"""

import contextlib
import shutil
import sqlite3
import subprocess
from pathlib import Path

import pytest

import tests.conversion_fixtures as conv
from app.services.conversion import TRACK_CHANGED_ERROR
from app.core.media_types import CODEC_TO_EXT
from app.services import conversion as conversion_module
from app.database.database import ANY_OWNER, ConversionJobNotRunning, Database
from app.library import Library
from app.services.audio_identity import (
    KIND_PACKETS,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
    compute_identity,
)
from tests.crash import Crash
from tests.identity_conversion_fixtures import (  # noqa: F401  (fixtures is a fixture)
    _ComputeSpy,
    _JobWakeup,
    _lossless_world,
    _settled,
    fixtures,
)
from tests.tool_call_capture import tool_call
from app.services.duplicate_detection import find_duplicates
from app.services.track_editor import reconcile_journal
from tests.owned_database import add_test_user
from tests.sqlite_helpers import sql_dicts
from tests.identity_rows import DIGEST, _identity
from tests.test_identity_writers import (  # noqa: F401  (connection_depth is a fixture)
    _bare_track,
    _current,
    _new_track,
    connection_depth,
)

NEW_DIGEST = "cd" * 32


def _track(db):
    track = _new_track(identity=_current())
    assert db.add_track(track)
    return track.uuid_id


def _write(db, uuid_id, identity, *, audio_unchanged, commit=True):
    with db._connection(commit=commit) as conn:
        return Database._write_conversion_identity_in(
            conn, uuid_id, identity, audio_unchanged=audio_unchanged
        )


def _aac(computed_at=1_800_000_000):
    return AudioIdentity(
        exact=ExactAudioHash(KIND_PACKETS, NEW_DIGEST, 44100, 2, None),
        tool_versions="ffmpeg 9.0.2", computed_at=computed_at,
    )


LIFECYCLE = {"match_state": "pending", "priority": 0, "attempts": 0, "next_attempt_at": None}


# --- the primitive -------------------------------------------------------------------


def test_a_converted_file_gets_its_job_identity_and_a_new_generation(db):
    uuid_id = _track(db)
    _settled(db, uuid_id)

    assert _write(db, uuid_id, _aac(), audio_unchanged=False) is True

    row = _identity(db, uuid_id)
    assert {k: row[k] for k in (
        "generation", "exact_state", "exact_kind", "exact_digest", "sample_rate_hz", "channels",
        "bits_per_sample", "failure_reason", "computed_at", "tool_versions", *LIFECYCLE,
    )} == {
        "generation": 4, "exact_state": "current", "exact_kind": "packets_sha256",
        "exact_digest": NEW_DIGEST, "sample_rate_hz": 44100, "channels": 2,
        "bits_per_sample": None, "failure_reason": None, "computed_at": 1_800_000_000,
        "tool_versions": "ffmpeg 9.0.2", **LIFECYCLE,
    }


def test_a_changed_audio_sends_the_fingerprint_back_to_pending(db):
    uuid_id = _track(db)
    before = _settled(db, uuid_id)

    _write(db, uuid_id, _aac(), audio_unchanged=False)

    row = _identity(db, uuid_id)
    assert row["fp_state"] == "pending"
    assert row["fp_algorithm"] == before["fp_algorithm"]  # stale-but-safe, like a mark


def test_a_verified_unchanged_audio_keeps_the_fingerprint(db):
    uuid_id = _track(db)
    before = _settled(db, uuid_id)

    _write(db, uuid_id, _current(computed_at=1_900_000_000), audio_unchanged=True)

    row = _identity(db, uuid_id)
    assert (row["fp_state"], row["fp_algorithm"]) == ("current", "chromaprint-2")
    assert (row["exact_state"], row["exact_digest"], row["generation"]) == ("current", DIGEST, 4)
    assert row["matcher_version"] == before["matcher_version"]
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE


def test_no_fingerprinter_stays_unavailable_after_a_conversion(db):
    uuid_id = _track(db)
    _settled(db, uuid_id, fp_state="unavailable")

    _write(db, uuid_id, _aac(), audio_unchanged=False)

    assert _identity(db, uuid_id)["fp_state"] == "unavailable"


def _unreadable(db, uuid_id, *, exact_state="failed", fp_state="failed"):
    """What the worker leaves after the exact hash failed for good (DEV-6.5-12): exact
    'failed' with nothing known, and the fingerprint marked failed with it (no fpcalc run)."""
    sql_dicts(db, "UPDATE track_audio_identity SET generation = 3, exact_state = ?, "
             "exact_kind = NULL, exact_digest = NULL, sample_rate_hz = NULL, channels = NULL, "
             "bits_per_sample = NULL, fp_state = ?, fp_algorithm = 'chromaprint-2', "
             "match_state = 'current', attempts = 4, next_attempt_at = NULL, "
             "failure_reason = 'decode_error' WHERE uuid_id = ?",
         (exact_state, fp_state, uuid_id))


@pytest.mark.parametrize("exact_state", ["failed", "pending"])
def test_an_unchanged_conversion_retries_a_print_the_failed_exact_hash_failed(db, exact_state):
    # DEV-6.5-12 (sign-off 2026-11-17, U08-B-02): the print was failed only because the
    # exact hash could not be made ('pending' = that state after a tag-edit mark). The
    # conversion now wrote a current exact hash, so the print is tried again, as the
    # worker's own successful exact compute would do (``_fp_after_exact``).
    uuid_id = _track(db)
    _unreadable(db, uuid_id, exact_state=exact_state)

    _write(db, uuid_id, _current(computed_at=1_900_000_000), audio_unchanged=True)

    row = _identity(db, uuid_id)
    assert (row["exact_state"], row["fp_state"]) == ("current", "pending")
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE
    # ...and the fingerprinting worker sees it as due work.
    assert db.next_identity_work(
        2_000_000_000, skip={}, owner_id=ANY_OWNER, fingerprint=True
    ) == uuid_id


@pytest.mark.parametrize("exact_state, fp_state", [
    ("current", "failed"),       # the print failed for its own reason; the audio did not change
    ("current", "current"),      # a stored print of unchanged audio is kept
    ("current", "too_short"),
    ("current", "low_information"),
    ("failed", "unavailable"),   # no fingerprinter: never claims one exists
    ("failed", "pending"),       # already waiting
])
def test_an_unchanged_conversion_keeps_every_other_print_state(db, exact_state, fp_state):
    uuid_id = _track(db)
    if exact_state == "current":
        _settled(db, uuid_id, fp_state=fp_state)
    else:
        _unreadable(db, uuid_id, exact_state=exact_state, fp_state=fp_state)

    _write(db, uuid_id, _current(computed_at=1_900_000_000), audio_unchanged=True)

    row = _identity(db, uuid_id)
    assert (row["exact_state"], row["fp_state"], row["fp_algorithm"]) \
        == ("current", fp_state, "chromaprint-2")


def test_a_changed_conversion_still_re_pends_a_print_that_failed_on_its_own(db):
    uuid_id = _track(db)
    _settled(db, uuid_id, fp_state="failed")

    _write(db, uuid_id, _aac(), audio_unchanged=False)

    assert _identity(db, uuid_id)["fp_state"] == "pending"


def test_a_failed_job_hash_is_stored_pending_with_nothing_known(db):
    uuid_id = _track(db)
    _settled(db, uuid_id)

    _write(db, uuid_id, AudioIdentity(
        exact=ExactUnavailable("failed", "tool_missing"), tool_versions=None, computed_at=7,
    ), audio_unchanged=False)

    row = _identity(db, uuid_id)
    assert (row["generation"], row["exact_state"], row["exact_kind"], row["exact_digest"],
            row["sample_rate_hz"], row["channels"], row["failure_reason"]) \
        == (4, "pending", None, None, None, None, None)
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE


def test_a_track_without_an_identity_row_is_left_for_the_reconcile(db):
    uuid_id = _bare_track(db)

    assert _write(db, uuid_id, _aac(), audio_unchanged=False) is False
    assert _identity(db, uuid_id) is None


def test_the_conversion_primitive_never_commits(db):
    uuid_id = _track(db)
    before = _settled(db, uuid_id)

    _write(db, uuid_id, _aac(), audio_unchanged=False, commit=False)

    assert _identity(db, uuid_id) == before


# --- the owned wrappers (in-place writer and the job's source read) -------------------


def test_the_owned_writer_writes_for_the_owner_only(db):
    uuid_id = _track(db)
    before = _settled(db, uuid_id)
    other = add_test_user(db, "other")

    assert Library(db, other).write_conversion_identity(uuid_id, _aac()) is False
    assert _identity(db, uuid_id) == before

    assert Library(db, db.owner_id).write_conversion_identity(uuid_id, _aac()) is True
    row = _identity(db, uuid_id)
    assert (row["generation"], row["exact_digest"], row["fp_state"]) == (4, NEW_DIGEST, "pending")


def test_the_owned_read_returns_the_row_for_the_owner_only(db):
    uuid_id = _track(db)
    before = _settled(db, uuid_id)
    other = add_test_user(db, "other")

    assert Library(db, other).get_audio_identity(uuid_id) is None
    row = Library(db, db.owner_id).get_audio_identity(uuid_id)
    assert {k: row[k] for k in ("generation", "exact_state", "exact_kind", "exact_digest",
                                "sample_rate_hz", "channels")} \
        == {k: before[k] for k in ("generation", "exact_state", "exact_kind", "exact_digest",
                                   "sample_rate_hz", "channels")}
    assert Library(db, db.owner_id).get_audio_identity("no-such-uuid") is None


# --- complete_conversion_job: the relocating writer (identity in its commit) ----------


def _running_job(db, uuid_id):
    job_id = db.insert_conversion_job(uuid_id, "aac", "m4a", 256, base_revision=None)
    assert db.mark_conversion_job_running(job_id)
    return job_id


def test_the_relocating_commit_writes_the_job_identity_in_its_transaction(db):
    uuid_id = _track(db)
    _settled(db, uuid_id)
    job_id = _running_job(db, uuid_id)

    db.complete_conversion_job(
        job_id, uuid_id, "aac", 256.0, 44100, 2, file_path="/m/Lucky.m4a",
        identity=_aac(), audio_unchanged=False,
    )

    row = _identity(db, uuid_id)
    assert (row["generation"], row["exact_kind"], row["exact_digest"], row["fp_state"]) \
        == (4, "packets_sha256", NEW_DIGEST, "pending")
    assert db.get_conversion_job(job_id)["status"] == "done"


def test_the_relocating_commit_passes_audio_unchanged_through(db):
    uuid_id = _track(db)
    _settled(db, uuid_id)
    job_id = _running_job(db, uuid_id)

    db.complete_conversion_job(
        job_id, uuid_id, "alac", None, 44100, 2, file_path="/m/Lucky.m4a",
        identity=_current(), audio_unchanged=True,
    )

    assert _identity(db, uuid_id)["fp_state"] == "current"


def test_a_refused_commit_leaves_the_identity_untouched(db):
    uuid_id = _track(db)
    before = _settled(db, uuid_id)
    job_id = _running_job(db, uuid_id)
    db.mark_conversion_job_cancelled(job_id)

    with pytest.raises(ConversionJobNotRunning):
        db.complete_conversion_job(
            job_id, uuid_id, "aac", 256.0, 44100, 2, file_path="/m/Lucky.m4a",
            identity=_aac(), audio_unchanged=False,
        )

    assert _identity(db, uuid_id) == before


def test_an_in_place_commit_marks_the_identity_stale_before_the_replace(db):
    """The in-place commit runs before ``os.replace``: no identity yet. Pre-merge
    A3-01: the old digest describes audio about to be replaced, so the commit
    marks the row stale ('conversion': digest cleared, every layer pending)."""
    uuid_id = _track(db)
    before = _settled(db, uuid_id)
    job_id = _running_job(db, uuid_id)

    db.complete_conversion_job(
        job_id, uuid_id, "aac", 256.0, 44100, 2, file_path=None,
        inplace_journal=("/m/Lucky.flac", "/s/t.m4a"),
    )

    row = _identity(db, uuid_id)
    assert (row["generation"], row["exact_state"], row["exact_kind"], row["exact_digest"],
            row["fp_state"], row["match_state"]) \
        == (before["generation"] + 1, "pending", None, None, "pending", "pending")


# --- SC-16a: the conversion writers open no second connection ------------------------


def test_no_conversion_identity_writer_opens_a_connection_inside_its_transaction(
    db, connection_depth
):
    uuid_id = _track(db)
    job_id = _running_job(db, uuid_id)
    connection_depth["max"] = 0

    db.complete_conversion_job(
        job_id, uuid_id, "aac", 256.0, 44100, 2, file_path="/m/Lucky.m4a",
        identity=_aac(), audio_unchanged=False,
    )
    db.write_conversion_identity(uuid_id, _aac())
    db.get_audio_identity(uuid_id)

    assert _identity(db, uuid_id)["generation"] == 3
    assert connection_depth["max"] == 1


# --- the conversion job as an identity writer (real ffmpeg) ---------------------------
#
# The job computes the identity of the converted file and stores it once the new bytes
# are at the master path: in the relocating commit, or (in place) in a short
# transaction after ``os.replace`` and before the journal row is deleted. A failure or
# crash after the replace converges through journal recovery ('conversion' mark).


def _packet_digest(path):
    """Independent expectation: ffmpeg's packet hash of the file's first audio stream."""
    out = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-map", "0:a:0",
         "-c:a", "copy", "-f", "hash", "-hash", "sha256", "-"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    assert out.startswith("SHA256=")
    return out[len("SHA256="):].lower()


def _conversion_world(tmp_path, codec, target, bitrate):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    ext = {"flac": "flac", "mp3": "mp3"}[codec]
    source = conv._root(tmp_path) / f"song.{ext}"
    conv._make_audio(source, codec=codec)
    track = conv._add_track(db, source, codec=codec,
                            bitrate_kbps=192.0 if codec == "mp3" else 1000.0)
    before = _settled(db, track.uuid_id)
    wakeup = _JobWakeup(db, track.uuid_id)
    orch.identity_signal = wakeup
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, target, bitrate, track.revision)
    return db, orch, coordinator, track, source, before, wakeup, job_id


@pytest.mark.requires_ffmpeg
def test_a_relocating_conversion_stores_the_new_files_identity_and_signals_after(tmp_path):
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "flac", "aac", 256)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    master = Path(db.get_track_by_uuid(track.uuid_id).file_path)
    row = _identity(db, track.uuid_id)
    assert (row["generation"], row["exact_state"], row["exact_kind"]) \
        == (before["generation"] + 1, "current", "packets_sha256")
    assert row["exact_digest"] == _packet_digest(master)
    assert (row["fp_state"], row["match_state"], row["priority"]) == ("pending", "pending", 0)
    assert wakeup.seen == [(before["generation"] + 1, 0)]


@pytest.mark.requires_ffmpeg
def test_an_in_place_conversion_stores_the_identity_after_the_replace_and_signals_after(
    tmp_path, monkeypatch
):
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "mp3", "mp3", 128)
    original = source.read_bytes()
    real_write = db.write_conversion_identity
    at_write = []

    def spy(*args, **kwargs):
        at_write.append((source.read_bytes() != original, len(db.list_journal_entries())))
        return real_write(*args, **kwargs)

    monkeypatch.setattr(db, "write_conversion_identity", spy)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert at_write == [(True, 1)]  # new bytes in place, journal row not yet deleted
    row = _identity(db, track.uuid_id)
    # Two bumps: the commit's 'conversion' mark (pre-merge A3-01), then the write.
    assert (row["generation"], row["exact_state"], row["exact_kind"]) \
        == (before["generation"] + 2, "current", "packets_sha256")
    assert row["exact_digest"] == _packet_digest(source)
    assert row["fp_state"] == "pending"
    assert db.list_journal_entries() == []
    assert wakeup.seen == [(before["generation"] + 2, 0)]


@pytest.mark.requires_ffmpeg
def test_an_in_place_identity_write_that_fails_keeps_the_job_done_and_recovery_marks(
    tmp_path, monkeypatch
):
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "mp3", "mp3", 128)
    original = source.read_bytes()

    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "write_conversion_identity", boom)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    assert source.read_bytes() != original
    assert [e["intent"] for e in db.list_journal_entries()] == ["convert"]
    assert wakeup.seen == []
    # Pre-merge A3-01: the commit already marked the identity stale ('conversion'),
    # so the old digest of the replaced audio is not left 'current'.
    row = _identity(db, track.uuid_id)
    assert (row["generation"], row["exact_state"], row["exact_kind"], row["exact_digest"],
            row["fp_state"], row["match_state"]) \
        == (before["generation"] + 1, "pending", None, None, "pending", "pending")

    monkeypatch.undo()
    reconcile_journal(db, tmp_path)

    row = _identity(db, track.uuid_id)
    assert (row["generation"], row["exact_state"], row["exact_digest"], row["fp_state"]) \
        == (before["generation"] + 2, "pending", None, "pending")
    assert db.list_journal_entries() == []


@pytest.mark.requires_ffmpeg
def test_an_in_place_conversion_whose_identity_write_fails_is_no_exact_copy_of_the_original(
    tmp_path, monkeypatch
):
    # Pre-merge A3-01: the file now holds other audio; an upload of the original
    # must not be refused against it, nor the finder call it an exact copy.
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "mp3", "mp3", 128)
    original = AudioIdentity(
        exact=ExactAudioHash(before["exact_kind"], before["exact_digest"], before["sample_rate_hz"],
                             before["channels"], before["bits_per_sample"]),
        tool_versions=None, computed_at=0)

    def exact_copies():
        with db._connection() as conn:
            report = find_duplicates(conn, original, owner_id=db.owner_id)
            _, refused = Database._exact_library_matches_in(
                conn, owner_id=db.owner_id, item_uuid="item-1", identity=original, acknowledged={})
        return [m.subject.uuid_id for m in report.matches if m.kind == "exact"], refused

    assert exact_copies() == ([track.uuid_id], [track.uuid_id])

    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "write_conversion_identity", boom)
    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert exact_copies() == ([], [])


@pytest.mark.requires_ffmpeg
def test_a_crash_between_the_replace_and_the_identity_write_converges_through_recovery(
    tmp_path, monkeypatch
):
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "mp3", "mp3", 128)
    original = source.read_bytes()
    snap = {}

    def crash(*args, **kwargs):
        # The process dies here; the next startup runs journal recovery.
        reconcile_journal(db, tmp_path)
        snap.update(row=_identity(db, track.uuid_id), journal=db.list_journal_entries(),
                    replaced=source.read_bytes() != original)
        raise Crash()

    monkeypatch.setattr(db, "write_conversion_identity", crash)

    with pytest.raises(Crash):
        conv._run_submitted(coordinator)

    assert snap["replaced"] is True
    assert snap["journal"] == []
    row = snap["row"]
    assert (row["generation"], row["exact_state"], row["exact_digest"], row["fp_state"],
            row["match_state"], row["priority"]) \
        == (before["generation"] + 2, "pending", None, "pending", "pending", 0)


@pytest.mark.requires_ffmpeg
def test_a_crash_after_the_relocating_commit_converges_through_recovery(tmp_path, monkeypatch):
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "flac", "aac", 256)
    real_complete = db.complete_conversion_job
    snap = {}

    def commit_then_crash(*args, **kwargs):
        result = real_complete(*args, **kwargs)
        snap["committed"] = _identity(db, track.uuid_id)
        reconcile_journal(db, tmp_path)
        snap["recovered"] = _identity(db, track.uuid_id)
        raise Crash()

    monkeypatch.setattr(db, "complete_conversion_job", commit_then_crash)

    with pytest.raises(Crash):
        conv._run_submitted(coordinator)

    committed, recovered = snap["committed"], snap["recovered"]
    assert (committed["generation"], committed["exact_state"]) \
        == (before["generation"] + 1, "current")
    # Pre-merge A3-01: recovery's 'conversion' mark clears the digest (unknown until
    # the worker hashes the master again), never a digest it cannot vouch for.
    assert (recovered["generation"], recovered["exact_state"], recovered["exact_digest"]) \
        == (before["generation"] + 2, "pending", None)
    assert wakeup.seen == []


# --- §6.3 verification: lossless integer -> lossless integer (real ffmpeg) -------------
#
# The converted file's PCM digest must equal the source's. The source digest is the
# stored one when the row is `current` for the source generation, else computed in the
# job. A mismatch fails the job with the exact message and leaves everything as it was
# (DEV-6.5-06: a deliberate Phase 2 behavior change).

MISMATCH = ("Conversion stopped: the converted audio did not match the original, so the "
            "original was kept (conversion_audio_mismatch).")


def _pcm_digest(path):
    """Independent expectation: ffmpeg's s32 PCM hash of the file's first audio stream."""
    out = subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-map", "0:a:0",
         "-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    assert out.startswith("SHA256=")
    return out[len("SHA256="):].lower()


LOSSLESS_CASES = [
    ("flac24.flac", "alac"), ("alac24.m4a", "flac"), ("wav24.wav", "flac"),
    ("wav24.wav", "alac"), ("flac24_level0.flac", "alac"), ("flac24_retag.flac", "alac"),
    ("flac16.flac", "alac"), ("alac16.m4a", "flac"), ("wav16.wav", "flac"),
    ("wav16.wav", "alac"), ("flac16_padded24.flac", "alac"),
    ("flac24_silence.flac", "alac"), ("unrelated24.flac", "alac"),
]


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("name,target", LOSSLESS_CASES)
def test_a_lossless_conversion_passes_and_keeps_the_digest_and_fingerprint(
    tmp_path, fixtures, name, target
):
    """Exit proof 1 over the whole lossless fixture set: no false mismatch from
    stream selection, padding/priming or bit depth (16-bit into a 24-bit container)."""
    expected = _pcm_digest(fixtures[name].path)
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures[name], target)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    master = Path(db.get_track_by_uuid(track.uuid_id).file_path)
    assert master.suffix == f".{CODEC_TO_EXT[target]}"
    row = _identity(db, track.uuid_id)
    assert (row["generation"], row["exact_state"], row["exact_kind"], row["exact_digest"]) \
        == (before["generation"] + 1, "current", "pcm_sha256", expected)
    assert _pcm_digest(master) == expected
    # Verified unchanged: the fingerprint is kept.
    assert (row["fp_state"], row["fp_algorithm"]) == ("current", "chromaprint-2")
    assert (row["match_state"], row["priority"]) == ("pending", 0)
    assert wakeup.seen == [(before["generation"] + 1, 0)]


@pytest.mark.requires_ffmpeg
def test_the_stored_digest_is_used_when_current_for_the_source_generation(tmp_path, fixtures):
    fixture = fixtures["flac24.flac"]
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixture, "alac", stored=_pcm_digest(fixture.path))

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert spy.computed_source() == []  # only the converted temp was hashed
    assert [c[1] for c in spy.calls] == ["alac"]
    _, _, kwargs = spy.calls[0]
    assert kwargs.get("registry") is orch._registry and kwargs.get("job_id") == job_id
    assert _identity(db, track.uuid_id)["fp_state"] == "current"


@pytest.mark.requires_ffmpeg
def test_the_source_digest_is_computed_when_the_stored_one_is_not_current(tmp_path, fixtures):
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac")  # stored digest pending (stale)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert [(name, hint) for name, hint, _ in spy.computed_source()] == [("song.flac", "flac")]
    assert _identity(db, track.uuid_id)["exact_digest"] == _pcm_digest(fixtures["flac24.flac"].path)


def _mismatched(identity):
    exact = identity.exact
    assert isinstance(exact, ExactAudioHash)
    return AudioIdentity(
        exact=ExactAudioHash(exact.kind, "0" * 64, exact.sample_rate_hz, exact.channels,
                             exact.bits_per_sample),
        tool_versions=identity.tool_versions, computed_at=identity.computed_at,
    )


@pytest.mark.requires_ffmpeg
def test_a_mismatch_fails_the_job_and_leaves_everything_as_it_was(tmp_path, fixtures):
    """Exit proof 2: master bytes, track row, revision, journal and identity untouched;
    ``error_text`` carries the human message with the stable code verbatim."""
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac")
    spy.rewrite_temp = _mismatched
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    assert job["error_text"] == MISMATCH
    assert "conversion_audio_mismatch" in job["error_text"]
    conv._assert_track_untouched(db, track, source, original)
    assert db.get_track_by_uuid(track.uuid_id).metadata == track.metadata
    assert not source.with_suffix(".m4a").exists()
    assert db.list_journal_entries() == []
    assert conv._staging_files(tmp_path) == []
    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []


@pytest.mark.requires_ffmpeg
def test_a_source_change_during_the_job_is_a_track_change_not_a_mismatch(
    tmp_path, fixtures, monkeypatch
):
    """A writer bumped the identity generation while the job transcoded: the source
    digest no longer describes the master the job read, so it is never compared."""
    fixture = fixtures["flac24.flac"]
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixture, "alac", stored=_pcm_digest(fixture.path))
    spy.rewrite_temp = _mismatched
    real_transcode = conversion_module.transcode

    def transcode_then_rewrite(*args, **kwargs):
        result = real_transcode(*args, **kwargs)
        sql_dicts(db, "UPDATE track_audio_identity SET generation = generation + 1 WHERE uuid_id = ?",
             (track.uuid_id,))
        return result

    monkeypatch.setattr(conversion_module, "transcode", transcode_then_rewrite)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", TRACK_CHANGED_ERROR)
    assert db.get_track_by_uuid(track.uuid_id).revision == track.revision


# --- §6.3 step 5: where the check does not apply, or cannot run ----------------------
#
# Not applicable (lossy target, lossy source, float source, a parameter change, a
# multi-stream source) -> logged and skipped; the job still converts and the
# fingerprint goes back to pending (the audio was not verified unchanged). A hash
# that cannot run (tool missing, timeout, decode error) is not a mismatch: logged,
# and the job proceeds unverified (spec silent; DEV). A hash killed by a cancel or
# shutdown stops the job.

LOGGER = "app.services.conversion"


def _skip_logged(caplog, reason):
    return any(r.name == LOGGER and "audio check skipped" in r.getMessage()
               and reason in r.getMessage() for r in caplog.records)


def _run_case(tmp_path, fixture, target, bitrate=None, spy=None):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / f"song{fixture.path.suffix}"
    shutil.copyfile(fixture.path, source)
    track = conv._add_track(db, source, codec=fixture.codec_hint)
    _settled(db, track.uuid_id)
    sql_dicts(db, "UPDATE track_audio_identity SET exact_state = 'pending' WHERE uuid_id = ?",
         (track.uuid_id,))  # the source digest is computed, never the stale stored one
    before = _identity(db, track.uuid_id)
    spy = spy or _ComputeSpy()
    orch.compute_identity = spy
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, target, bitrate, track.revision)
    conv._run_submitted(coordinator)
    return db, track, source, before, spy, db.get_conversion_job(job_id)


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("name,target,bitrate,reason", [
    ("flac24.flac", "aac", 256, "lossy target"),
    ("alac16.m4a", "mp3", 320, "lossy target"),
    ("mp3_320.mp3", "flac", None, "lossy source"),
    ("aac256.m4a", "alac", None, "lossy source"),
    ("wav_f32.wav", "flac", None, "float source"),
])
def test_a_conversion_the_check_does_not_apply_to_skips_with_a_log(
    tmp_path, fixtures, caplog, name, target, bitrate, reason
):
    caplog.set_level("INFO", logger=LOGGER)
    db, track, source, before, spy, job = _run_case(tmp_path, fixtures[name], target, bitrate)

    assert (job["status"], job["error_text"]) == ("done", None)
    assert _skip_logged(caplog, reason)
    assert spy.computed_source() == []  # no source hash when the check cannot apply
    row = _identity(db, track.uuid_id)
    # AAC -> ALAC stays an .m4a: an in-place conversion, whose commit also marks the
    # identity stale before the write (pre-merge A3-01), so two bumps.
    bumps = 2 if name == "aac256.m4a" else 1
    assert (row["generation"], row["exact_state"], row["fp_state"]) \
        == (before["generation"] + bumps, "current", "pending")


@pytest.mark.requires_ffmpeg
def test_a_parameter_change_skips_with_a_log(tmp_path, fixtures, caplog):
    caplog.set_level("INFO", logger=LOGGER)

    def other_rate(identity):
        exact = identity.exact
        return AudioIdentity(
            exact=ExactAudioHash(exact.kind, "0" * 64, 48000, exact.channels,
                                 exact.bits_per_sample),
            tool_versions=identity.tool_versions, computed_at=identity.computed_at,
        )

    db, track, source, before, spy, job = _run_case(
        tmp_path, fixtures["flac24.flac"], "alac", spy=_ComputeSpy(rewrite_temp=other_rate))

    assert (job["status"], job["error_text"]) == ("done", None)
    assert _skip_logged(caplog, "parameter change")
    assert _identity(db, track.uuid_id)["fp_state"] == "pending"


@pytest.fixture(scope="module")
def two_stream_m4a(tmp_path_factory):
    """ALAC .m4a with two audio streams of different audio: a stereo tone first and a
    5.1 noise second, marked default. ffmpeg's default stream choice (the second)
    differs from ``0:a:0`` (verified on 9.0.2: the transcoder converts the 5.1 stream
    down to stereo, so a ``0:a:0`` comparison would fail falsely)."""
    if shutil.which("ffmpeg") is None:
        pytest.skip("ffmpeg not available")
    path = tmp_path_factory.mktemp("two-stream") / "two.m4a"
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-y",
         "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100:duration=1",
         "-f", "lavfi", "-i", "anoisesrc=color=pink:seed=3:sample_rate=44100:duration=1",
         "-filter_complex",
         "[0:a]aformat=channel_layouts=stereo[a];[1:a]aformat=channel_layouts=5.1[b]",
         "-map", "[a]", "-map", "[b]", "-c:a", "alac",
         "-disposition:a:0", "0", "-disposition:a:1", "default", str(path)],
        check=True,
    )
    return path


@pytest.mark.requires_ffmpeg
def test_a_multi_stream_source_skips_rather_than_failing_falsely(
    tmp_path, two_stream_m4a, caplog
):
    caplog.set_level("INFO", logger=LOGGER)
    fixture = type("F", (), {"path": two_stream_m4a, "codec_hint": "alac"})()

    db, track, source, before, spy, job = _run_case(tmp_path, fixture, "flac")

    assert (job["status"], job["error_text"]) == ("done", None)
    assert _skip_logged(caplog, "multiple audio streams")


def _failed(reason):
    def rewrite(identity):
        return AudioIdentity(exact=ExactUnavailable("failed", reason),
                             tool_versions=identity.tool_versions,
                             computed_at=identity.computed_at)
    return rewrite


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("reason", ["tool_missing", "timeout"])
def test_a_hash_that_cannot_run_is_not_a_mismatch_and_the_job_proceeds(
    tmp_path, fixtures, caplog, reason
):
    caplog.set_level("INFO", logger=LOGGER)
    db, track, source, before, spy, job = _run_case(
        tmp_path, fixtures["flac24.flac"], "alac", spy=_ComputeSpy(rewrite_temp=_failed(reason)))

    assert (job["status"], job["error_text"]) == ("done", None)
    assert any(r.name == LOGGER and "audio check unavailable" in r.getMessage()
               and reason in r.getMessage() for r in caplog.records)
    row = _identity(db, track.uuid_id)
    # The new file's identity is unknown: pending for the worker, never `failed`.
    assert (row["generation"], row["exact_state"], row["exact_digest"], row["fp_state"]) \
        == (before["generation"] + 1, "pending", None, "pending")


@pytest.mark.requires_ffmpeg
def test_a_source_hash_that_cannot_run_lets_the_job_proceed(tmp_path, fixtures, caplog):
    caplog.set_level("INFO", logger=LOGGER)

    class SourceFails(_ComputeSpy):
        def __call__(self, path, codec_hint, **kwargs):
            if ".tagged." not in Path(path).name:
                self.calls.append((Path(path).name, codec_hint, tool_call(compute_identity, path, codec_hint, **kwargs)))
                return AudioIdentity(exact=ExactUnavailable("failed", "timeout"),
                                     tool_versions=None, computed_at=1)
            return super().__call__(path, codec_hint, **kwargs)

    db, track, source, before, spy, job = _run_case(
        tmp_path, fixtures["flac24.flac"], "alac", spy=SourceFails())

    assert (job["status"], job["error_text"]) == ("done", None)
    assert any("audio check unavailable" in r.getMessage() and "timeout" in r.getMessage()
               for r in caplog.records if r.name == LOGGER)
    assert _identity(db, track.uuid_id)["exact_state"] == "current"


@pytest.mark.requires_ffmpeg
def test_a_killed_hash_stops_the_job_and_keeps_the_original(tmp_path, fixtures):
    """A cancel or shutdown killed the check: the job never commits unverified."""
    fixture = fixtures["flac24.flac"]
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.flac"
    shutil.copyfile(fixture.path, source)
    track = conv._add_track(db, source, codec="flac")
    before = _settled(db, track.uuid_id)
    orch.compute_identity = _ComputeSpy(rewrite_temp=_failed("killed"))
    original = source.read_bytes()
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "alac", None, track.revision)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    assert "conversion_audio_mismatch" not in job["error_text"]
    conv._assert_track_untouched(db, track, source, original)
    assert db.list_journal_entries() == []
    assert _identity(db, track.uuid_id) == before


# --- review r1 -------------------------------------------------------------------------


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("reason", ["decode_error", "probe_error", "output_error"])
def test_a_converted_file_that_cannot_be_read_back_fails_and_keeps_the_original(
    tmp_path, fixtures, reason
):
    """Review F1: ffmpeg could not decode the new lossless file; committing would delete
    the lossless original for a file nothing could verify."""
    fixture = fixtures["flac24.flac"]
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.flac"
    shutil.copyfile(fixture.path, source)
    track = conv._add_track(db, source, codec="flac")
    before = _identity(db, track.uuid_id)
    orch.compute_identity = _ComputeSpy(rewrite_temp=_failed(reason))
    original = source.read_bytes()
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "alac", None, track.revision)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    assert job["error_text"] == conversion_module.AUDIO_UNREADABLE_ERROR
    conv._assert_track_untouched(db, track, source, original)
    assert not source.with_suffix(".m4a").exists()
    assert db.list_journal_entries() == []
    assert _identity(db, track.uuid_id) == before


@pytest.mark.requires_ffmpeg
def test_a_source_change_after_the_check_and_before_the_commit_is_a_track_change(
    tmp_path, fixtures, monkeypatch
):
    """Review F4: a writer that bumps the identity generation without a revision (the
    settle check's unreadable branch) between the check and the lock."""
    fixture = fixtures["flac24.flac"]
    db, orch, coordinator, track, source, before, spy, wakeup, job_id = _lossless_world(
        tmp_path, fixture, "alac", stored=_pcm_digest(fixture.path))
    original = source.read_bytes()
    real_lock = orch.track_locks.lock

    @contextlib.contextmanager
    def bump_then_lock(key):
        sql_dicts(db, "UPDATE track_audio_identity SET generation = generation + 1 WHERE uuid_id = ?",
             (track.uuid_id,))
        with real_lock(key):
            yield

    monkeypatch.setattr(orch.track_locks, "lock", bump_then_lock)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", TRACK_CHANGED_ERROR)
    conv._assert_track_untouched(db, track, source, original)
    assert db.list_journal_entries() == []


def test_a_conversion_write_forgets_the_old_files_stat_snapshot(db):
    """Review F5: the stat snapshot described the old master; unknown is NULL."""
    uuid_id = _track(db)
    _settled(db, uuid_id)
    sql_dicts(db, "UPDATE track_audio_identity SET stat_size = 10, stat_mtime_ns = 20, "
             "stat_inode = 30 WHERE uuid_id = ?", (uuid_id,))

    _write(db, uuid_id, _aac(), audio_unchanged=False)

    row = _identity(db, uuid_id)
    assert (row["stat_size"], row["stat_mtime_ns"], row["stat_inode"]) == (None, None, None)
