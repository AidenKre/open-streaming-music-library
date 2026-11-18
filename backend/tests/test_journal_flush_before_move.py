"""The journal row is on disk before a file moves (sign-off s8-journal-flush).

The user's decision of 2026-11-17: "Add the flush." A tag edit that moves the
file and a conversion that changes its path insert their ``edit_journal`` row
(a commit, not yet flushed to disk at ``synchronous=NORMAL`` in WAL mode), then
move the staged copy to the new path. A power cut could keep the move and lose
the row and the later commit: the track keeps its old file and a second copy
sits at the new path with no row and no track. Both writers now take a durable
point between the row insert and the move. Best effort, like decision D10: when
it answers False or raises, the operation goes ahead and one path-free operator
line (entry id and track uuid) says so; it never fails the edit or the job.

Startup recovery moves staged copies too, and a row it reads may itself be only
in the page cache (the process was killed, then the power failed during
recovery). It takes one durable point before the first row is settled, only when
rows exist; a failure does not keep any row by itself (the per-row point, K1,
still guards every deletion).
"""

import logging
import sqlite3

import pytest

import tests.test_conversion as conv
from app.services.track_edit import WriteMode
from app.services.track_editor import PendingOldMasters, TrackEditor, reconcile_journal
from tests.test_identity_editor import _world
from tests.test_journal_settle import C_TEMP, INITIAL, _add, _db_path, _rows, fake_read, run, world
from tests.test_track_editor import _db, _lib

OPERATOR = "uvicorn.error"
FAILURES = [False, sqlite3.OperationalError("database is locked")]
FAILURE_IDS = ["answers-false", "raises"]


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


def _answering(answers, record):
    """A ``make_durable`` stand-in: calls ``record()`` and answers from ``answers``
    (True/False or an exception to raise), the last one repeating."""
    seen = []

    def fake(*args, **kwargs):
        seen.append(record())
        answer = answers[min(len(seen) - 1, len(answers) - 1)]
        if isinstance(answer, BaseException):
            raise answer
        return answer

    return fake, seen


def _move_edit(library, db, track):
    return TrackEditor(library, library / ".staging", pending_old_masters=PendingOldMasters()).apply_edit(
        _lib(db), track.uuid_id, {"artist": "New"}, db.get_track_by_uuid(track.uuid_id).revision,
        WriteMode.db_and_master,
    )


def _row_ids(db):
    return [e["id"] for e in db.list_journal_entries()]


# --- the moving tag edit ---------------------------------------------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_moving_edit_flushes_its_journal_row_before_the_move(tmp_path, monkeypatch):
    library, audio, db, track, _ = _world(tmp_path)
    dest = library / "owner" / "New" / audio.name
    fake, seen = _answering([True], lambda: (
        len(_row_ids(db)), db.get_track_file_path(track.uuid_id), audio.exists(), dest.exists()))
    monkeypatch.setattr(db, "make_durable", fake)

    _move_edit(library, db, track)

    assert seen == [
        (1, str(audio), True, False),  # the row is in, nothing has moved, nothing committed
        (1, str(dest), True, True),  # after the commit, before the old file goes (Part 1)
    ]
    assert not audio.exists() and dest.exists() and db.list_journal_entries() == []


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("failure", FAILURES, ids=FAILURE_IDS)
def test_a_moving_edit_whose_first_flush_failed_goes_ahead_and_logs_one_line(
    tmp_path, monkeypatch, caplog, failure
):
    library, audio, db, track, _ = _world(tmp_path)
    dest = library / "owner" / "New" / audio.name
    fake, seen = _answering([failure, True], lambda: _row_ids(db))
    monkeypatch.setattr(db, "make_durable", fake)

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        revision, written = _move_edit(library, db, track)

    assert written is True and revision == db.get_track_by_uuid(track.uuid_id).revision
    assert db.get_track_file_path(track.uuid_id) == str(dest) and dest.exists()
    assert not audio.exists()  # the second point answered True: today's end state
    assert db.list_journal_entries() == []
    [entry_id] = seen[0]
    [line] = _operator_lines(caplog)
    assert track.uuid_id in line and str(entry_id) in line and "flush" in line
    assert str(tmp_path) not in line and audio.name not in line and "Art" not in line


# --- the path-changing conversion ------------------------------------------------------------------


