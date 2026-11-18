"""Phase 7A.2a: a conversion holds a storage reservation from job start to its end.

POST /jobs only checks the ledger (a queued job holds nothing). The worker
reserves when the job starts running, in place of the old free-space check,
and releases the reservation exactly once, after its temps are gone, on every
exit: success, every failure (including the lossless audio check failing or
being unable to verify), and cancel. A reservation the worker never took is
never released by it. A kill or crash leaves the row to the startup reconcile.
"""

import shutil
import sqlite3
from pathlib import Path
from types import SimpleNamespace

import pytest

import app.services.conversion as conv_mod
import tests.test_conversion as conv
from app.services.metadata import TagWriteError
from app.services.storage_ledger import (
    CONVERSION,
    InsufficientStorage,
    StagedQuota,
    StorageLedger,
    register_purpose,
)
from app.services.transcoder import TranscodeResult
from tests.test_identity_conversion import (  # noqa: F401  (fixtures is a fixture)
    _ComputeSpy,
    _failed,
    _lossless_world,
    _mismatched,
    fixtures,
)
from tests.test_identity_conversion_stale_digest import STALE, _failing_source_rehash

BOOT = "boot-now"
MIB = 1024 * 1024


class SpyLedger(StorageLedger):
    """The real ledger, recording each reserve and release and what staging
    held at release time."""

    def __init__(self, *args, staging_dir, **kwargs):
        super().__init__(*args, **kwargs)
        self.staging_dir = staging_dir
        self.reserved, self.released, self.temps_at_release = [], [], []
        self.release_error = None

    def reserve(self, **kwargs):
        rid = super().reserve(**kwargs)
        self.reserved.append((rid, kwargs))
        return rid

    def release(self, reservation_id):
        self.temps_at_release.append(
            sorted(p.name for p in self.staging_dir.iterdir()) if self.staging_dir.is_dir() else []
        )
        if self.release_error is not None:
            self.released.append((reservation_id, "error"))
            raise self.release_error
        ok = super().release(reservation_id)
        self.released.append((reservation_id, ok))
        return ok


def _rows(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute(
            "SELECT id, owner_id, purpose, subject_ref, bytes, lease_boot_id "
            "FROM storage_reservations ORDER BY id"
        ).fetchall()
    finally:
        conn.close()


def _spy(orch, db, tmp_path, *, free=None, floor=0):
    disk = shutil.disk_usage if free is None else (lambda _p: SimpleNamespace(free=free))
    spy = SpyLedger(
        db, path=tmp_path, floor_bytes=floor, boot_id=BOOT, disk_usage=disk,
        staging_dir=orch.staging_dir,
    )
    orch.storage_ledger = spy
    return spy


def _fake_world(tmp_path, *, codec="flac", target="aac", bitrate=192):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    spy = _spy(orch, db, tmp_path)
    source = conv._root(tmp_path) / f"song.{ {'flac': 'flac', 'mp3': 'mp3'}[codec] }"
    source.write_bytes(b"fake")
    track = conv._add_track(db, source, codec=codec)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, target, bitrate, track.revision)
    return db, orch, coordinator, spy, track, source, job_id


def _assert_held_once_and_released_once(spy, db):
    assert len(spy.reserved) == 1, spy.reserved
    rid = spy.reserved[0][0]
    assert spy.released == [(rid, True)]
    # Released only after the job's temps were removed.
    assert [n for n in spy.temps_at_release[0] if ".convert." in n or ".tagged." in n] == []
    assert _rows(db) == []


def _assert_never_held(spy, db):
    assert spy.reserved == [] and spy.released == []
    assert _rows(db) == []


# --- enqueue: an admission check, nothing held ------------------------------------------


def test_enqueue_holds_nothing(tmp_path):
    db, orch, coordinator, spy, track, source, job_id = _fake_world(tmp_path)

    assert db.get_conversion_job(job_id)["status"] == "queued"
    _assert_never_held(spy, db)


