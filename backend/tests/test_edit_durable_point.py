"""A moving edit or conversion deletes the old master only after a durable point.

Bug guide A1, sign-off OPEN-6.5-05 (decision of 2026-11-16), Part 1. After a tag
edit that moves the file, or a conversion that changes its path, the database
commit that points the track at the new file is followed by the deletion of the
old master. At ``synchronous=NORMAL`` in WAL mode that commit is on disk only
after the next checkpoint, so a power cut could keep the deletion and lose the
commit. The writers now call ``Database.make_durable()`` first, as the deletion
worker does, and delete the old master only when it answers True.

When the flush answers False (or raises), the operation has still succeeded and
answers success; the old master and the journal row stay, and the old file's
identity (lstat: device, inode, size, mtime, ctime) is remembered in the
process. A later edit or conversion of the track, or the idle finisher, flushes
again and deletes the old file only while it is still that same file object
(decision D3); otherwise the row waits for startup. While the flush keeps failing
the next edit or conversion of that track is refused with the existing error
(decision D4). An in-place conversion takes a best-effort durable point before
its destructive replace (decision D10).
"""

import logging
import os
import sqlite3

import pytest

import tests.test_conversion as conv
from app.services.conversion import PendingRecovery
from app.services.track_edit import WriteMode
from app.services.track_editor import (
    MasterWriteError,
    PendingOldMasters,
    TrackEditor,
    finish_kept_journal_rows,
    reconcile_journal,
)
from app.services.track_locks import TrackLocks
from tests.test_identity_editor import _world
from tests.test_track_editor import _lib

pytestmark = pytest.mark.requires_ffmpeg

OPERATOR = "uvicorn.error"


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


def _durable(monkeypatch, db, answers):
    """``make_durable`` answers from ``answers`` (True/False or an exception to
    raise), the last one repeating; records each call."""
    calls = []

    def fake(*args, **kwargs):
        calls.append(len(calls))
        answer = answers[min(len(calls) - 1, len(answers) - 1)]
        if isinstance(answer, BaseException):
            raise answer
        return answer

    monkeypatch.setattr(db, "make_durable", fake)
    return calls


def _editor(library, pending):
    return TrackEditor(library, library / ".staging", pending_old_masters=pending)


def _move_edit(editor, db, track, artist="New"):
    return editor.apply_edit(
        _lib(db), track.uuid_id, {"artist": artist}, db.get_track_by_uuid(track.uuid_id).revision,
        WriteMode.db_and_master,
    )


def _flush_failed_edit(tmp_path, monkeypatch, caplog=None):
    """A relocating edit whose durable point answered False."""
    library, audio, db, track, _ = _world(tmp_path)
    original = audio.read_bytes()
    pending = PendingOldMasters()
    editor = _editor(library, pending)
    _durable(monkeypatch, db, [False])
    if caplog is not None:
        with caplog.at_level(logging.WARNING, logger=OPERATOR):
            result = _move_edit(editor, db, track)
    else:
        result = _move_edit(editor, db, track)
    dest = library / "owner" / "New" / audio.name
    return library, audio, original, dest, db, track, pending, editor, result


# --- the writers wait for the durable point --------------------------------------------------------


def test_a_relocating_edit_deletes_the_old_master_only_after_the_durable_point(tmp_path, monkeypatch):
    library, audio, db, track, _ = _world(tmp_path)
    dest = library / "owner" / "New" / audio.name
    seen = []

    def spy(*args, **kwargs):
        seen.append((db.get_track_file_path(track.uuid_id), audio.exists(), dest.exists()))
        return True

    monkeypatch.setattr(db, "make_durable", spy)
    _move_edit(_editor(library, PendingOldMasters()), db, track)

    # s8-journal-flush: first the row's point, before the move.
    assert seen == [(str(audio), True, False), (str(dest), True, True)]  # then after the commit, before the deletion
    assert not audio.exists() and dest.exists()
    assert db.list_journal_entries() == []


@pytest.mark.parametrize("failure", [False, sqlite3.OperationalError("database is locked")],
                         ids=["answers-false", "raises"])