def _flac_track(tmp_path):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / "song.flac"
    conv._make_audio(source, codec="flac")
    track = conv._add_track(db, source, codec="flac")
    return db, orch, coordinator, source, track


@pytest.mark.requires_ffmpeg
def test_a_path_changing_conversion_flushes_its_journal_row_before_the_move(tmp_path, monkeypatch):
    db, orch, coordinator, source, track = _flac_track(tmp_path)
    dest = source.with_suffix(".m4a")
    fake, seen = _answering([True], lambda: (
        len(_row_ids(db)), db.get_track_file_path(track.uuid_id), source.exists(), dest.exists()))
    monkeypatch.setattr(db, "make_durable", fake)

    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)
    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert seen == [
        (1, str(source), True, False),  # the row is in, nothing has moved, nothing committed
        (1, str(dest), True, True),  # after the commit, before the original goes (Part 1)
    ]
    assert not source.exists() and dest.exists() and db.list_journal_entries() == []


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("failure", FAILURES, ids=FAILURE_IDS)
def test_a_conversion_whose_first_flush_failed_goes_ahead_and_logs_one_line(
    tmp_path, monkeypatch, caplog, failure
):
    db, orch, coordinator, source, track = _flac_track(tmp_path)
    dest = source.with_suffix(".m4a")
    fake, seen = _answering([failure, True], lambda: _row_ids(db))
    monkeypatch.setattr(db, "make_durable", fake)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "aac", 192, track.revision)

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert db.get_track_file_path(track.uuid_id) == str(dest) and dest.exists()
    assert not source.exists()  # the second point answered True: today's end state
    assert db.list_journal_entries() == []
    [entry_id] = seen[0]
    [line] = _operator_lines(caplog)
    assert track.uuid_id in line and str(entry_id) in line and "flush" in line
    assert str(tmp_path) not in line and "song" not in line


# --- startup recovery ------------------------------------------------------------------------------


def _two_rows_that_need_no_point_of_their_own(tmp_path):
    """Convert row 15 (the track at N, its file missing, the staged copy present:
    the copy moves to N) and an in-place row with nothing to replace (mark, drop).
    Neither deletes anything, so neither takes a durable point of its own."""
    w = world(tmp_path, intent="convert", db_at="N", o=0, n=0, t=1)
    other = w.root / "Two" / "two.m4a"
    other.parent.mkdir()
    other.write_bytes(b"A|two")
    second = _add(w.db, other, INITIAL, title="Two")
    w.db.insert_journal_entry("inplace", second.uuid_id, str(other), None, None)
    return w


def test_startup_flushes_once_before_the_first_row_is_settled(tmp_path, monkeypatch):
    w = _two_rows_that_need_no_point_of_their_own(tmp_path)
    fake, seen = _answering([True], lambda: (
        len(_rows(w)), w.paths["T"].exists(), w.paths["N"].exists()))
    monkeypatch.setattr(w.db, "make_durable", fake)

    run(w)

    assert seen == [(2, True, False)]  # once, both rows still there, the copy not yet moved
    assert _rows(w) == []
    assert _db_path(w) == str(w.paths["N"]) and w.paths["N"].read_bytes() == C_TEMP


def test_startup_with_no_rows_takes_no_durable_point(tmp_path, monkeypatch):
    db = _db(tmp_path)
    calls = []
    monkeypatch.setattr(db, "make_durable", lambda *a, **k: calls.append(1) or True)

    reconcile_journal(db, tmp_path, read_audio=fake_read)

    assert calls == []


@pytest.mark.parametrize("failure", FAILURES, ids=FAILURE_IDS)
def test_a_failed_startup_flush_lets_recovery_go_ahead_with_one_line(
    tmp_path, monkeypatch, caplog, failure
):
    w = _two_rows_that_need_no_point_of_their_own(tmp_path)
    fake, seen = _answering([failure], lambda: None)
    monkeypatch.setattr(w.db, "make_durable", fake)

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        run(w)

    assert len(seen) == 1
    assert _rows(w) == []  # the failure keeps no row by itself
    assert _db_path(w) == str(w.paths["N"]) and w.paths["N"].read_bytes() == C_TEMP
    lines = _operator_lines(caplog)
    assert len([line for line in lines if "flush" in line]) == 1
    for line in lines:
        assert str(tmp_path) not in line and "song" not in line and "two" not in line