def test_enqueue_is_refused_when_live_reservations_leave_too_little(tmp_path):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    spy = _spy(orch, db, tmp_path, free=100 * MIB, floor=0)
    source = conv._root(tmp_path) / "song.flac"
    source.write_bytes(b"fake")
    track = conv._add_track(db, source, codec="flac")
    other = StorageLedger(db, path=tmp_path, floor_bytes=0, boot_id=BOOT,
                          disk_usage=lambda _p: SimpleNamespace(free=100 * MIB))
    other.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=90 * MIB, subject_ref="x")

    with pytest.raises(conv_mod.InsufficientDiskSpace) as refused:
        orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)

    assert refused.value.code == "insufficient_storage"
    assert str(tmp_path) not in str(refused.value)
    assert db.list_conversion_jobs()[0] == []
    assert spy.reserved == [] and len(_rows(db)) == 1


# --- the worker: held from job start ----------------------------------------------------


def test_a_running_job_holds_its_estimate_for_its_owner_under_this_boot(tmp_path, monkeypatch):
    db, orch, coordinator, spy, track, source, job_id = _fake_world(tmp_path)
    seen = []

    def fake_transcode(src, dest, *args, **kwargs):
        seen.append(_rows(db))
        return TranscodeResult(ok=False, stderr="boom")

    monkeypatch.setattr(conv_mod, "transcode", fake_transcode)

    conv._run_submitted(coordinator)

    # 0.3 s of 192 kbps AAC = 7200 bytes (the unchanged Phase 2 estimate truncates
    # the float product to 7199); x2.2 for the two temps + 16 MiB headroom.
    expected = int(7199 * 2.2) + 16 * MIB
    [[row]] = seen
    assert row[1:] == (db.owner_id, "conversion", str(job_id), expected, BOOT)
    _assert_held_once_and_released_once(spy, db)


def test_a_job_the_ledger_refuses_at_start_fails_without_a_path_and_runs_nothing(
    tmp_path, monkeypatch
):
    db, orch, coordinator, spy, track, source, job_id = _fake_world(tmp_path)
    # Free space shrank between enqueue and start.
    spy._disk_usage = lambda _p: SimpleNamespace(free=MIB)
    transcoded = []
    monkeypatch.setattr(conv_mod, "transcode", lambda *a, **k: transcoded.append(a))

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert job["status"] == "failed"
    assert str(tmp_path) not in job["error_text"]
    # 7-fix-r0 review R0-1: the ledger's own message (numbers only) is kept.
    assert job["error_text"].startswith("Not enough free disk space"), job["error_text"]
    assert transcoded == []
    conv._assert_track_untouched(db, track, source, b"fake")
    _assert_never_held(spy, db)


def test_a_job_refused_at_start_tells_no_figure_that_moves_with_other_users(tmp_path, monkeypatch):
    """Review r2 7-R2-06: the ``GET /jobs`` text says what is needed, never the
    free room left after other users' reservations."""
    from tests.owned_database import add_test_user

    db, orch, coordinator, spy, track, source, job_id = _fake_world(tmp_path)
    spy._disk_usage = lambda _p: SimpleNamespace(free=10 * MIB)  # some room, not enough
    other = add_test_user(db, "bob")
    spy.reserve(owner_id=other, purpose=CONVERSION, nbytes=3 * MIB, subject_ref="other")
    monkeypatch.setattr(conv_mod, "transcode", lambda *a, **k: pytest.fail("ran"))

    conv._run_submitted(coordinator)

    text = db.get_conversion_job(job_id)["error_text"]
    assert text.startswith("Not enough free disk space"), text
    assert "available" not in text and str(7 * MIB) not in text and str(10 * MIB) not in text


# --- exits before the reservation: never held, never released ---------------------------


def _cancel_first(db, orch, track, source, job_id):
    orch.cancel(conv._lib(orch), job_id)


def _bump_revision(db, orch, track, source, job_id):
    db.apply_track_metadata_edit(track.uuid_id, {"title": "Edited"}, track.revision)


def _remove_master(db, orch, track, source, job_id):
    source.unlink()


