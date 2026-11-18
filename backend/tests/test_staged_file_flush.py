"""A staged file's contents reach the disk before they can replace a master.

Sign-off OPEN-A-03 follow-up (reviews F1 / flush#1). Recovery accepts a regular
file at the database's path as proof that a move landed, and redoes a pending
in-place replace from the staged copy. Both trust the staged file's *contents*.
So every writer that produces a staged copy (tag edit, conversion) forces its
data to stable storage (``durable_fs.fsync_file``: ``F_FULLFSYNC`` on macOS,
``fsync`` elsewhere) before the first step that can later make the old copy
deletable: the database commit or the journal row, whichever comes first. A
flush that fails fails the operation: nothing is replaced, the original stays.
Recovery's redo flushes the staged copy before the replace, and only replays a
staged copy that is a regular file (F5).
"""

import errno
import fcntl
import os
import sys
from pathlib import Path

import pytest

import tests.test_conversion as conv
from app.core import durable_fs
from app.services.track_edit import WriteMode
from app.services.track_editor import MasterWriteError, reconcile_journal
from tests.test_identity_editor import _editor, _world
from tests.test_track_editor import _add_track, _db, _lib

_WRITERS = ("app.services.track_editor", "app.services.conversion")


def _spy(monkeypatch, probe, fail=False):
    calls = []

    def fake(path):
        calls.append((Path(path), probe()))
        if fail:
            raise OSError(errno.EIO, "flush failed")

    patched = 0
    for name in _WRITERS:
        module = sys.modules[name]
        if hasattr(module, "fsync_file"):
            monkeypatch.setattr(module, "fsync_file", fake)
            patched += 1
    assert patched == len(_WRITERS), "a writer does not use durable_fs.fsync_file"
    return calls


def _staged(library):
    staging = library / ".staging"
    return sorted(staging.iterdir()) if staging.is_dir() else []


# --- the helper ----------------------------------------------------------------------------------


def test_the_helper_issues_a_full_flush_on_macos_and_fsync_elsewhere(tmp_path, monkeypatch):
    f = tmp_path / "staged.m4a"
    f.write_bytes(b"data")
    seen = []
    monkeypatch.setattr(durable_fs.os, "fsync", lambda fd: seen.append("fsync"))
    if sys.platform == "darwin":
        real = fcntl.fcntl
        monkeypatch.setattr(
            durable_fs.fcntl, "fcntl",
            lambda fd, op, *a: seen.append("full") if op == fcntl.F_FULLFSYNC else real(fd, op, *a))
        durable_fs.fsync_file(f)
        assert seen == ["full"]
    else:
        durable_fs.fsync_file(f)
        assert seen == ["fsync"]


@pytest.mark.skipif(sys.platform != "darwin", reason="F_FULLFSYNC is macOS only")
def test_a_file_system_without_a_full_flush_falls_back_to_fsync(tmp_path, monkeypatch):
    f = tmp_path / "staged.m4a"
    f.write_bytes(b"data")
    seen = []
    monkeypatch.setattr(durable_fs.os, "fsync", lambda fd: seen.append("fsync"))

    def refuse(fd, op, *a):
        raise OSError(errno.ENOTSUP, "not supported")

    monkeypatch.setattr(durable_fs.fcntl, "fcntl", refuse)
    durable_fs.fsync_file(f)
    assert seen == ["fsync"]


def test_the_helper_reports_a_file_it_cannot_flush(tmp_path):
    with pytest.raises(OSError):
        durable_fs.fsync_file(tmp_path / "missing.m4a")


# --- tag edits -----------------------------------------------------------------------------------


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("fields", [{"artist": "New"}, {"title": "New"}], ids=["relocate", "in-place"])
def test_an_edit_flushes_its_staged_copy_before_the_journal_or_the_commit(tmp_path, monkeypatch, fields):
    library, audio, db, track, before = _world(tmp_path)
    calls = _spy(monkeypatch, lambda: (
        len(db.list_journal_entries()), db.get_track_by_uuid(track.uuid_id).revision))

    _editor(library).apply_edit(_lib(db), track.uuid_id, fields, track.revision, WriteMode.db_and_master)

    [(path, state)] = calls
    assert path.parent == library / ".staging"
    assert state == (0, track.revision)  # nothing journaled, nothing committed yet


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("fields", [{"artist": "New"}, {"title": "New"}], ids=["relocate", "in-place"])
def test_an_edit_whose_staged_copy_cannot_be_flushed_fails_and_changes_nothing(
    tmp_path, monkeypatch, fields
):
    library, audio, db, track, before = _world(tmp_path)
    original = audio.read_bytes()
    _spy(monkeypatch, lambda: None, fail=True)

    with pytest.raises(MasterWriteError):
        _editor(library).apply_edit(_lib(db), track.uuid_id, fields, track.revision, WriteMode.db_and_master)

    after = db.get_track_by_uuid(track.uuid_id)
    assert after.revision == track.revision and after.metadata.title == "Old"
    assert str(after.file_path) == str(audio) and audio.read_bytes() == original
    assert db.list_journal_entries() == []
    assert _staged(library) == []


