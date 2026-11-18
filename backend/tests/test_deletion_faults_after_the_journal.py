"""Deletion fault paths after the journal row exists (Phase 8A.3c review r1,
scratch review-r1.md).

- #1 (major): an exception that is not a crash (a database error, an
  unexpected OSError) after the journal row is written never leaves the item
  ``running``: a failed ``moved`` stage update is advisory and the deletion goes
  on; anything else goes through the same restore-or-``recovery_required``
  decision as a failed commit.
- #2: the file moved into quarantine must be the journaled one before the
  catalog commit; otherwise nothing is committed and the file we moved is put
  back (review r2 #2).
- #3: the restore never replaces anything at the original path, not even a
  dangling symbolic link.
- #4: an unreadable quarantine path after a failed rename is unknown, never
  "not ours": the journal is kept.
- #5: a commit that landed but reported an error is never rolled back.
"""

import os
import sqlite3
from pathlib import Path

import pytest

from app.services import file_ops
from tests.deletion_world import (
    accept_job,
    add_master,
    build_world,
    files_under,
    item,
    journal,
    live,
    make_executor,
    path_of,
    revision,
    sql,
    tombstone,
)


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def _outcome(world, op, uuid_id):
    it = item(world, op, uuid_id)
    return it["status"], it["error"]


def _quarantine(world, op, uuid_id):
    return world.music / ".deleting" / str(world.owner) / op / f"{uuid_id}.flac"


def _job(world, rel="A/Album/a.flac"):
    uuid_id = add_master(world, rel)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    return uuid_id, op, path_of(world, uuid_id)


# ── #1 ─────────────────────────────────────────────────────────────────────


def test_a_failed_moved_stage_update_does_not_stop_the_deletion(world, monkeypatch):
    uuid_id, op, master = _job(world)

    def failing(**kwargs):
        raise RuntimeError("database is locked")

    monkeypatch.setattr(world.db, "mark_deletion_moved", failing)

    make_executor(world).run_one()

    assert _outcome(world, op, uuid_id) == ("deleted", None)
    assert tombstone(world, uuid_id) is not None
    assert not os.path.lexists(master) and not os.path.lexists(_quarantine(world, op, uuid_id))
    assert journal(world, uuid_id) is None


def test_a_rename_that_raises_is_a_failed_rename_with_the_master_intact(world, monkeypatch):
    uuid_id, op, master = _job(world)

    def raising(source, destination):
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(file_ops, "move_file", raising)

    make_executor(world).run_one()

    assert _outcome(world, op, uuid_id) == ("failed", "rename")
    assert master.read_bytes() == b"master A/Album/a.flac"
    assert journal(world, uuid_id) is None and live(world, uuid_id)


