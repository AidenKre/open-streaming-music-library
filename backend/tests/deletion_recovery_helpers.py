"""Helpers for the 8A.3d recovery tests: crash the real executor at a seam,
then run recovery on a fresh ``Database`` over the same file (an independent
connection, like a restarted process)."""

import shutil
import sqlite3

import pytest

from app.database import DatabaseContext
from app.database.database import Database
from app.services import deletion_recovery
from app.services.deletion_recovery import DeletionJanitor
from app.services.deletion_worker import DeletionExecutor
from app.services.track_locks import TrackLocks
from app.services.upload_publish import SimulatedCrash
from tests.deletion_world import (
    accept_job,
    add_master,
    files_under,
    journal,
    make_executor,
    revision,
)
from tests.schema_fixtures import INIT_SQL

NEW_BOOT = "boot-after-restart"


def crash_at(point):
    def seam(name):
        if name == point:
            raise SimulatedCrash(point)

    return seam


def run_until_crash(world, point, **overrides):
    with pytest.raises(SimulatedCrash):
        make_executor(world, seam=crash_at(point), **overrides).run_one()


def restarted_db(world):
    return Database(
        DatabaseContext(database_path=world.db.context.database_path, init_sql_path=INIT_SQL)
    )


def janitor(world, seam=None):
    """The janitor of a restarted process: its own connection and boot id."""
    database = restarted_db(world)
    executor = DeletionExecutor(
        database,
        music_library_dir=world.music,
        track_locks=world.locks,
        cover_art=world.cover_art,
        cache=world.cache,
        default_cache=world.default_cache,
        boot_id=NEW_BOOT,
        lock_timeout_s=0,
        seam=seam,
    )
    return DeletionJanitor(database, executor=executor, music_library_dir=world.music)


def recover(world, *, locks=None, database=None):
    deletion_recovery.reconcile_deletion_journals(
        database or restarted_db(world),
        music_library_dir=world.music,
        track_locks=locks or TrackLocks(),
        boot_id=NEW_BOOT,
    )


def crashed_at(world, point, rel="Portishead/Dummy/01 Mysterons.flac", *, owner=None, **kwargs):
    """A one-track job of ``owner`` crashed at ``point``: (uuid, revision, op)."""
    uuid_id = add_master(world, rel, owner=owner, **kwargs)
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev), owner=owner)
    run_until_crash(world, point)
    assert journal(world, uuid_id) is not None
    return uuid_id, rev, op


class DatabaseSnapshot:
    """OPEN-8-01: a power cut that loses the last commits. ``take()`` copies
    the database (SQLite's backup API: every committed row, WAL included) at a
    seam before a commit; ``restore()`` puts that copy back with no WAL, so the
    commits made after ``take()`` are lost while every file operation stays.
    Only files inside the test's own temporary directory are touched."""

    def __init__(self, world):
        self._path = world.db.context.database_path
        # Named like the database so ``disk()`` leaves it out.
        self._copy = self._path.with_name(self._path.name + ".snapshot")
        self.taken = False

    def take(self) -> None:
        source = sqlite3.connect(self._path)
        target = sqlite3.connect(self._copy)
        try:
            source.backup(target)
        finally:
            target.close()
            source.close()
        self.taken = True

    def restore(self) -> None:
        assert self.taken, "the snapshot seam was never reached"
        for suffix in ("-wal", "-shm"):
            sidecar = self._path.with_name(self._path.name + suffix)
            if sidecar.exists():
                sidecar.unlink()
        shutil.copyfile(self._copy, self._path)


def snapshot_then_crash(snapshot, *, take_at, crash_at_point=None):
    """A seam that takes ``snapshot`` at ``take_at`` and, if given, stops the
    executor dead at ``crash_at_point`` (a later seam)."""

    def seam(name):
        if name == take_at:
            snapshot.take()
        if name == crash_at_point:
            raise SimulatedCrash(name)

    return seam


def disk(world):
    """Every regular file under the test root except the database itself."""
    return {
        name: data
        for name, data in files_under(world.tmp).items()
        if not name.startswith("db.sqlite")
    }
