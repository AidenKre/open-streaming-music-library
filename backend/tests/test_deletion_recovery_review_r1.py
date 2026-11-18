"""Phase 8A.3d review r1 regressions.

- #1 (major): when the journal step cannot resolve a row (an exception such
  as a library without hard links, or a skipped row), its item is never left
  ``running`` under a dead lease: it is ``failed:recovery_required``, the job
  completes, the journal and every file stay (no stuck job, track hidden).
- #2: a journal row whose operation or track id is not a plain UUID never
  makes recovery follow a path through folders it did not check.
- #3: a committed clean-up whose original path is no longer usable (a folder
  on the way replaced by a symlink) still unlinks the proven quarantine file;
  pruning never leaves the owner's root.
- nit #6: committed journals the janitor has to keep are counted in the
  operator log (count only).
"""

import logging
import os
import shutil

import pytest

from app.services import organizer
from app.services.deletion_recovery import DeletionJanitor
from app.services.deletion_worker import DeletionExecutor
from tests.deletion_recovery_helpers import NEW_BOOT, crashed_at, disk, recover, restarted_db
from tests.deletion_world import build_world, item, journal, live, path_of, sql


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def janitor(world):
    database = restarted_db(world)
    executor = DeletionExecutor(
        database, music_library_dir=world.music, track_locks=world.locks,
        cover_art=world.cover_art, cache=world.cache, default_cache=world.default_cache,
        boot_id=NEW_BOOT, lock_timeout_s=0,
    )
    return DeletionJanitor(database, executor=executor, music_library_dir=world.music)


def test_a_put_back_that_raises_never_strands_the_item(world, monkeypatch):
    """Link fallback (sign-off DEV-7-25 Part B): a library without hard links now
    gets the file renamed back; a link refused for another reason (EIO) still
    raises, and that is what this case pins."""
    uuid_id, rev, op = crashed_at(world, "after_rename")
    q = journal(world, uuid_id)["quarantine_path"]

    def failing_link(*args, **kwargs):
        raise OSError(5, "Input/output error")

    monkeypatch.setattr(organizer.os, "link", failing_link)
    before = (journal(world, uuid_id), disk(world))

    recover(world)
    recover(world)

    assert (journal(world, uuid_id), disk(world)) == before
    assert os.path.exists(q) and not path_of(world, uuid_id).exists()
    assert not live(world, uuid_id)
    after = item(world, op, uuid_id)
    assert (after["status"], after["error"]) == ("failed", "recovery_required")
    assert sql(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == [
        ("completed",)
    ]


@pytest.mark.parametrize("step", ["journal step", "janitor"])
def test_an_operation_id_with_a_slash_never_walks_through_an_unchecked_folder(world, step):
    point = "after_rename" if step == "journal step" else "after_commit"
    uuid_id, rev, op = crashed_at(world, point)
    q = journal(world, uuid_id)["quarantine_path"]
    outside = world.tmp / "outside"
    (outside / "y").mkdir(parents=True)
    planted = outside / "y" / os.path.basename(q)
    os.rename(q, planted)
    owner_q = world.music / ".deleting" / str(world.owner)
    os.symlink(outside, owner_q / "x")
    forged = owner_q / "x" / "y" / os.path.basename(q)
    sql(world, "UPDATE deletion_journal SET operation_uuid = 'x/y', quarantine_path = ?"
        " WHERE uuid_id = ?", (str(forged), uuid_id))
    before = (journal(world, uuid_id), disk(world))

    if step == "journal step":
        recover(world)
    else:
        janitor(world).retry_cleanups()

    assert (journal(world, uuid_id), disk(world)) == before
    assert planted.exists()


def test_a_committed_cleanup_finishes_when_the_original_folder_became_a_symlink(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    q = journal(world, uuid_id)["quarantine_path"]
    album = os.path.dirname(journal(world, uuid_id)["original_path"])
    elsewhere = world.tmp / "elsewhere"
    (elsewhere / "empty").mkdir(parents=True)
    shutil.rmtree(album)
    os.symlink(elsewhere / "empty", album)

    janitor(world).retry_cleanups()

    assert not os.path.lexists(q) and journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["details"] == []
    assert (elsewhere / "empty").is_dir()  # pruning never leaves the owner's root


def test_committed_journals_the_janitor_keeps_are_counted(world, caplog):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    q = journal(world, uuid_id)["quarantine_path"]
    os.unlink(q)
    with open(q, "wb") as f:
        f.write(b"not ours")

    with caplog.at_level(logging.INFO):
        janitor(world).retry_cleanups()

    assert journal(world, uuid_id) is not None
    warnings = [r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING]
    assert any("1 " in m for m in warnings)
    assert all(str(world.music) not in r.getMessage() for r in caplog.records)