def test_a_restore_that_raises_keeps_the_journal_and_ends_the_item(world, monkeypatch):
    uuid_id, op, master = _job(world)
    real_move = file_ops.move_file

    def move(source, destination):
        if Path(destination) == master:  # the move back
            raise PermissionError(13, "Permission denied")
        return real_move(source, destination)

    monkeypatch.setattr(file_ops, "move_file", move)
    monkeypatch.setattr(file_ops, "place_no_replace", _raising_link)

    def seam(name):
        if name == "after_moved":
            sql(world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?", (uuid_id,))

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("failed", "recovery_required")
    assert journal(world, uuid_id) is not None and not live(world, uuid_id)
    assert _quarantine(world, op, uuid_id).read_bytes() == b"master A/Album/a.flac"


def _raising_link(source, destination, **kwargs):  # the put-back's placement raises
    raise PermissionError(13, "Permission denied")


def test_an_unexpected_error_before_the_commit_restores_the_master(world, monkeypatch):
    uuid_id, op, master = _job(world)
    rev = revision(world, uuid_id)

    def failing(**kwargs):
        raise OSError(5, "I/O error")

    monkeypatch.setattr(world.db, "commit_track_deletion", failing)

    make_executor(world).run_one()

    # Sign-off DEV-8-17 item 4: busy only for a busy database; anything else
    # is failed (the file is put back exactly as before).
    assert _outcome(world, op, uuid_id) == ("failed", "internal_error")
    assert master.read_bytes() == b"master A/Album/a.flac"
    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev


@pytest.mark.parametrize("error, expected", [
    (sqlite3.OperationalError("database is locked"), ("busy", "busy")),
    (sqlite3.OperationalError("database table is locked"), ("busy", "busy")),
    (sqlite3.OperationalError("database is busy"), ("busy", "busy")),
    (sqlite3.OperationalError("disk I/O error"), ("failed", "internal_error")),
    (sqlite3.OperationalError("database or disk is full"), ("failed", "internal_error")),
    (sqlite3.DatabaseError("database disk image is malformed"), ("failed", "internal_error")),
    (sqlite3.IntegrityError("CHECK constraint failed"), ("failed", "internal_error")),
], ids=["locked", "table locked", "busy", "io", "full", "malformed", "integrity"])
def test_a_database_error_in_the_last_step_is_busy_only_when_the_database_was_busy(
    world, monkeypatch, error, expected
):
    """Sign-off DEV-8-17 item 4: a database error in the catalog commit, after
    the file was moved, puts the file back as before; the target ends ``busy``
    only for SQLite's busy/locked answer, otherwise ``failed:internal_error``."""
    uuid_id, op, master = _job(world)
    rev = revision(world, uuid_id)

    def failing(**kwargs):
        raise error

    monkeypatch.setattr(world.db, "commit_track_deletion", failing)

    make_executor(world).run_one()

    assert _outcome(world, op, uuid_id) == expected
    assert master.read_bytes() == b"master A/Album/a.flac"
    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert files_under(world.music) == {
        str(master.relative_to(world.music)): b"master A/Album/a.flac"}  # nothing left in holding


# ── #2 ─────────────────────────────────────────────────────────────────────


def test_a_master_replaced_before_the_rename_is_put_back_and_never_committed(world):
    # Review r2 #2: the file we just moved is not the journaled one (an outside
    # save replaced it after our lstat). It is put straight back (never
    # replacing anything), the journal is cleared and the target is a conflict.
    uuid_id, op, master = _job(world)
    rev = revision(world, uuid_id)
    saved = {}

    def seam(name):
        if name == "after_journal":
            # An outside tool saves the file by rename: a new inode at O.
            other = master.parent / "save.tmp"
            other.write_bytes(b"saved by another program")
            os.replace(other, master)
            saved["ino"] = os.lstat(master).st_ino

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("conflict", "conflict")
    assert tombstone(world, uuid_id) is None
    assert master.read_bytes() == b"saved by another program"
    assert os.lstat(master).st_ino == saved["ino"] and os.lstat(master).st_nlink == 1
    assert not os.path.lexists(_quarantine(world, op, uuid_id))
    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev


# ── #3 ─────────────────────────────────────────────────────────────────────


def test_a_dangling_symlink_at_the_original_path_is_never_replaced(world):
    uuid_id, op, master = _job(world)

    def seam(name):
        if name == "after_moved":
            master.symlink_to(world.tmp / "nowhere.flac")
            sql(world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?", (uuid_id,))

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("failed", "recovery_required")
    assert master.is_symlink() and os.readlink(master) == str(world.tmp / "nowhere.flac")
    assert _quarantine(world, op, uuid_id).read_bytes() == b"master A/Album/a.flac"
    assert journal(world, uuid_id) is not None


def test_a_restored_master_is_the_same_file_and_the_quarantine_is_empty(world):
    uuid_id, op, master = _job(world)
    ino = os.lstat(master).st_ino

    def seam(name):
        if name == "after_moved":
            sql(world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?", (uuid_id,))

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("conflict", "conflict")
    assert os.lstat(master).st_ino == ino and os.lstat(master).st_nlink == 1
    assert not os.path.lexists(_quarantine(world, op, uuid_id))
    assert journal(world, uuid_id) is None and live(world, uuid_id)


# ── #4 ─────────────────────────────────────────────────────────────────────


@pytest.mark.requires_chmod_denial
def test_an_unreadable_quarantine_path_after_a_failed_rename_keeps_the_journal(world):
    uuid_id, op, master = _job(world)
    op_dir = world.music / ".deleting" / str(world.owner) / op

    def seam(name):
        if name == "after_journal":
            op_dir.mkdir(parents=True)
            os.chmod(op_dir, 0o000)  # the rename fails, and Q cannot be looked at

    try:
        make_executor(world, seam=seam).run_one()
    finally:
        os.chmod(op_dir, 0o700)

    assert _outcome(world, op, uuid_id) == ("failed", "recovery_required")
    assert journal(world, uuid_id) is not None
    assert master.read_bytes() == b"master A/Album/a.flac"


# ── #5 ─────────────────────────────────────────────────────────────────────


def test_a_commit_that_landed_but_reported_an_error_is_never_rolled_back(world, monkeypatch):
    uuid_id, op, master = _job(world)
    real_commit = world.db.commit_track_deletion

    def landed_then_failed(**kwargs):
        real_commit(**kwargs)
        raise OSError(5, "I/O error after commit")

    monkeypatch.setattr(world.db, "commit_track_deletion", landed_then_failed)

    make_executor(world).run_one()

    assert item(world, op, uuid_id)["status"] == "deleted"
    assert tombstone(world, uuid_id) is not None
    assert not os.path.lexists(master)  # never restored over a committed deletion
    j = journal(world, uuid_id)
    assert j is not None and j["stage"] == "committed"
    assert Path(j["quarantine_path"]).read_bytes() == b"master A/Album/a.flac"