# --- conversions ---------------------------------------------------------------------------------


def _conversion(tmp_path, codec, target, bitrate):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / f"song.{ 'flac' if codec == 'flac' else 'mp3'}"
    conv._make_audio(source, codec=codec)
    track = conv._add_track(db, source, codec=codec, bitrate_kbps=192.0)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, target, bitrate, track.revision)
    return db, coordinator, track, source, job_id


CONVERSIONS = [("flac", "aac", 192), ("mp3", "mp3", 128)]


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("codec,target,bitrate", CONVERSIONS, ids=["relocate", "in-place"])
def test_a_conversion_flushes_its_staged_copy_before_the_journal_or_the_commit(
    tmp_path, monkeypatch, codec, target, bitrate
):
    db, coordinator, track, source, job_id = _conversion(tmp_path, codec, target, bitrate)
    calls = _spy(monkeypatch, lambda: (
        len(db.list_journal_entries()), db.get_track_by_uuid(track.uuid_id).revision))

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    [(path, state)] = calls
    assert path.parent == tmp_path / ".staging" and ".tagged." in path.name
    assert state == (0, track.revision)


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("codec,target,bitrate", CONVERSIONS, ids=["relocate", "in-place"])
def test_a_conversion_whose_staged_copy_cannot_be_flushed_fails_and_changes_nothing(
    tmp_path, monkeypatch, codec, target, bitrate
):
    db, coordinator, track, source, job_id = _conversion(tmp_path, codec, target, bitrate)
    original = source.read_bytes()
    _spy(monkeypatch, lambda: None, fail=True)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "failed"
    after = db.get_track_by_uuid(track.uuid_id)
    assert after.revision == track.revision and str(after.file_path) == str(source)
    assert source.read_bytes() == original
    assert db.list_journal_entries() == []
    assert conv._staging_files(tmp_path) == []


# --- recovery's redo of an in-place replace --------------------------------------------------------


def _inplace_row(tmp_path, intent):
    db = _db(tmp_path)
    (tmp_path / "owner").mkdir()
    target = tmp_path / "owner" / "song.m4a"
    target.write_bytes(b"stale")
    temp = tmp_path / ".staging" / "temp.m4a"
    temp.parent.mkdir()
    temp.write_bytes(b"fresh")
    track = _add_track(db, target, "T", "Art")
    db.insert_journal_entry(intent, track.uuid_id, str(target), None, str(temp))
    return db, target, temp


@pytest.mark.parametrize("intent", ["inplace", "convert"])
def test_recovery_flushes_the_staged_copy_before_replaying_it(tmp_path, monkeypatch, intent):
    db, target, temp = _inplace_row(tmp_path, intent)
    calls = _spy(monkeypatch, lambda: target.read_bytes())

    reconcile_journal(db, tmp_path)

    assert calls == [(temp, b"stale")]
    assert target.read_bytes() == b"fresh" and db.list_journal_entries() == []


@pytest.mark.parametrize("intent", ["inplace", "convert"])
def test_recovery_never_replays_a_staged_copy_it_cannot_flush(tmp_path, monkeypatch, intent):
    db, target, temp = _inplace_row(tmp_path, intent)
    _spy(monkeypatch, lambda: None, fail=True)

    reconcile_journal(db, tmp_path)

    assert target.read_bytes() == b"stale"
    assert temp.read_bytes() == b"fresh"
    assert [e["intent"] for e in db.list_journal_entries()] == [intent]


@pytest.mark.parametrize("intent", ["inplace", "convert"])
def test_recovery_never_replays_a_staged_copy_that_is_not_a_regular_file(tmp_path, intent):
    """Review F5: a symlink at the staged path would put another file in place (one
    pointing outside staging is already refused by the containment check; this one
    points at another staged file)."""
    db, target, temp = _inplace_row(tmp_path, intent)
    elsewhere = tmp_path / ".staging" / "other.m4a"
    elsewhere.write_bytes(b"another file")
    temp.unlink()
    temp.symlink_to(elsewhere)

    reconcile_journal(db, tmp_path)

    assert target.read_bytes() == b"stale"
    assert elsewhere.read_bytes() == b"another file"
    # Since OPEN-6.5-05 (2026-11-16, state-table I7): the link is never followed or
    # replayed; startup removes the link name itself and the row goes.
    assert not temp.is_symlink() and not temp.exists()
    assert db.list_journal_entries() == []
