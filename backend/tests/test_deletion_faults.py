"""Phase 8A.3c (spec §5 step 3 and the rollback paragraph; plan exit proofs 5
and 6; review 8-D10, 8-U06; 8A.3b hand-over (b)): faults around the
quarantine move.

- A failed rename leaves the catalog intact. The journal row is removed only
  after the original is proven intact (same ``lstat`` identity, nothing at the
  quarantine path); otherwise it is kept and the item is
  ``failed:recovery_required``.
- A recheck that fails after the move restores the master only when the
  original path is absent and the quarantine file is the journaled one; it
  never overwrites a path that was taken meanwhile. If it cannot restore, the
  journal stays, the track stays hidden and the item is
  ``failed:recovery_required``.

Permission faults use ``chmod`` on folders inside the test's own scratch area.
"""

import os
import sqlite3
from pathlib import Path

import pytest

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


# ── the rename fails ───────────────────────────────────────────────────────


@pytest.mark.requires_chmod_denial
def test_a_refused_rename_leaves_the_catalog_and_the_master_intact(world):
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    ino, data, rev = os.lstat(master).st_ino, master.read_bytes(), revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    os.chmod(master.parent, 0o500)  # EACCES on the rename out of this folder
    try:
        make_executor(world).run_one()
    finally:
        os.chmod(master.parent, 0o700)

    assert _outcome(world, op, uuid_id) == ("failed", "rename")
    assert os.lstat(master).st_ino == ino and master.read_bytes() == data
    assert journal(world, uuid_id) is None  # cleared after the original was verified
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert tombstone(world, uuid_id) is None
    assert files_under(world.music / ".deleting") == {}


def test_an_occupied_quarantine_path_is_never_overwritten(world):
    uuid_id = add_master(world, "A/a.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    q = _quarantine(world, op, uuid_id)

    def seam(name):
        if name == "after_journal":
            q.parent.mkdir(parents=True, exist_ok=True)
            q.write_bytes(b"already here")

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("failed", "rename")
    assert q.read_bytes() == b"already here"
    assert master.read_bytes() == b"master A/a.flac"
    assert journal(world, uuid_id) is None and live(world, uuid_id)


@pytest.mark.requires_chmod_denial
def test_a_failed_rename_with_an_original_that_changed_keeps_the_journal(world):
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    def seam(name):
        if name == "after_journal":
            # Another file now sits at the original path (another inode), and
            # the folder refuses the rename.
            other = master.parent / "other.tmp"
            other.write_bytes(b"master A/Album/a.flac")
            os.replace(other, master)
            os.chmod(master.parent, 0o500)

    try:
        make_executor(world, seam=seam).run_one()
    finally:
        os.chmod(master.parent, 0o700)

    assert _outcome(world, op, uuid_id) == ("failed", "recovery_required")
    assert journal(world, uuid_id) is not None
    assert not live(world, uuid_id)  # stays hidden; nothing guessed
    assert master.read_bytes() == b"master A/Album/a.flac"
    assert tombstone(world, uuid_id) is None


# ── the recheck fails after the move ───────────────────────────────────────


def _bump(world, uuid_id):
    sql(world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?", (uuid_id,))


def test_a_revision_changed_after_the_move_restores_the_master(world):
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    ino = os.lstat(master).st_ino
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))

    def seam(name):
        if name == "after_moved":
            _bump(world, uuid_id)

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("conflict", "conflict")
    assert os.lstat(master).st_ino == ino and master.read_bytes() == b"master A/Album/a.flac"
    assert not os.path.lexists(_quarantine(world, op, uuid_id))
    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev + 1000
    assert tombstone(world, uuid_id) is None


def test_a_database_failure_at_the_commit_restores_the_master(world, monkeypatch):
    uuid_id = add_master(world, "A/a.flac")
    master = path_of(world, uuid_id)
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))

    def failing(conn, uuid, *, owner_id):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(world.db, "_delete_track_in", failing)

    make_executor(world).run_one()

    assert _outcome(world, op, uuid_id) == ("busy", "busy")
    assert master.read_bytes() == b"master A/a.flac"
    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert tombstone(world, uuid_id) is None


def test_an_original_path_taken_meanwhile_is_never_overwritten(world):
    uuid_id = add_master(world, "A/a.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    q = _quarantine(world, op, uuid_id)

    def seam(name):
        if name == "after_moved":
            master.write_bytes(b"a new import took the path")
            _bump(world, uuid_id)

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("failed", "recovery_required")
    assert master.read_bytes() == b"a new import took the path"
    assert q.read_bytes() == b"master A/a.flac"  # kept for recovery
    j = journal(world, uuid_id)
    assert j is not None and j["stage"] == "moved"
    assert not live(world, uuid_id) and tombstone(world, uuid_id) is None


def test_a_quarantine_file_that_changed_is_never_restored(world):
    uuid_id = add_master(world, "A/a.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    q = _quarantine(world, op, uuid_id)

    def seam(name):
        if name == "after_moved":
            other = q.parent / "other.tmp"
            other.write_bytes(b"master A/a.flac")
            os.replace(other, q)  # same size and name, another inode
            _bump(world, uuid_id)

    make_executor(world, seam=seam).run_one()

    assert _outcome(world, op, uuid_id) == ("failed", "recovery_required")
    assert not os.path.lexists(master)
    assert q.read_bytes() == b"master A/a.flac"
    assert journal(world, uuid_id) is not None and not live(world, uuid_id)


@pytest.mark.requires_chmod_denial
def test_a_restore_that_fails_keeps_the_journal(world):
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    q = _quarantine(world, op, uuid_id)

    def seam(name):
        if name == "after_moved":
            _bump(world, uuid_id)
            os.chmod(master.parent, 0o500)  # the move back is refused

    try:
        make_executor(world, seam=seam).run_one()
    finally:
        os.chmod(master.parent, 0o700)

    assert _outcome(world, op, uuid_id) == ("failed", "recovery_required")
    assert q.read_bytes() == b"master A/Album/a.flac"
    assert not os.path.lexists(master)
    assert journal(world, uuid_id) is not None and not live(world, uuid_id)
    assert Path(journal(world, uuid_id)["quarantine_path"]) == q


# ── review r1 8-R1-10: the commit is one transaction (U04a) ────────────────


def test_a_failure_after_the_catalog_delete_inside_the_commit_rolls_everything_back(
    world, monkeypatch
):
    """The tombstone, the catalog rows, the item outcome, the job and the
    journal stage are written in one transaction: a failure after
    ``_delete_track_in`` and the item write, before the journal update, leaves
    no tombstone and a live track, and the master is put back."""
    uuid_id = add_master(world, "A/a.flac")
    master = path_of(world, uuid_id)
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    real = world.db._complete_deletion_job_if_done_in
    calls = []

    def failing(conn, owner, operation_uuid):
        calls.append(conn.execute(
            "SELECT count(*) FROM track_tombstones WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()[0])
        if len(calls) == 1:
            raise sqlite3.OperationalError("disk I/O error")
        return real(conn, owner, operation_uuid)

    monkeypatch.setattr(world.db, "_complete_deletion_job_if_done_in", failing)

    make_executor(world).run_one()

    assert calls[0] == 1  # the failure came after the tombstone was written in the transaction
    assert tombstone(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert master.read_bytes() == b"master A/a.flac"
    assert journal(world, uuid_id) is None
    # Sign-off DEV-8-17 item 4: a database error that is not "busy" ends failed.
    assert _outcome(world, op, uuid_id) == ("failed", "internal_error")
    assert sql(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == [
        ("completed",)
    ]