def test_a_failed_flush_keeps_the_old_master_and_the_row_and_the_edit_succeeds(
    tmp_path, monkeypatch, caplog, failure
):
    library, audio, db, track, _ = _world(tmp_path)
    original = audio.read_bytes()
    dest = library / "owner" / "New" / audio.name
    _durable(monkeypatch, db, [True, failure])  # s8-journal-flush: the row's point before the move first

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        revision, written = _move_edit(_editor(library, PendingOldMasters()), db, track)

    assert written is True
    assert revision == db.get_track_by_uuid(track.uuid_id).revision
    assert db.get_track_file_path(track.uuid_id) == str(dest)
    assert dest.exists()
    assert audio.read_bytes() == original
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]
    [line] = _operator_lines(caplog)
    assert track.uuid_id in line and "flush" in line
    assert str(tmp_path) not in line and audio.name not in line


# --- a later edit, conversion or idle pass settles it ----------------------------------------------


def test_the_next_edit_of_the_track_deletes_the_old_master_once_a_flush_succeeds(tmp_path, monkeypatch):
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)
    assert audio.read_bytes() == original and len(db.list_journal_entries()) == 1
    _durable(monkeypatch, db, [True])

    _move_edit(editor, db, track, artist="Newer")

    final = library / "owner" / "Newer" / audio.name
    assert db.get_track_file_path(track.uuid_id) == str(final)
    assert final.exists() and not dest.exists() and not audio.exists()
    assert db.list_journal_entries() == []


def test_the_next_edit_is_refused_while_the_flush_still_fails(tmp_path, monkeypatch):
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)
    revision = db.get_track_by_uuid(track.uuid_id).revision

    with pytest.raises(MasterWriteError):
        _move_edit(editor, db, track, artist="Newer")

    assert db.get_track_by_uuid(track.uuid_id).revision == revision
    assert audio.read_bytes() == original and dest.exists()
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]


def test_the_idle_finisher_deletes_the_old_master_once_a_flush_succeeds(tmp_path, monkeypatch):
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)
    _durable(monkeypatch, db, [True])

    finished = finish_kept_journal_rows(db, library, TrackLocks(), pending_old_masters=pending)

    assert finished == 1
    assert not audio.exists() and dest.exists()
    assert db.get_track_file_path(track.uuid_id) == str(dest)
    assert db.list_journal_entries() == []


def test_the_idle_finisher_keeps_everything_while_the_flush_still_fails(tmp_path, monkeypatch):
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)

    finished = finish_kept_journal_rows(db, library, TrackLocks(), pending_old_masters=pending)

    assert finished == 0
    assert audio.read_bytes() == original
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]


def test_an_old_master_that_vanished_meanwhile_lets_the_row_go(tmp_path, monkeypatch):
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)
    audio.unlink()
    _durable(monkeypatch, db, [True])

    finish_kept_journal_rows(db, library, TrackLocks(), pending_old_masters=pending)

    assert dest.exists()
    assert db.list_journal_entries() == []


# --- the identity proof (decision D3) --------------------------------------------------------------


def _recreated(path, data):
    path.unlink()
    path.write_bytes(data)


def _replaced_by_rename(path, data):
    other = path.with_name("other-" + path.name)
    other.write_bytes(data)
    os.replace(other, path)


def _rewritten_same_inode(path, data):
    with open(path, "r+b") as f:
        f.write(data)


@pytest.mark.parametrize(
    "change", [_recreated, _replaced_by_rename, _rewritten_same_inode],
    ids=["unlinked-and-recreated", "another-file-renamed-onto-it", "rewritten-in-place"],
)
@pytest.mark.parametrize("settle", ["finisher", "next-edit"])
def test_a_file_at_the_old_path_that_is_no_longer_the_same_file_is_never_deleted_at_runtime(
    tmp_path, monkeypatch, change, settle
):
    """Another file at the old path (another track moving in after an outside
    removal, or the file changed) is not the operation's old master: the running
    server leaves it and the row waits for startup."""
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)
    change(audio, b"someone else's file")
    _durable(monkeypatch, db, [True])

    if settle == "finisher":
        finish_kept_journal_rows(db, library, TrackLocks(), pending_old_masters=pending)
    else:
        with pytest.raises(MasterWriteError):
            _move_edit(editor, db, track, artist="Newer")

    assert audio.read_bytes().startswith(b"someone else's file")
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]


