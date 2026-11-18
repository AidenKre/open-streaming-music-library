"""OPEN-8-01 part B (user decision 2026-11-14): no file in the holding folder
is removed before the catalog commit that deleted its track is known to be on
disk. One durable point per job (the executor) and per clean-up pass (the
janitor), never one per track; when it fails nothing is removed and the
committed journal waits for the next pass.

``Database.make_durable`` is the durable point: a full WAL checkpoint with
``fullfsync`` on, True only when every frame committed before the call is in
the database file. The power-cut cases themselves are in
``test_deletion_crash_matrix.py`` (the lost-commit variants).
"""

import fcntl
import os
import shutil
import sqlite3
import sys

import pytest

from app.services.deletion_recovery import DeletionJanitor
from tests.deletion_recovery_helpers import run_until_crash
from tests.deletion_world import (
    accept_job,
    add_master,
    build_world,
    drain,
    files_under,
    item,
    journal,
    make_executor,
    path_of,
    revision,
    sql,
    tombstone,
)


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def holding(world) -> dict:
    return files_under(world.music / ".deleting")


class DurablePointSpy:
    """Stands in for ``make_durable``: records what was on disk and in the
    caches at each call, then answers ``answer`` (or raises it)."""

    def __init__(self, world, answer=True):
        self.world = world
        self.answer = answer
        self.calls = []

    def __call__(self, *args, **kwargs):
        self.calls.append(
            {
                "holding": sorted(holding(self.world)),
                "evicted": list(self.world.cache.evicted),
                # the catalog commits the point must cover are already made
                "tombstones": sql(self.world, "SELECT count(*) FROM track_tombstones")[0][0],
            }
        )
        if isinstance(self.answer, BaseException):
            raise self.answer
        return self.answer


# ── the durable point itself ────────────────────────────────────────────────


def _commit_a_row(world):
    conn = sqlite3.connect(world.db.context.database_path)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS durable_probe (x TEXT)")
        conn.execute("INSERT INTO durable_probe VALUES ('committed before the point')")
        conn.commit()
    finally:
        conn.close()


def _rows_in_the_main_file_alone(world, tmp_path):
    """Read a copy of the database file without its WAL: what a power cut
    that lost the WAL would leave."""
    copy = tmp_path / "main-file-only.sqlite"
    shutil.copyfile(world.db.context.database_path, copy)
    conn = sqlite3.connect(copy)
    try:
        return conn.execute("SELECT x FROM durable_probe").fetchall()
    except sqlite3.OperationalError:
        return None  # the table itself is not in the main file
    finally:
        conn.close()


@pytest.fixture
def keeper(world):
    """An idle second connection: without it the last connection to close
    would checkpoint the WAL by itself and hide what the durable point does."""
    conn = sqlite3.connect(world.db.context.database_path)
    conn.execute("PRAGMA journal_mode=WAL")
    yield conn
    conn.close()


@pytest.mark.real_sqlite_durability
def test_after_the_durable_point_a_commit_is_in_the_database_file_itself(world, tmp_path, keeper):
    _commit_a_row(world)
    assert _rows_in_the_main_file_alone(world, tmp_path) is None  # only in the WAL so far

    assert world.db.make_durable() is True

    assert _rows_in_the_main_file_alone(world, tmp_path) == [("committed before the point",)]


def test_the_durable_point_works_in_an_ordinary_test_too(world, tmp_path, keeper):
    _commit_a_row(world)
    assert _rows_in_the_main_file_alone(world, tmp_path) is None
    assert world.db.make_durable() is True
    assert _rows_in_the_main_file_alone(world, tmp_path) == [("committed before the point",)]


@pytest.mark.real_sqlite_durability
def test_a_reader_on_an_older_snapshot_makes_the_point_fail(world):
    _commit_a_row(world)
    reader = sqlite3.connect(world.db.context.database_path, isolation_level=None)
    try:
        reader.execute("BEGIN")
        reader.execute("SELECT count(*) FROM durable_probe").fetchone()  # holds this snapshot
        _commit_a_row(world)  # a newer frame the checkpoint cannot copy yet

        assert world.db.make_durable(timeout=0) is False
    finally:
        reader.execute("COMMIT")
        reader.close()
    assert world.db.make_durable(timeout=0) is True