def _squat_target(db, orch, track, source, job_id):
    source.with_suffix(".m4a").write_bytes(b"someone else")


def _pending_recovery(db, orch, track, source, job_id):
    # A row the running server cannot finish: a same-path conversion whose staged
    # copy still waits to be put in place (runtime never places converted bytes).
    # Since sign-off OPEN-6.5-05 (2026-11-16) the job first finishes the rows runtime
    # recovery can finish, so a bare row no longer stops it.
    staged = orch.staging_dir / f"{track.uuid_id}.999.tagged.flac"
    staged.parent.mkdir(parents=True, exist_ok=True)
    staged.write_bytes(b"owned")
    db.insert_journal_entry("convert", track.uuid_id, old_path=str(source), temp_path=str(staged))


@pytest.mark.parametrize(
    "before_run",
    [_cancel_first, _bump_revision, _remove_master, _squat_target, _pending_recovery],
)
def test_an_exit_before_the_job_starts_its_work_never_holds_or_releases(
    tmp_path, monkeypatch, before_run
):
    db, orch, coordinator, spy, track, source, job_id = _fake_world(tmp_path)
    before_run(db, orch, track, source, job_id)
    monkeypatch.setattr(conv_mod, "transcode", lambda *a, **k: TranscodeResult(ok=True))

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] in ("failed", "cancelled")
    _assert_never_held(spy, db)


# --- failures after the reservation (no ffmpeg) -----------------------------------------


def _transcode_fails(monkeypatch, orch, job_id):
    monkeypatch.setattr(
        conv_mod, "transcode", lambda *a, **k: TranscodeResult(ok=False, stderr="boom")
    )


def _cancel_mid_transcode(monkeypatch, orch, job_id):
    def fake(src, dest, *args, **kwargs):
        dest.write_bytes(b"partial")
        orch.cancel(conv._lib(orch), job_id)
        return TranscodeResult(ok=True)

    monkeypatch.setattr(conv_mod, "transcode", fake)


def _writes_temp(src, dest, *args, **kwargs):
    dest.write_bytes(b"transcoded")
    return TranscodeResult(ok=True)


def _tag_write_fails(monkeypatch, orch, job_id):
    monkeypatch.setattr(conv_mod, "transcode", _writes_temp)

    def fail(source, dest, *args, **kwargs):
        dest.write_bytes(b"half-tagged")
        raise TagWriteError("tag write failed")

    monkeypatch.setattr(conv_mod, "write_metadata_tags", fail)


def _tagged(monkeypatch):
    monkeypatch.setattr(conv_mod, "transcode", _writes_temp)

    def tag(source, dest, *args, **kwargs):
        dest.write_bytes(b"tagged")

    monkeypatch.setattr(conv_mod, "write_metadata_tags", tag)


def _probe_fails(monkeypatch, orch, job_id):
    _tagged(monkeypatch)

    def fail(path, target_codec):
        raise conv_mod.ConversionFailed("post-conversion probe failed")

    monkeypatch.setattr(conv_mod, "_probe_intrinsic_fields", fail)


def _unexpected_error(monkeypatch, orch, job_id):
    _tagged(monkeypatch)
    monkeypatch.setattr(
        conv_mod, "_probe_intrinsic_fields", lambda path, codec: ("aac", 192.0, 44100, 2)
    )

    def boom(*args, **kwargs):
        raise RuntimeError("unexpected")

    orch.compute_identity = boom


@pytest.mark.parametrize(
    "inject",
    [_transcode_fails, _cancel_mid_transcode, _tag_write_fails, _probe_fails, _unexpected_error],
)
def test_every_failure_after_the_start_releases_the_reservation_exactly_once(
    tmp_path, monkeypatch, inject
):
    db, orch, coordinator, spy, track, source, job_id = _fake_world(tmp_path)
    inject(monkeypatch, orch, job_id)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] in ("failed", "cancelled")
    conv._assert_track_untouched(db, track, source, b"fake")
    _assert_held_once_and_released_once(spy, db)


