"""A journal row kept after a failed identity mark is finished while the server runs.

After an in-place write the new bytes are in place and the edit is committed;
if the short identity mark then fails (for example a locked database), the
journal row is kept so recovery can mark the identity. Until that row is gone
every conversion of the track is refused and the identity worker skips it, so
waiting for a restart turns a transient fault into a lockout. The identity
worker, when idle, finishes such rows through the same per-intent recovery
startup uses. A row is finished only when its staged temp is gone (the file
operation is over) and no writer holds the track's lock (none is in flight).
"""

import sqlite3

import pytest

from app.services.track_edit import WriteMode
from app.services.track_editor import finish_kept_journal_rows
from app.services.track_locks import TrackLocks
from tests.identity_worker_fakes import make_worker
from tests.identity_worker_fixtures import make_db
from tests.identity_editor_fixtures import SpyWakeup, _editor, _identity, _world
from tests.test_identity_editor import _tag_write_marked
from tests.track_editor_fixtures import _lib


def _edit_with_a_failing_mark(monkeypatch, library, db, track, wakeup):
    def locked(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "mark_audio_identity_stale", locked)
    _editor(library, wakeup).apply_edit(
        _lib(db), track.uuid_id, {"title": "New"}, track.revision, WriteMode.db_and_master
    )
    monkeypatch.undo()
    assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]


@pytest.mark.requires_ffmpeg
def test_a_kept_row_is_finished_and_the_track_can_be_converted_again(tmp_path, monkeypatch):
    library, audio, db, track, before = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)
    _edit_with_a_failing_mark(monkeypatch, library, db, track, wakeup)
    assert _lib(db).has_journal_entry_for_uuid(track.uuid_id)

    finished = finish_kept_journal_rows(db, library, TrackLocks(), identity_signal=wakeup)

    assert finished == 1
    assert db.list_journal_entries() == []
    assert not _lib(db).has_journal_entry_for_uuid(track.uuid_id)
    assert _tag_write_marked(_identity(db, track.uuid_id))
    assert wakeup.seen == [4]  # woken after the mark committed


@pytest.mark.requires_ffmpeg
def test_a_row_whose_track_lock_is_held_is_left_for_later(tmp_path, monkeypatch):
    library, audio, db, track, before = _world(tmp_path)
    _edit_with_a_failing_mark(monkeypatch, library, db, track, None)
    locks = TrackLocks()

    with locks.lock(track.uuid_id):  # a writer for this track is in flight
        assert finish_kept_journal_rows(db, library, locks) == 0
        assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]
        assert _identity(db, track.uuid_id) == before

    assert finish_kept_journal_rows(db, library, locks) == 1
    assert db.list_journal_entries() == []


@pytest.mark.requires_ffmpeg
def test_a_row_whose_temp_still_exists_is_left_for_startup_recovery(tmp_path):
    library, audio, db, track, before = _world(tmp_path)
    staging = library / ".staging"
    staging.mkdir(parents=True, exist_ok=True)
    temp = staging / f"{track.uuid_id}.m4a"
    temp.write_bytes(b"staged bytes not yet in place")
    original = audio.read_bytes()
    _lib(db).insert_journal_entry("inplace", track.uuid_id, old_path=str(audio), temp_path=str(temp))

    assert finish_kept_journal_rows(db, library, TrackLocks()) == 0

    assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]
    assert temp.read_bytes() == b"staged bytes not yet in place"
    assert audio.read_bytes() == original
    assert _identity(db, track.uuid_id) == before


# --- the worker runs it when idle -------------------------------------------------------------------


def test_the_idle_worker_runs_the_finisher(tmp_path):
    db = make_db(tmp_path)
    calls = []
    worker = make_worker(db, journal_finisher=lambda: calls.append(1) or 0)

    assert worker.process_one().outcome == "idle"
    assert calls == [1]


def test_a_failing_finisher_never_stops_the_worker(tmp_path):
    db = make_db(tmp_path)

    def boom():
        raise sqlite3.OperationalError("database is locked")

    worker = make_worker(db, journal_finisher=boom)

    assert worker.process_one().outcome == "idle"
    assert worker.process_one().outcome == "idle"


