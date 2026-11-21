"""Review r1 m-R1-09 and m-R1-10: a delete that fails part-way.

- Art a user's track gained after step 1's capture (for example from the
  startup backfill while the user was left ``deleting``) is still released by
  step 3, so neither its row nor its file leaks.
- An ``OSError`` in step 2 (a file that cannot be removed) is reported by the
  CLI as a clean error, not a traceback; the user stays ``deleting``.
- Step 2 reads the user's UUIDs with reads that raise: a failed read aborts
  the step (and a rerun redoes it) instead of silently skipping the staging
  and transcode-cache cleanup.
"""

import re
import shutil
import sqlite3

import pytest

from app.services import user_delete
from app.services.user_delete import DeletePaths, run_user_delete
from tests.cli_fixtures import cli_settings, run_cli, sql
from tests.crash import Crash
from tests.user_delete_world import build_world


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return build_world(cli_settings(tmp_path))


def _paths(world):
    return DeletePaths.from_settings(world.settings)


def _crash_after_mark(world, monkeypatch):
    original = list(user_delete.STEPS)

    def crashing(*args, **kwargs):
        original[0](*args, **kwargs)
        raise Crash()

    monkeypatch.setattr(user_delete, "STEPS", [crashing, *original[1:]])
    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, _paths(world))
    monkeypatch.setattr(user_delete, "STEPS", original)


def test_art_gained_after_the_capture_is_released(world, monkeypatch):
    _crash_after_mark(world, monkeypatch)
    late = world.settings.app_data_dir / "cover_art" / ("f" * 64 + ".jpg")
    late.write_bytes(b"late art")
    late_id = world.db.insert_cover_art(
        sha256="f" * 64, phash="1" * 16, phash_prefix="11", file_path=str(late)
    )
    sql(world.db, "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ?",
        (late_id, world.sam_uuids[0]))

    run_user_delete(world.db, world.sam, _paths(world))

    assert sql(world.db, "SELECT count(*) FROM cover_arts WHERE id = ?", (late_id,)) == [(0,)]
    assert not late.exists()
    assert world.art["a"][1].exists()  # still Alex's


def test_an_os_error_in_step_2_is_a_clean_cli_error(world, tmp_path, monkeypatch):
    real_rmtree = shutil.rmtree

    def refuse(path, *args, **kwargs):
        if str(path) == str(world.files["sam_music"]):
            raise PermissionError(13, "Permission denied", str(path))
        return real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(user_delete.shutil, "rmtree", refuse)

    result = run_cli(world.settings, tmp_path, "users", "delete", "Sam", confirm=lambda _: "Sam")

    assert result.code == 1
    assert "Permission denied" in result.err
    assert "Traceback" not in result.err
    assert world.db.get_user(world.sam)["deleting_at"] is not None


_UUID_READ = re.compile(r"uuid_id\s+FROM\s+(tracks|track_tombstones)\b", re.IGNORECASE)


@pytest.mark.parametrize("table", ["tracks", "track_tombstones"])
def test_a_failed_uuid_read_aborts_step_2(world, monkeypatch, table):
    """A transient ``database is locked`` on the UUID read must not be read
    as "the user has no tracks"."""
    real_connect = sqlite3.connect

    class Locked(sqlite3.Connection):
        def execute(self, statement, *args):
            match = _UUID_READ.search(statement)
            if match and match.group(1) == table:
                raise sqlite3.OperationalError("database is locked")
            return super().execute(statement, *args)

    monkeypatch.setattr(
        "app.database.core.sqlite3.connect",
        lambda *a, **k: real_connect(*a, factory=Locked, **k),
    )

    with pytest.raises(sqlite3.OperationalError):
        run_user_delete(world.db, world.sam, _paths(world))

    monkeypatch.undo()
    assert world.files["sam_cache"].exists()  # untouched, so a rerun can find it
    assert world.db.get_user(world.sam)["deleting_at"] is not None
    assert sql(world.db, "SELECT count(*) FROM tracks WHERE owner_id = ?", (world.sam,)) == [(2,)]
