"""Every file-moving tag edit and conversion forces the folder change to disk.

Sign-off OPEN-A-03, the folder flush. A rename is durable only once the folders
that name the file are flushed; without it a power cut can lose the rename while
the database commit that followed it survives. Deletion and uploads already flush
(``fsync_dir``); the edit and conversion writers now do the same: the folders from
the file's new folder up to the owner's root, and the staging folder it came from,
before the step after which the old state can no longer be recovered (the
database commit for a move, the journal row's delete for an in-place replace).

The spy records which folder is flushed and the state at that moment; no real
flush runs, and nothing outside the test's temp directory is touched.
"""

import errno
import os
import stat
import sys
from pathlib import Path

import pytest

import tests.test_conversion as conv
from app.services.track_edit import WriteMode
from app.services.track_editor import reconcile_journal
from tests.test_identity_editor import _editor, _world
from tests.test_track_editor import _add_track, _db, _lib

_WRITER_MODULES = ("app.services.organizer", "app.services.track_editor", "app.services.conversion")


def _spy(monkeypatch, tmp_path, probe):
    """Replace ``fsync_dir`` wherever a writer module imported it; each call records
    the folder and ``probe()`` taken at that moment."""
    calls = []

    def fake(path):
        path = Path(path)
        assert path == tmp_path or tmp_path in path.parents, f"flushed outside the test: {path}"
        calls.append((path, probe()))

    patched = 0
    for name in _WRITER_MODULES:
        module = sys.modules.get(name)
        if module is not None and hasattr(module, "fsync_dir"):
            monkeypatch.setattr(module, "fsync_dir", fake)
            patched += 1
    assert patched, "no writer module uses fsync_dir"
    return calls


def _flushed_while(calls, condition):
    return {path for path, state in calls if condition(state)}


# --- tag edits -------------------------------------------------------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_relocating_edit_flushes_its_folders_before_the_commit(tmp_path, monkeypatch):
    library, audio, db, track, before = _world(tmp_path)
    dest = library / "owner" / "New" / audio.name  # a new folder move_file creates
    staging = library / ".staging"
    calls = _spy(monkeypatch, tmp_path, lambda: (
        db.get_track_file_path(track.uuid_id), dest.exists(), audio.exists()))

    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master)

    assert db.get_track_file_path(track.uuid_id) == str(dest)
    before_commit = _flushed_while(
        calls, lambda s: s == (str(audio), True, True))  # moved, not yet committed
    assert {dest.parent, library / "owner", staging} <= before_commit


@pytest.mark.requires_ffmpeg
def test_an_in_place_edit_flushes_its_folders_before_the_journal_row_goes(tmp_path, monkeypatch):
    library, audio, db, track, before = _world(tmp_path)
    staging = library / ".staging"
    original = audio.read_bytes()
    calls = _spy(monkeypatch, tmp_path, lambda: (
        len(db.list_journal_entries()), audio.read_bytes() != original))

    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master)

    assert db.list_journal_entries() == []
    replaced_row_kept = _flushed_while(calls, lambda s: s == (1, True))
    assert {audio.parent, staging} <= replaced_row_kept


@pytest.mark.requires_ffmpeg
def test_a_failed_flush_does_not_fail_the_edit(tmp_path, monkeypatch):
    """Best effort, like deletion and uploads: a folder that cannot be flushed
    leaves the edit to complete normally (startup recovery keeps a row whose move
    did not land, so nothing depends on the flush for safety)."""
    library, audio, db, track, before = _world(tmp_path)
    dest = library / "owner" / "New" / audio.name

    real_fsync = os.fsync

    def failing_fsync(fd):
        # Folders only: a staged file that cannot be flushed fails the edit
        # (test_staged_file_flush.py), which is not this test's case.
        if stat.S_ISDIR(os.fstat(fd).st_mode):
            raise OSError(errno.EIO, "flush failed")
        return real_fsync(fd)

    monkeypatch.setattr(os, "fsync", failing_fsync)
    _editor(library).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, track.revision, WriteMode.db_and_master)
    monkeypatch.undo()

    assert dest.exists() and not audio.exists()
    assert db.get_track_file_path(track.uuid_id) == str(dest)
    assert db.list_journal_entries() == []


# --- conversions -----------------------------------------------------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_relocating_conversion_flushes_its_folders_before_the_commit(tmp_path, monkeypatch):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.flac"
    conv._make_audio(source, codec="flac")
    track = conv._add_track(db, source, codec="flac")
    dest = source.with_suffix(".m4a")
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)
    calls = _spy(monkeypatch, tmp_path, lambda: (
        db.get_track_file_path(track.uuid_id), dest.exists(), source.exists()))

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    before_commit = _flushed_while(calls, lambda s: s == (str(source), True, True))
    assert {dest.parent, tmp_path / ".staging"} <= before_commit


@pytest.mark.requires_ffmpeg
def test_an_in_place_conversion_flushes_its_folders_before_the_journal_row_goes(tmp_path, monkeypatch):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.mp3"
    conv._make_audio(source, codec="mp3")
    track = conv._add_track(db, source, codec="mp3", bitrate_kbps=192.0)
    original = source.read_bytes()
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "mp3", 128, track.revision)
    calls = _spy(monkeypatch, tmp_path, lambda: (
        len(db.list_journal_entries()), source.read_bytes() != original))

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    replaced_row_kept = _flushed_while(calls, lambda s: s == (1, True))
    assert {source.parent, tmp_path / ".staging"} <= replaced_row_kept


# --- recovery's own replace ------------------------------------------------------------------------


@pytest.mark.parametrize("intent", ["inplace", "convert"])
def test_recovery_flushes_a_redone_replace_before_the_journal_row_goes(tmp_path, monkeypatch, intent):
    db = _db(tmp_path)
    (tmp_path / "owner").mkdir()
    target = tmp_path / "owner" / "song.m4a"
    target.write_bytes(b"stale")
    temp = tmp_path / ".staging" / "temp.m4a"
    temp.parent.mkdir()
    temp.write_bytes(b"fresh")
    track = _add_track(db, target, "T", "Art")
    db.insert_journal_entry(intent, track.uuid_id, str(target), None, str(temp))
    calls = _spy(monkeypatch, tmp_path, lambda: (
        len(db.list_journal_entries()), target.read_bytes() == b"fresh"))

    reconcile_journal(db, tmp_path)

    assert target.read_bytes() == b"fresh" and db.list_journal_entries() == []
    replaced_row_kept = _flushed_while(calls, lambda s: s == (1, True))
    assert {target.parent, temp.parent} <= replaced_row_kept