def test_a_row_that_keeps_failing_is_logged_once_not_on_every_pass(tmp_path, monkeypatch, caplog):
    import app.services.journal_recovery as journal_recovery
    from tests.track_editor_fixtures import _add_track, _db

    db = _db(tmp_path)
    library = tmp_path / "music"
    track = _add_track(db, library / "owner" / "a.m4a", "T", "Art")
    _lib(db).insert_journal_entry("inplace", track.uuid_id, old_path=str(library / "owner" / "a.m4a"))

    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(journal_recovery, "reconcile_one", boom)
    caplog.set_level("WARNING", logger="app.services.track_editor")
    reported = set()

    for _ in range(5):
        assert finish_kept_journal_rows(db, library, TrackLocks(), reported=reported) == 0

    assert len([r for r in caplog.records if "journal finish failed" in r.getMessage()]) == 1
    assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]  # still kept for later


def test_a_new_failing_row_after_a_finished_one_is_logged_again(tmp_path, monkeypatch, caplog):
    """Journal ids are never reused (AUTOINCREMENT). A row that failed, was
    logged and was then finished must not silence a later failing row, for
    another track."""
    import app.services.journal_recovery as journal_recovery
    from tests.track_editor_fixtures import _add_track, _db

    db = _db(tmp_path)
    library = tmp_path / "music"
    first = _add_track(db, library / "owner" / "a.m4a", "A", "Art")
    second = _add_track(db, library / "owner" / "b.m4a", "B", "Art")
    real = journal_recovery.reconcile_one
    failing = {first.uuid_id}

    def flaky(database, entry, *args, **kwargs):
        if entry["uuid_id"] in failing:
            raise sqlite3.OperationalError("database is locked")
        return real(database, entry, *args, **kwargs)

    monkeypatch.setattr(journal_recovery, "reconcile_one", flaky)
    caplog.set_level("WARNING", logger="app.services.track_editor")
    reported = set()

    first_id = _lib(db).insert_journal_entry("inplace", first.uuid_id, old_path=str(library / "owner" / "a.m4a"))
    assert finish_kept_journal_rows(db, library, TrackLocks(), reported=reported) == 0
    failing.clear()
    assert finish_kept_journal_rows(db, library, TrackLocks(), reported=reported) == 1  # finished

    failing.add(second.uuid_id)
    second_id = _lib(db).insert_journal_entry("inplace", second.uuid_id, old_path=str(library / "owner" / "b.m4a"))
    assert second_id > first_id  # the finished row's id is not handed out again
    for _ in range(3):
        assert finish_kept_journal_rows(db, library, TrackLocks(), reported=reported) == 0

    warnings = [r for r in caplog.records if "journal finish failed" in r.getMessage()]
    assert len(warnings) == 2  # once for each failing row, not once in all
    # The finished row is forgotten: the set kept across passes holds only
    # rows still in the journal, so it does not grow for the server's life.
    assert reported == {journal_recovery._row_key(e) for e in db.list_journal_entries()}
    assert len(reported) == 1


def test_a_journal_id_is_not_handed_out_again_after_the_table_empties_and_the_server_restarts(tmp_path):
    """A row's "(recovered <id>)" file name carries its id, so a later row
    must never get an earlier row's id. Without AUTOINCREMENT SQLite gives the
    highest id in the table plus one, which is 1 again once the table is empty."""
    from tests.track_editor_fixtures import _add_track, _db

    db = _db(tmp_path)
    old_path = str(tmp_path / "music" / "owner" / "a.m4a")
    track = _add_track(db, tmp_path / "music" / "owner" / "a.m4a", "A", "Art")
    first_id = _lib(db).insert_journal_entry("inplace", track.uuid_id, old_path=old_path)
    _lib(db).delete_journal_entry(first_id)

    restarted = _db(tmp_path)  # the next start opens the same file
    assert restarted.list_journal_entries() == []
    later_id = _lib(restarted).insert_journal_entry("inplace", track.uuid_id, old_path=old_path)

    assert later_id > first_id