def test_an_unregistered_row_of_the_same_shape_still_waits_for_startup(tmp_path, monkeypatch):
    """Guard: only this process's own remembered rows are settled at runtime; a
    finisher that does not know the row (another process left it) defers it."""
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)
    _durable(monkeypatch, db, [True])

    finish_kept_journal_rows(db, library, TrackLocks(), pending_old_masters=PendingOldMasters())

    assert audio.read_bytes() == original
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]


def test_startup_finishes_a_row_left_by_a_failed_flush(tmp_path, monkeypatch):
    """After a restart nothing is remembered: startup finishes the row (state-table
    row 10) and deletes the old master."""
    library, audio, original, dest, db, track, pending, editor, _ = _flush_failed_edit(
        tmp_path, monkeypatch)
    assert audio.read_bytes() == original and len(db.list_journal_entries()) == 1
    _durable(monkeypatch, db, [True])

    reconcile_journal(db, library)

    assert not audio.exists() and dest.exists()
    assert db.list_journal_entries() == []


# --- conversions -----------------------------------------------------------------------------------


def _converting(tmp_path, monkeypatch, answers):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    pending = PendingOldMasters()
    orch.pending_old_masters = pending
    source = conv._root(tmp_path) / "song.flac"
    conv._make_audio(source, codec="flac")
    track = conv._add_track(db, source, codec="flac")
    calls = _durable(monkeypatch, db, answers)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)
    return db, orch, coordinator, pending, source, track, job_id, calls


def test_a_relocating_conversion_deletes_the_original_only_after_the_durable_point(
    tmp_path, monkeypatch
):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.flac"
    conv._make_audio(source, codec="flac")
    track = conv._add_track(db, source, codec="flac")
    dest = source.with_suffix(".m4a")
    seen = []

    def spy(*args, **kwargs):
        seen.append((db.get_track_file_path(track.uuid_id), source.exists(), dest.exists()))
        return True

    monkeypatch.setattr(db, "make_durable", spy)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)
    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    # s8-journal-flush: first the row's point, before the move.
    assert seen == [(str(source), True, False), (str(dest), True, True)]
    assert not source.exists() and dest.exists()
    assert db.list_journal_entries() == []


def test_a_conversion_whose_flush_failed_is_done_and_keeps_the_original_and_the_row(
    tmp_path, monkeypatch, caplog
):
    db, orch, coordinator, pending, source, track, job_id, _ = _converting(
        tmp_path, monkeypatch, [True, False])  # s8-journal-flush: the row's point before the move first
    original = source.read_bytes()
    dest = source.with_suffix(".m4a")

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert db.get_track_file_path(track.uuid_id) == str(dest) and dest.exists()
    assert source.read_bytes() == original
    assert [e["intent"] for e in db.list_journal_entries()] == ["convert"]
    [line] = _operator_lines(caplog)
    assert track.uuid_id in line and "flush" in line and str(tmp_path) not in line


def test_the_next_conversion_settles_the_row_once_a_flush_succeeds(tmp_path, monkeypatch):
    db, orch, coordinator, pending, source, track, job_id, _ = _converting(
        tmp_path, monkeypatch, [False])
    conv._run_submitted(coordinator)
    assert source.exists() and len(db.list_journal_entries()) == 1
    _durable(monkeypatch, db, [True])
    current = db.get_track_by_uuid(track.uuid_id)

    orch.enqueue(conv._lib(orch), track.uuid_id, "mp3", 128, current.revision)

    assert not source.exists()
    assert db.list_journal_entries() == []


def test_the_next_conversion_is_refused_while_the_flush_still_fails(tmp_path, monkeypatch):
    db, orch, coordinator, pending, source, track, job_id, _ = _converting(
        tmp_path, monkeypatch, [False])
    conv._run_submitted(coordinator)
    current = db.get_track_by_uuid(track.uuid_id)

    with pytest.raises(PendingRecovery):
        orch.enqueue(conv._lib(orch), track.uuid_id, "mp3", 128, current.revision)

    assert source.exists()
    assert [e["intent"] for e in db.list_journal_entries()] == ["convert"]


