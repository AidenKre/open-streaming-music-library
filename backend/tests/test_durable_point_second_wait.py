"""The second durable point skips its wait when the first gave up (sign-off s8-second-wait).

A tag edit that moves the file and a conversion that changes its path take two
durable points: one after the journal row insert, before the move
(s8-journal-flush), and one after the commit, before the old file is deleted
(s8-recovery-settle, Part 1). Each waits up to one second for a busy database.
The user's decision of 2026-11-17: "skip the second wait". When the first point
answered False or raised, the second tries once without waiting
(``make_durable(timeout=0)``), so the extra wait stays at about one second. If the
database became free in between, the second point works anyway and the old file
goes as usual; if it is still busy, the old file and the row are kept exactly as
when the second point fails today. When the first point succeeded, the second
waits as today.

Timing-free: a spy records the ``timeout`` each call asks for; nothing sleeps.
"""

import logging
import sqlite3

import pytest

import tests.conversion_fixtures as conv
from app.services.track_edit import WriteMode
from app.services.track_editor import PendingOldMasters, TrackEditor
from tests.identity_editor_fixtures import _world
from tests.track_editor_fixtures import _lib

pytestmark = pytest.mark.requires_ffmpeg

OPERATOR = "uvicorn.error"
WAIT = 1  # the ordinary wait of a durable point, in seconds (the contract: "up to one second")
NO_WAIT = 0
FAILURES = [False, sqlite3.OperationalError("database is locked")]
FAILURE_IDS = ["answers-false", "raises"]
NOT_GIVEN = object()


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


def _durable_spy(monkeypatch, db, answers):
    """Stands in for ``make_durable``: records the wait each call asks for (the
    ``timeout`` argument; the method's own default when none is given) and answers
    from ``answers`` (True/False or an exception to raise), the last one repeating."""
    timeouts = []

    def fake(*args, **kwargs):
        timeout = kwargs.get("timeout", NOT_GIVEN)
        timeouts.append(WAIT if timeout is NOT_GIVEN else timeout)
        answer = answers[min(len(timeouts) - 1, len(answers) - 1)]
        if isinstance(answer, BaseException):
            raise answer
        return answer

    monkeypatch.setattr(db, "make_durable", fake)
    return timeouts


class _Edit:
    """A tag edit that moves the track's file to a new folder."""

    def __init__(self, tmp_path):
        library, self.old, self.db, self.track, _ = _world(tmp_path)
        self.new = library / "owner" / "New" / self.old.name
        self.original = self.old.read_bytes()
        self.pending = PendingOldMasters()
        self.editor = TrackEditor(library, library / ".staging", pending_old_masters=self.pending)

    def run(self):
        revision, written = self.editor.apply_edit(
            _lib(self.db), self.track.uuid_id, {"artist": "New"},
            self.db.get_track_by_uuid(self.track.uuid_id).revision, WriteMode.db_and_master,
        )
        assert written is True and revision == self.db.get_track_by_uuid(self.track.uuid_id).revision


class _Conversion:
    """A flac -> aac conversion: the file's path changes (song.flac -> song.m4a)."""

    def __init__(self, tmp_path):
        self.db, self.orch, self.coordinator = conv._make_orchestrator(tmp_path)
        self.pending = PendingOldMasters()
        self.orch.pending_old_masters = self.pending
        self.old = conv._root(tmp_path) / "song.flac"
        conv._make_audio(self.old, codec="flac")
        self.track = conv._add_track(self.db, self.old, codec="flac")
        self.new = self.old.with_suffix(".m4a")
        self.original = self.old.read_bytes()

    def run(self):
        job_id = self.orch.enqueue(conv._lib(self.orch), self.track.uuid_id, "aac", 192, self.track.revision)
        conv._run_submitted(self.coordinator)
        assert self.db.get_conversion_job(job_id)["status"] == "done"


WRITERS = [_Edit, _Conversion]
WRITER_IDS = ["moving-edit", "path-changing-conversion"]


def _registered(w):
    [row] = w.db.list_journal_entries()
    return w.pending.holds(row)


@pytest.mark.parametrize("failure", FAILURES, ids=FAILURE_IDS)
@pytest.mark.parametrize("writer", WRITERS, ids=WRITER_IDS)
def test_after_a_failed_first_point_the_second_tries_once_without_waiting_and_settles_as_usual(
    tmp_path, monkeypatch, caplog, writer, failure
):
    """The database became free in between: the second point, without waiting,
    answers True, and the old file and the row go as usual."""
    w = writer(tmp_path)
    timeouts = _durable_spy(monkeypatch, w.db, [failure, True])

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        w.run()

    assert timeouts == [WAIT, NO_WAIT]
    assert w.db.get_track_file_path(w.track.uuid_id) == str(w.new) and w.new.exists()
    assert not w.old.exists()
    assert w.db.list_journal_entries() == []
    assert len(_operator_lines(caplog)) == 1  # only the first point's line


@pytest.mark.parametrize("second", FAILURES, ids=["second-" + i for i in FAILURE_IDS])
@pytest.mark.parametrize("first", FAILURES, ids=["first-" + i for i in FAILURE_IDS])
@pytest.mark.parametrize("writer", WRITERS, ids=WRITER_IDS)
def test_after_a_failed_first_point_a_second_that_fails_without_waiting_keeps_everything_as_today(
    tmp_path, monkeypatch, caplog, writer, first, second
):
    """Still busy: the old file, the row and the registry entry are kept, one
    operator line for each point, and no path in either line."""
    w = writer(tmp_path)
    timeouts = _durable_spy(monkeypatch, w.db, [first, second])

    with caplog.at_level(logging.WARNING, logger=OPERATOR):
        w.run()

    assert timeouts == [WAIT, NO_WAIT]
    assert w.db.get_track_file_path(w.track.uuid_id) == str(w.new) and w.new.exists()
    assert w.old.read_bytes() == w.original
    assert len(w.db.list_journal_entries()) == 1 and _registered(w)
    lines = _operator_lines(caplog)
    assert len(lines) == 2
    assert "moves before a database flush" in lines[0]
    assert "old file waits for a database flush" in lines[1]
    for line in lines:
        assert w.track.uuid_id in line
        assert str(tmp_path) not in line and w.old.name not in line and w.old.stem not in line


@pytest.mark.parametrize("second", [True, False], ids=["second-succeeds", "second-fails"])
@pytest.mark.parametrize("writer", WRITERS, ids=WRITER_IDS)
def test_after_a_successful_first_point_the_second_waits_as_today(
    tmp_path, monkeypatch, writer, second
):
    w = writer(tmp_path)
    timeouts = _durable_spy(monkeypatch, w.db, [True, second])

    w.run()

    assert timeouts == [WAIT, WAIT]
    assert w.old.exists() is (not second)
    assert len(w.db.list_journal_entries()) == (0 if second else 1)
    if not second:
        assert _registered(w)
