"""Phase 8A.3d S1 (spec §5 "Durable worker claiming"; SC-16d/e; review 8-D09):
the "deletion jobs" startup step.

- A ``running`` item leased by a dead boot with **no** journal row goes back
  to ``pending`` (lease cleared): a crash right after the claim never strands
  a job, and the next worker run executes it.
- A ``running`` item backed by a journal row is left alone: it waits for the
  journal step, never an independent second delete.
- Terminal items never run again; pending items stay pending.
- A job none of whose items is open is ``completed`` (no stuck job).
- Server-wide (every owner); running it twice changes nothing more.

States are made by the real executor stopped at its crash seams
(``SimulatedCrash``), or written with plain SQL where noted.
"""

import pytest

from app.services import deletion_recovery
from tests.deletion_recovery_helpers import NEW_BOOT, run_until_crash
from tests.deletion_world import (
    BOOT,
    accept_job,
    add_master,
    build_world,
    drain,
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


def job_status(world, op, owner=None):
    owner = world.owner if owner is None else owner
    return sql(
        world,
        "SELECT status FROM deletion_jobs WHERE owner_id = ? AND operation_uuid = ?",
        (owner, op),
    )[0][0]


def test_a_running_item_without_a_journal_goes_back_to_pending(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    run_until_crash(world, "after_claim")
    assert item(world, op, uuid_id)["status"] == "running"

    assert deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT) == 1

    after = item(world, op, uuid_id)
    assert after["status"] == "pending" and after["lease"] is None
    assert job_status(world, op) == "accepted"


def test_reclaiming_twice_changes_nothing_more(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    run_until_crash(world, "after_claim")

    deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT)
    first = item(world, op, uuid_id)
    assert deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT) == 0

    assert item(world, op, uuid_id) == first


def test_a_reclaimed_item_is_executed_by_the_next_worker_run(world):
    uuid_id = add_master(world, "A/a.flac")
    master = path_of(world, uuid_id)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    run_until_crash(world, "after_claim")
    deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT)

    assert drain(make_executor(world, boot_id=NEW_BOOT)) == 1

    assert item(world, op, uuid_id)["status"] == "deleted"
    assert tombstone(world, uuid_id) is not None and not master.exists()
    assert job_status(world, op) == "completed"


def test_a_running_item_backed_by_a_journal_waits_for_the_journal_step(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    run_until_crash(world, "after_journal")
    assert journal(world, uuid_id) is not None

    assert deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT) == 0

    after = item(world, op, uuid_id)
    assert after["status"] == "running" and after["lease"] == BOOT
    assert journal(world, uuid_id)["stage"] == "intent"


def test_terminal_and_pending_items_are_never_touched(world):
    done = add_master(world, "A/done.flac")
    stale = add_master(world, "A/stale.flac")
    waiting = add_master(world, "A/waiting.flac")
    op = accept_job(
        world,
        (done, revision(world, done)),
        (stale, revision(world, stale) + 7),  # conflict
        (waiting, revision(world, waiting)),
    )
    executor = make_executor(world)
    assert executor.run_one() and executor.run_one()  # done → deleted, stale → conflict
    before = {u: item(world, op, u) for u in (done, stale, waiting)}
    assert [before[u]["status"] for u in (done, stale, waiting)] == [
        "deleted", "conflict", "pending",
    ]

    assert deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT) == 0

    assert {u: item(world, op, u) for u in (done, stale, waiting)} == before


def test_items_of_every_owner_are_reclaimed_under_their_own_owner(world):
    mine = add_master(world, "A/a.flac")
    theirs = add_master(world, "A/a.flac", owner=world.sam)
    op_me = accept_job(world, (mine, revision(world, mine)))
    op_sam = accept_job(world, (theirs, revision(world, theirs)), owner=world.sam)
    run_until_crash(world, "after_claim")
    run_until_crash(world, "after_claim")

    assert deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT) == 2

    assert item(world, op_me, mine)["status"] == "pending"
    assert item(world, op_sam, theirs, owner=world.sam)["status"] == "pending"
    assert sql(
        world,
        "SELECT owner_id, uuid_id FROM deletion_job_items ORDER BY owner_id",
    ) == sorted([(world.owner, mine), (world.sam, theirs)])


def test_an_item_leased_by_this_boot_is_not_reclaimed(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    run_until_crash(world, "after_claim")

    assert deletion_recovery.reclaim_deletion_items(world.db, boot_id=BOOT) == 0

    assert item(world, op, uuid_id)["status"] == "running"


def test_a_job_whose_items_are_all_terminal_is_completed(world):
    uuid_id = add_master(world, "A/a.flac")
    other = add_master(world, "A/b.flac")
    open_op = accept_job(world, (other, revision(world, other)))
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    # A job left 'accepted' with every item terminal (plain SQL: the normal
    # path completes the job in the item's own transaction).
    sql(
        world,
        "UPDATE deletion_job_items SET status = 'conflict', error_code = 'conflict'"
        " WHERE operation_uuid = ?",
        (op,),
    )

    deletion_recovery.reclaim_deletion_items(world.db, boot_id=NEW_BOOT)

    assert job_status(world, op) == "completed"
    assert job_status(world, open_op) == "accepted"  # its item is still pending
