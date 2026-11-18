"""A deletion first finishes the journal row a finished edit or conversion left
behind (pre-merge review B1-02).

A tag edit that moved the file commits, and then the database flush before the
old file is removed fails: the edit answers success, the journal row stays and
the old file is remembered by the running server. Until that row was finished
(by the track's next edit or conversion, by the idle pass, or by a restart),
deleting the track answered "busy", and so did every retry. An edit and a
conversion finish such rows first, under the track's lock; the deletion now
does the same, with the server's one registry of remembered old files.
"""

import pytest

from app.library import Library
from app.services.journal_recovery import PendingOldMasters
from tests.pending_deletion import mark_pending_deletion
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


def _a_finished_move_whose_row_was_kept(world, *, old_file: bool):
    """Track X after a committed move: its file at the new path, the catalog
    naming it, and the journal row of the move still there. Returns
    (uuid, old path, the row)."""
    uuid_id = add_master(world, "New/Album/01 Song.flac", data=b"the new master")
    new = path_of(world, uuid_id)
    old = world.root(world.owner) / "Old" / "Album" / "01 Song.flac"
    if old_file:
        old.parent.mkdir(parents=True)
        old.write_bytes(b"the old master")
    world.db.insert_journal_entry(
        "relocate", uuid_id, old_path=str(old), new_path=str(new),
        temp_path=str(world.music / ".staging" / f"{uuid_id}.edit.flac"), owner_id=world.owner)
    [row] = Library(world.db, world.owner).list_journal_entries()
    return uuid_id, old, row


def _edit_rows(world):
    return sql(world, "SELECT id FROM edit_journal")


def test_a_kept_row_whose_old_file_is_remembered_is_finished_and_the_track_deleted(world):
    """The finding's case: the old file is still there, remembered by the
    running server. The deletion removes it as the track's next edit would
    (after a durable point), drops the row, and then deletes the track."""
    uuid_id, old, row = _a_finished_move_whose_row_was_kept(world, old_file=True)
    remembered = PendingOldMasters()
    remembered.remember(row, old)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world, pending_old_masters=remembered).run_one()

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == ("deleted", None)
    assert tombstone(world, uuid_id) is not None and journal(world, uuid_id) is None
    assert _edit_rows(world) == []
    assert files_under(world.music) == {}  # the old file, the new master and the holding copy


def test_a_kept_row_whose_old_file_is_already_gone_is_finished_too(world):
    uuid_id, _old, _row = _a_finished_move_whose_row_was_kept(world, old_file=False)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world, pending_old_masters=PendingOldMasters()).run_one()

    assert item(world, op, uuid_id)["status"] == "deleted"
    assert _edit_rows(world) == [] and files_under(world.music) == {}


def test_a_row_that_cannot_be_finished_still_answers_busy_and_nothing_is_touched(world):
    """An old file the running server does not remember (the row is from an
    earlier run) is never removed while the server runs: the row waits for the
    next start, and the deletion still answers busy."""
    uuid_id, old, _row = _a_finished_move_whose_row_was_kept(world, old_file=True)
    before = files_under(world.music)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world, pending_old_masters=PendingOldMasters()).run_one()

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == ("busy", "busy")
    assert live(world, uuid_id) and tombstone(world, uuid_id) is None
    assert len(_edit_rows(world)) == 1
    assert files_under(world.music) == before and old.read_bytes() == b"the old master"


def test_a_track_that_another_deletion_holds_pending_is_not_written_to(world):
    """A track whose earlier deletion is still pending (its journal row is
    kept) is left alone by every writer; the kept edit row is not finished for
    it either, although it could be. The target answers busy."""
    uuid_id, _old, _row = _a_finished_move_whose_row_was_kept(world, old_file=False)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    mark_pending_deletion(world.db.context.database_path, uuid_id)
    before = files_under(world.music)

    make_executor(world, pending_old_masters=PendingOldMasters()).run_one()

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == ("busy", "busy")
    assert len(_edit_rows(world)) == 1
    assert files_under(world.music) == before


def test_the_apps_deletion_worker_has_the_servers_one_registry_of_remembered_old_files(
    open_app_client,
):
    """The wiring: the deletion can only remove an old file the editor or the
    conversion remembered if it is handed their registry (and their wake-up of
    the identity worker), not one of its own."""
    with open_app_client(env={"ENABLE_DELETION_WORKER": "true"}) as client:
        state = client.app.state
        executor = state.deletion_worker._executor
        assert executor._pending_old_masters is state.pending_old_masters
        assert executor._identity_signal is state.identity_wakeup
