"""Sign-off DEV-7-25 link fallback (A3): after a crash, recovery proves a
moved or copied final file by the placement record (size + sha256), exactly
where it proves a hard link today: startup's first step, the runtime retry,
a preflight conflict and a recovered failure. The journal clean-up removes
the temp and then the record before the row goes."""

import errno
import os
import sqlite3
from pathlib import Path

import pytest

from app.services import organizer, upload_placement, upload_recovery
from tests.identity_worker_fixtures import make_db, sql
from tests.upload_commit_fixtures import (
    FakeCoverArt, accept, journal, library_root, make_commit_worker, ready_item,
)
from tests.upload_publish_fixtures import library_track, make_publisher, prepared_commit, track_row
from tests.upload_recovery_fixtures import World
from tests.upload_validation_fixtures import item_row

_real_link = os.link


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def _refuse(monkeypatch, err):
    def link(src, dst, *args, **kwargs):
        raise OSError(err, os.strerror(err))

    monkeypatch.setattr(organizer.os, "link", link)


def _record(commit) -> Path:
    return Path(str(commit["work"]) + ".place")


def _moved_by_fallback(db, music, *, final_bytes=None):
    """A prepared journal in the owner's library whose record was written and
    whose work file was then renamed at the final name (or, with
    ``final_bytes``, whose final name holds other bytes): the state a crash
    right after the fallback's rename leaves."""
    commit = prepared_commit(db, music)
    work = Path(commit["work"])
    work.write_bytes(b"audio-A")
    root = library_root(db, music, commit["owner_id"])
    final = root / "Artist" / f"{commit['track']}.flac"
    # Startup validation reads the journaled codec (the fixture's metadata has none).
    sql(db, "UPDATE upload_commit_journal SET final_path = ?,"
            " final_metadata = json_set(final_metadata, '$.codec', 'flac')"
            " WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), commit["owner_id"], commit["op"]))
    upload_placement.write_record(journal(db, commit), uploads_root=music / ".uploads",
                                  library_root=root, temp=False)
    final.parent.mkdir(parents=True, exist_ok=True)
    if final_bytes is None:
        os.rename(work, final)
    else:
        final.write_bytes(final_bytes)
        work.unlink()
    return commit, final


# ── startup: the first step proves a moved file by its record ───────────────

def test_startup_publishes_a_moved_file_its_record_proves(world, db, music):
    commit, final = _moved_by_fallback(db, music)

    world.recover()

    assert journal(db, commit)["state"] == "imported"
    assert track_row(db, commit["track"])["file_path"] == str(final)
    assert final.read_bytes() == b"audio-A"


def test_startup_never_takes_a_final_with_other_bytes(world, db, music):
    commit, final = _moved_by_fallback(db, music, final_bytes=b"audio-B")

    world.recover()

    row = journal(db, commit)
    assert (row["state"], row["final_path"]) == ("failed", None)  # nothing of ours was placed
    assert item_row(db, commit)["state"] == "review_ready"
    assert track_row(db, commit["track"]) is None
    assert final.read_bytes() == b"audio-B"  # never removed, never adopted


def test_startup_leaves_a_final_it_cannot_read(world, db, music, monkeypatch, caplog):
    commit, final = _moved_by_fallback(db, music)
    real_open = os.open

    def deny(path, *args, **kwargs):
        if Path(path) == final:
            raise PermissionError(errno.EACCES, "denied")
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr(os, "open", deny)

    with caplog.at_level("WARNING", logger="uvicorn.error"):
        world.recover()

    assert journal(db, commit)["state"] == "prepared"
    assert final.read_bytes() == b"audio-A"
    assert _record(commit).exists()
    assert any("could not be checked" in r.getMessage() for r in caplog.records
               if r.name == "uvicorn.error")


def test_advance_if_placed_moves_a_journal_proven_by_its_record(db, music):
    commit, _final = _moved_by_fallback(db, music)

    row = upload_recovery.advance_if_placed(
        db, journal(db, commit), uploads_root=music / ".uploads", music_library_dir=music)

    assert row["state"] == "moved"
    assert journal(db, commit)["state"] == "moved"


# ── the publisher's own proofs: preflight conflict and recovered failure ────

def test_a_preflight_conflict_removes_a_moved_file_its_record_proves(db, music):
    commit, final = _moved_by_fallback(db, music)
    library_track(db, music, b"audio-A")

    assert make_publisher(db, music)(journal(db, commit)) == "duplicate_conflict"

    assert not final.exists()
    assert item_row(db, commit)["state"] == "duplicate_conflict"


def test_a_preflight_conflict_keeps_a_final_with_other_bytes(db, music):
    commit, final = _moved_by_fallback(db, music, final_bytes=b"audio-B")
    library_track(db, music, b"audio-A")

    assert make_publisher(db, music)(journal(db, commit)) == "duplicate_conflict"

    assert final.read_bytes() == b"audio-B"
    assert journal(db, commit)["final_path"] is None


def test_a_recovered_failure_removes_a_moved_file_its_record_proves(db, music):
    commit, final = _moved_by_fallback(db, music)

    assert make_publisher(db, music).fail_recovered(journal(db, commit)) == "failed"

    row = journal(db, commit)
    assert row["state"] == "failed" and row["final_path"] == str(final)
    assert not final.exists()  # this operation's own file, removed with the failure


# ── the runtime retry takes the same first step ─────────────────────────────

class _FailsFirst:
    def __init__(self, real, times=1):
        self.real, self.times, self.calls = real, times, 0

    def __call__(self, **kwargs):
        self.calls += 1
        if self.calls <= self.times:
            raise sqlite3.OperationalError("database is locked")
        return self.real(**kwargs)


def test_the_runtime_retry_proves_a_moved_file_by_its_record(db, music, monkeypatch):
    commit = accept(db, ready_item(db, music / ".uploads", content=b"audio-A"))
    _refuse(monkeypatch, errno.ENOTSUP)
    monkeypatch.setattr(db, "mark_upload_commit_moved", _FailsFirst(db.mark_upload_commit_moved))
    monkeypatch.setattr(db, "fail_upload_publish", _FailsFirst(db.fail_upload_publish))
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "error"  # moved, then two busy errors: nothing recorded
    final = Path(journal(db, commit)["final_path"])
    assert final.is_file() and not commit["work"].exists()

    assert worker.process_one() == "imported"
    assert track_row(db, commit["track"])["file_path"] == str(final)


# ── the journal clean-up: temp first, then the record, then the row ─────────

def test_the_clean_up_removes_the_record_before_the_row(world, db, music, monkeypatch):
    commit = world.commit()
    _refuse(monkeypatch, errno.ENOTSUP)
    assert world.worker().process_one() == "imported"
    assert _record(commit).exists()

    assert upload_recovery.clean_finished_journal(
        db, journal(db, commit), uploads_root=music / ".uploads", music_library_dir=music,
        cover_art=FakeCoverArt())

    assert not _record(commit).exists()
    assert sql(db, "SELECT count(*) AS n FROM upload_commit_journal")[0]["n"] == 0


def test_a_record_that_cannot_be_removed_keeps_the_row(world, db, music, monkeypatch):
    commit = world.commit()
    _refuse(monkeypatch, errno.ENOTSUP)
    assert world.worker().process_one() == "imported"
    record = _record(commit)
    real_unlink = os.unlink

    def unlink(path, *args, **kwargs):
        if Path(path) == record:
            raise PermissionError(errno.EACCES, "denied")
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", unlink)

    assert not upload_recovery.clean_finished_journal(
        db, journal(db, commit), uploads_root=music / ".uploads", music_library_dir=music,
        cover_art=FakeCoverArt())

    assert record.exists()
    assert journal(db, commit)["state"] == "imported"


def test_a_crash_mid_copy_then_a_conflict_leaves_no_temp(world, db, music, monkeypatch):
    """The conflict clears the journal's final_path; the record still finds the temp."""
    commit = world.commit()
    _refuse(monkeypatch, errno.EXDEV)
    world.crash_at("mid_copy", commit)
    final = Path(journal(db, commit)["final_path"])
    temp = organizer.temp_name_for(final)
    assert os.path.lexists(temp)
    library_track(db, music, b"audio-A")  # a duplicate lands before the restart

    world.restart()
    world.restart()

    assert item_row(db, commit)["state"] == "duplicate_conflict"
    assert not os.path.lexists(temp)
    assert not _record(commit).exists()
    assert sql(db, "SELECT count(*) AS n FROM upload_commit_journal")[0]["n"] == 0
    root = library_root(db, music, commit["owner_id"])
    assert not [p for p in root.rglob("*")]  # the temp's empty folders are pruned too