def test_a_release_that_fails_keeps_the_jobs_own_outcome_and_leaves_the_row(
    tmp_path, monkeypatch
):
    db, orch, coordinator, spy, track, source, job_id = _fake_world(tmp_path)
    _transcode_fails(monkeypatch, orch, job_id)
    spy.release_error = sqlite3.OperationalError("database is locked")

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", "transcode failed")
    # Left for the startup reconcile (a row of this boot is never released by it
    # while this process runs; it is a dead lease after a restart).
    assert [r[3] for r in _rows(db)] == [str(job_id)]


# --- real ffmpeg: success, commit refusals, the lossless check --------------------------


def _real_world(tmp_path, case):
    db, orch, coordinator, track, source, dest, original, target, bitrate = (
        conv._cancel_race_setup(tmp_path, case)
    )
    spy = _spy(orch, db, tmp_path)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, target, bitrate, track.revision)
    return db, orch, coordinator, spy, track, source, dest, job_id


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("case", ["flac_to_aac", "mp3_to_mp3"])
def test_a_successful_conversion_releases_once(tmp_path, case):
    db, orch, coordinator, spy, track, source, dest, job_id = _real_world(tmp_path, case)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert dest.exists()
    _assert_held_once_and_released_once(spy, db)


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("case", ["flac_to_aac", "mp3_to_mp3"])
def test_a_commit_refused_by_a_cancel_releases_once(tmp_path, monkeypatch, case):
    db, orch, coordinator, spy, track, source, dest, job_id = _real_world(tmp_path, case)
    real_complete = db.complete_conversion_job

    def cancel_then_complete(*args, **kwargs):
        assert orch.cancel(conv._lib(orch), job_id) is True
        return real_complete(*args, **kwargs)

    monkeypatch.setattr(db, "complete_conversion_job", cancel_then_complete)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "cancelled"
    _assert_held_once_and_released_once(spy, db)


@pytest.mark.requires_ffmpeg
def test_a_failed_move_releases_once(tmp_path, monkeypatch):
    db, orch, coordinator, spy, track, source, dest, job_id = _real_world(tmp_path, "flac_to_aac")
    monkeypatch.setattr(conv_mod, "move_file", lambda **kwargs: False)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "failed"
    _assert_held_once_and_released_once(spy, db)


@pytest.mark.requires_ffmpeg
def test_a_track_change_under_the_lock_releases_once(tmp_path, monkeypatch):
    db, orch, coordinator, spy, track, source, dest, job_id = _real_world(tmp_path, "flac_to_aac")
    real_probe = conv_mod._probe_intrinsic_fields

    def probe_then_edit(path, target_codec):
        db.apply_track_metadata_edit(track.uuid_id, {"title": "Edited"}, track.revision)
        return real_probe(path, target_codec)

    monkeypatch.setattr(conv_mod, "_probe_intrinsic_fields", probe_then_edit)

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", conv.TRACK_CHANGED_ERROR)
    _assert_held_once_and_released_once(spy, db)


@pytest.mark.requires_ffmpeg
def test_an_in_place_identity_write_failure_keeps_the_job_done_and_releases_once(
    tmp_path, monkeypatch
):
    db, orch, coordinator, spy, track, source, dest, job_id = _real_world(tmp_path, "mp3_to_mp3")

    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "write_conversion_identity", boom)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert [e["intent"] for e in db.list_journal_entries()] == ["convert"]
    _assert_held_once_and_released_once(spy, db)


def _lossless_spy_world(tmp_path, fixtures, *, stored=None):
    db, orch, coordinator, track, source, before, compute, wakeup, job_id = _lossless_world(
        tmp_path, fixtures["flac24.flac"], "alac", stored=stored)
    spy = _spy(orch, db, tmp_path)
    return db, orch, coordinator, spy, compute, job_id