@pytest.mark.real_sqlite_durability
def test_a_writer_holding_the_lock_makes_a_point_without_a_wait_fail_at_once(world):
    """s8-second-wait: ``timeout=0`` (no busy handler) never waits for the write
    lock; the checkpoint reports busy, and busy alone must answer False (every
    committed frame may already be copied, so the frame counts match)."""
    _commit_a_row(world)
    writer = sqlite3.connect(world.db.context.database_path, isolation_level=None)
    try:
        writer.execute("BEGIN IMMEDIATE")
        writer.execute("INSERT INTO durable_probe VALUES ('not committed')")

        assert world.db.make_durable(timeout=0) is False
    finally:
        writer.execute("ROLLBACK")
        writer.close()
    assert world.db.make_durable(timeout=0) is True


class _RecordingConnection(sqlite3.Connection):
    """Records, at the checkpoint statement, the connection's own sync settings."""

    seen: list = []

    def execute(self, sql, *args):
        if "wal_checkpoint" in sql:
            _RecordingConnection.seen.append(
                {
                    "statement": sql,
                    "synchronous": super().execute("PRAGMA synchronous").fetchone()[0],
                    "fullfsync": super().execute("PRAGMA fullfsync").fetchone()[0],
                }
            )
        return super().execute(sql, *args)


@pytest.mark.real_sqlite_durability
def test_the_checkpoint_syncs_with_fullfsync_and_never_with_sync_off(world, monkeypatch):
    """The guarantee rests on two settings of the checkpoint's connection: a
    synchronous level that is not OFF (SQLite's checkpoint syncs the WAL and
    the database file at NORMAL and above) and fullfsync (macOS F_FULLFSYNC).
    The product sets no synchronous of its own (pinned in
    test_sqlite_test_durability.py); this pins what the checkpoint runs with."""
    real_connect = sqlite3.connect
    _RecordingConnection.seen = []

    def connect(*args, **kwargs):
        kwargs.setdefault("factory", _RecordingConnection)
        return real_connect(*args, **kwargs)

    _commit_a_row(world)
    monkeypatch.setattr(sqlite3, "connect", connect)
    assert world.db.make_durable() is True

    assert len(_RecordingConnection.seen) == 1
    seen = _RecordingConnection.seen[0]
    assert "FULL" in seen["statement"].upper()
    assert seen["synchronous"] != 0
    assert seen["fullfsync"] == 1


@pytest.mark.real_sqlite_durability
def test_an_already_checkpointed_database_still_gets_a_full_flush(world, monkeypatch):
    """Review finding (durable point r1 #1): with one connection per call the
    last connection to close checkpoints the WAL itself, syncing with its own
    plain settings (no F_FULLFSYNC on macOS). The durable point then finds no
    work, so it must flush the database file itself: F_FULLFSYNC on macOS,
    fsync elsewhere."""
    _commit_a_row(world)  # no keeper: the close has already checkpointed
    database_file = os.stat(world.db.context.database_path)
    flushes = []
    real_fcntl, real_fsync = fcntl.fcntl, os.fsync
    full = getattr(fcntl, "F_FULLFSYNC", None)

    def spy_fcntl(fd, cmd, *args):
        if full is not None and cmd == full:
            flushes.append(("full", os.fstat(fd).st_ino))
        return real_fcntl(fd, cmd, *args)

    def spy_fsync(fd):
        flushes.append(("fsync", os.fstat(fd).st_ino))
        return real_fsync(fd)

    monkeypatch.setattr(fcntl, "fcntl", spy_fcntl)
    monkeypatch.setattr(os, "fsync", spy_fsync)

    assert world.db.make_durable() is True

    kind = "full" if sys.platform == "darwin" else "fsync"
    assert (kind, database_file.st_ino) in flushes


# ── the executor: one durable point per job, before any cleanup ─────────────


def test_a_job_has_one_durable_point_and_nothing_is_cleaned_before_it(world, monkeypatch):
    uuids = [add_master(world, f"A/{n}.flac") for n in ("one", "two", "three")]
    masters = [path_of(world, u) for u in uuids]
    op = accept_job(world, *[(u, revision(world, u)) for u in uuids])
    spy = DurablePointSpy(world)
    monkeypatch.setattr(world.db, "make_durable", spy, raising=False)

    drain(make_executor(world))

    assert len(spy.calls) == 1
    # At the point all three committed files are still in the holding folder
    # and no cache was evicted.
    assert len(spy.calls[0]["holding"]) == 3 and spy.calls[0]["evicted"] == []
    assert spy.calls[0]["tombstones"] == 3
    assert holding(world) == {} and not any(m.exists() for m in masters)
    for u in uuids:
        assert item(world, op, u)["status"] == "deleted" and item(world, op, u)["details"] == []
        assert journal(world, u) is None
    assert sorted(world.cache.evicted) == sorted(uuids)