def test_the_idle_finisher_settles_a_conversion_row_once_a_flush_succeeds(tmp_path, monkeypatch):
    db, orch, coordinator, pending, source, track, job_id, _ = _converting(
        tmp_path, monkeypatch, [False])
    conv._run_submitted(coordinator)
    _durable(monkeypatch, db, [True])

    finished = finish_kept_journal_rows(db, tmp_path, TrackLocks(), pending_old_masters=pending)

    assert finished == 1
    assert not source.exists()
    assert db.list_journal_entries() == []


# --- in-place conversion (decision D10) ------------------------------------------------------------


def _in_place(tmp_path):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.mp3"
    conv._make_audio(source, codec="mp3")
    track = conv._add_track(db, source, codec="mp3", bitrate_kbps=192.0)
    return db, orch, coordinator, source, track


def test_an_in_place_conversion_takes_a_durable_point_before_its_replace(tmp_path, monkeypatch):
    db, orch, coordinator, source, track = _in_place(tmp_path)
    original = source.read_bytes()
    seen = []

    def spy(*args, **kwargs):
        seen.append((len(db.list_journal_entries()), db.get_track_by_uuid(track.uuid_id).metadata.bitrate_kbps != 192.0, source.read_bytes() == original))
        return True

    monkeypatch.setattr(db, "make_durable", spy)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "mp3", 128, track.revision)
    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert seen == [(1, True, True)]  # committed (columns + row), not yet replaced
    assert source.read_bytes() != original
    assert db.list_journal_entries() == []


def test_an_in_place_conversion_whose_flush_failed_still_replaces_and_logs_once(
    tmp_path, monkeypatch, caplog
):
    db, orch, coordinator, source, track = _in_place(tmp_path)
    original = source.read_bytes()
    _durable(monkeypatch, db, [False])
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "mp3", 128, track.revision)

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert source.read_bytes() != original
    assert db.list_journal_entries() == []
    [line] = _operator_lines(caplog)
    assert track.uuid_id in line and str(tmp_path) not in line


# --- durability review (s8-recovery-settle-review-durability.md) ------------------------------------


def test_a_failed_read_back_after_a_failed_flush_still_answers_success(tmp_path, monkeypatch):
    """Review #2: remembering the old master is best effort; the edit committed and
    must answer success (the row then waits for startup)."""
    library, audio, db, track, _ = _world(tmp_path)
    original = audio.read_bytes()
    dest = library / "owner" / "New" / audio.name
    _durable(monkeypatch, db, [False])
    real = db.list_journal_entries
    calls = []

    def flaky(*args, **kwargs):
        calls.append(1)
        if len(calls) >= 2:  # the read-back after the commit
            raise sqlite3.OperationalError("database is locked")
        return real(*args, **kwargs)

    monkeypatch.setattr(db, "list_journal_entries", flaky)
    revision, written = _move_edit(_editor(library, PendingOldMasters()), db, track)
    monkeypatch.setattr(db, "list_journal_entries", real)

    assert written is True and db.get_track_file_path(track.uuid_id) == str(dest)
    assert audio.read_bytes() == original
    assert [e["intent"] for e in db.list_journal_entries()] == ["relocate"]


def test_a_symlinked_old_master_is_remembered_and_its_link_removed_after_a_flush(tmp_path, monkeypatch):
    """Review #3: a track whose master is a symbolic link (an imported link) is
    settled at runtime too: the link name goes, the file it pointed to stays."""
    library, audio, db, track, _ = _world(tmp_path)
    real_file = library / "owner" / "real.m4a"
    audio.rename(real_file)
    audio.symlink_to(real_file)
    pending = PendingOldMasters()
    editor = _editor(library, pending)
    _durable(monkeypatch, db, [False])
    _move_edit(editor, db, track)
    assert audio.is_symlink() and len(db.list_journal_entries()) == 1

    _durable(monkeypatch, db, [True])
    finish_kept_journal_rows(db, library, TrackLocks(), pending_old_masters=pending)

    assert not audio.is_symlink() and not audio.exists()
    assert real_file.exists()
    assert db.list_journal_entries() == []