@pytest.mark.requires_ffmpeg
def test_an_audio_mismatch_releases_once(tmp_path, fixtures):
    db, orch, coordinator, spy, compute, job_id = _lossless_spy_world(tmp_path, fixtures)
    compute.rewrite_temp = _mismatched

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["error_text"] == conv_mod.AUDIO_MISMATCH_ERROR
    _assert_held_once_and_released_once(spy, db)


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize(
    "reason,error",
    [("killed", conv_mod.AUDIO_CHECK_STOPPED_ERROR), ("decode_error", conv_mod.AUDIO_UNREADABLE_ERROR)],
)
def test_an_audio_check_that_stops_or_cannot_read_back_releases_once(
    tmp_path, fixtures, reason, error
):
    db, orch, coordinator, spy, compute, job_id = _lossless_spy_world(tmp_path, fixtures)
    compute.rewrite_temp = _failed(reason)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["error_text"] == error
    _assert_held_once_and_released_once(spy, db)


@pytest.mark.requires_ffmpeg
def test_a_conversion_that_could_not_be_verified_releases_once(tmp_path, fixtures):
    db, orch, coordinator, spy, compute, job_id = _lossless_spy_world(
        tmp_path, fixtures, stored=STALE)
    orch.compute_identity = _failing_source_rehash(compute, "timeout")

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["error_text"] == conv_mod.AUDIO_UNVERIFIED_ERROR
    _assert_held_once_and_released_once(spy, db)


@pytest.mark.requires_ffmpeg
def test_a_check_unable_to_run_lets_the_job_finish_and_releases_once(tmp_path, fixtures):
    db, orch, coordinator, spy, compute, job_id = _lossless_spy_world(tmp_path, fixtures)
    compute.rewrite_temp = _failed("timeout")

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    _assert_held_once_and_released_once(spy, db)


# --- a conversion and an "upload" competing for the same bytes (exit proof 2, 7-L23) ----

UPLOAD = "test_upload"  # stand-in for the upload purposes 7A.2b/7A.3a register
register_purpose(UPLOAD, staged_quota=True)
QUOTA = StagedQuota(user_bytes=10**12, total_bytes=10**12)


def _competing_world(tmp_path, *, free, floor):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    spy = _spy(orch, db, tmp_path, free=free, floor=floor)
    source = conv._root(tmp_path) / "song.flac"
    source.write_bytes(b"fake")
    track = conv._add_track(db, source, codec="flac")
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)
    # The upload side runs on its own Database (its own connections).
    upload = StorageLedger(
        conv.OwnedTestDatabase(db.context), path=tmp_path, floor_bytes=floor, boot_id=BOOT,
        disk_usage=lambda _p: SimpleNamespace(free=free),
    )
    return db, orch, coordinator, spy, track, source, job_id, upload


def test_an_upload_reservation_first_means_the_conversion_does_not_start(
    tmp_path, monkeypatch
):
    db, orch, coordinator, spy, track, source, job_id, upload = _competing_world(
        tmp_path, free=40 * MIB, floor=10 * MIB)
    upload.reserve(owner_id=db.owner_id, purpose=UPLOAD, nbytes=20 * MIB,
                   subject_ref="item", quota=QUOTA)
    transcoded = []
    monkeypatch.setattr(conv_mod, "transcode", lambda *a, **k: transcoded.append(a))

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "failed" and transcoded == []
    assert [r[3] for r in _rows(db)] == ["item"]
    assert spy.reserved == [] and spy.released == []


def test_a_running_conversion_first_means_the_upload_reservation_is_refused(
    tmp_path, monkeypatch
):
    db, orch, coordinator, spy, track, source, job_id, upload = _competing_world(
        tmp_path, free=40 * MIB, floor=10 * MIB)
    refused = []

    def transcode_while_an_upload_tries(src, dest, *args, **kwargs):
        try:
            upload.reserve(owner_id=db.owner_id, purpose=UPLOAD, nbytes=20 * MIB,
                           subject_ref="item", quota=QUOTA)
        except InsufficientStorage as e:
            refused.append(e.code)
        return TranscodeResult(ok=False, stderr="boom")

    monkeypatch.setattr(conv_mod, "transcode", transcode_while_an_upload_tries)

    conv._run_submitted(coordinator)

    assert refused == ["insufficient_storage"]
    _assert_held_once_and_released_once(spy, db)