def test_two_jobs_have_one_durable_point_each(world, monkeypatch):
    first = add_master(world, "A/first.flac")
    second = add_master(world, "A/second.flac")
    accept_job(world, (first, revision(world, first)), now=1)
    accept_job(world, (second, revision(world, second)), now=2)
    spy = DurablePointSpy(world)
    monkeypatch.setattr(world.db, "make_durable", spy, raising=False)

    drain(make_executor(world))

    assert len(spy.calls) == 2
    assert [len(c["holding"]) for c in spy.calls] == [1, 1]
    assert holding(world) == {}


def test_a_one_track_job_is_cleaned_within_its_own_step(world, monkeypatch):
    uuid_id = add_master(world, "A/x.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    spy = DurablePointSpy(world)
    monkeypatch.setattr(world.db, "make_durable", spy, raising=False)

    assert make_executor(world).run_one()

    assert len(spy.calls) == 1 and holding(world) == {}
    assert item(world, op, uuid_id)["details"] == [] and journal(world, uuid_id) is None


@pytest.mark.parametrize(
    "answer", [False, sqlite3.OperationalError("disk I/O error"), OSError("EIO")]
)
def test_a_failed_durable_point_removes_nothing_and_keeps_the_journal(world, monkeypatch, answer):
    uuid_id = add_master(world, "A/x.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    monkeypatch.setattr(world.db, "make_durable", DurablePointSpy(world, answer), raising=False)

    drain(make_executor(world))

    after = item(world, op, uuid_id)
    assert after["status"] == "deleted"
    assert "storage_cleanup_pending" in after["details"]  # the receipt claims nothing more
    assert journal(world, uuid_id)["stage"] == "committed"
    assert len(holding(world)) == 1 and not master.exists()
    assert world.cache.evicted == []
    assert tombstone(world, uuid_id) is not None

    # The next clean-up pass, with a working durable point, finishes it.
    monkeypatch.setattr(world.db, "make_durable", DurablePointSpy(world), raising=False)
    DeletionJanitor(world.db, executor=make_executor(world), music_library_dir=world.music).retry_cleanups()

    assert holding(world) == {} and journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["details"] == []


# ── the janitor: one durable point per pass ─────────────────────────────────


def _two_committed_cleanups(world):
    uuids = []
    for name in ("one", "two"):
        uuid_id = add_master(world, f"A/{name}.flac")
        accept_job(world, (uuid_id, revision(world, uuid_id)))
        run_until_crash(world, "after_commit")
        assert journal(world, uuid_id)["stage"] == "committed"
        uuids.append(uuid_id)
    assert len(holding(world)) == 2
    return uuids


def test_a_janitor_pass_has_one_durable_point_before_any_removal(world, monkeypatch):
    uuids = _two_committed_cleanups(world)
    spy = DurablePointSpy(world)
    monkeypatch.setattr(world.db, "make_durable", spy, raising=False)

    DeletionJanitor(world.db, executor=make_executor(world), music_library_dir=world.music).retry_cleanups()

    assert len(spy.calls) == 1 and len(spy.calls[0]["holding"]) == 2
    assert spy.calls[0]["tombstones"] == 2
    assert holding(world) == {}
    assert all(journal(world, u) is None for u in uuids)


def test_a_janitor_pass_whose_durable_point_fails_keeps_every_journal(world, monkeypatch):
    uuids = _two_committed_cleanups(world)
    monkeypatch.setattr(world.db, "make_durable", DurablePointSpy(world, False), raising=False)

    DeletionJanitor(world.db, executor=make_executor(world), music_library_dir=world.music).retry_cleanups()

    assert len(holding(world)) == 2
    assert all(journal(world, u)["stage"] == "committed" for u in uuids)


def test_a_janitor_pass_with_nothing_to_clean_needs_no_durable_point(world, monkeypatch):
    spy = DurablePointSpy(world)
    monkeypatch.setattr(world.db, "make_durable", spy, raising=False)

    DeletionJanitor(world.db, executor=make_executor(world), music_library_dir=world.music).retry_cleanups()

    assert spy.calls == []
