"""OPEN-8-01 part A (user decision 2026-11-14): at startup a file in the
deletion holding folder that no journal row names is put back at its track's
place when everything about it proves it is that track's own master:

- its path is exactly ``.deleting/<owner id>/<operation uuid>/<track uuid><ext>``
  (canonical spellings, real folders, a regular file with one link);
- no journal row of that track exists;
- the owner exists and is not being deleted; the owner's track with that uuid
  is live; the extension is the one the worker gives that track's master;
- the track's stored path passes the master path checks and nothing is there,
  and no other track of the owner uses it; the track is not locked.

Anything else stays exactly where it is and is reported, as before. A file
that was put back is not counted by the orphan report. The power-cut cases
that create such files are in ``test_deletion_crash_matrix.py``.
"""

import os
import uuid as uuidlib

import pytest

from app.services.deletion_recovery import DeletionJanitor
from tests.deletion_recovery_helpers import crashed_at
from tests.deletion_world import (
    accept_job,
    add_master,
    build_world,
    drain,
    files_under,
    item,
    journal,
    live,
    make_executor,
    path_of,
    revision,
    tombstone,
)
from tests.track_paths import allow_two_tracks_on_one_path, set_track_path


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def hold(world, uuid_id, *, folder_owner=None, op=None, name=None):
    """Move a track's master into the holding folder by hand, at
    ``.deleting/<folder_owner>/<op>/<name>`` (by default exactly where the
    worker would put it). Returns (holding path, original bytes, inode)."""
    master = path_of(world, uuid_id)
    folder_owner = world.owner if folder_owner is None else folder_owner
    op = op or str(uuidlib.uuid4())
    name = name or f"{uuid_id}{master.suffix}"
    target = world.music / ".deleting" / str(folder_owner) / op / name
    target.parent.mkdir(parents=True, exist_ok=True)
    data, ino = master.read_bytes(), os.lstat(master).st_ino
    os.rename(master, target)
    return target, data, ino


def startup_pass(world, *, executor=None):
    """The janitor's startup pass; returns the orphan count it reports."""
    janitor = DeletionJanitor(
        world.db, executor=executor or make_executor(world), music_library_dir=world.music
    )
    janitor.retry_cleanups()
    return janitor.report_orphans()


def holding(world):
    return files_under(world.music / ".deleting")


def assert_put_back(world, uuid_id, data, ino):
    master = path_of(world, uuid_id)
    assert master.exists(), "the file was not put back"
    assert master.read_bytes() == data and os.lstat(master).st_ino == ino
    assert holding(world) == {}
    assert live(world, uuid_id) and journal(world, uuid_id) is None


# ── put back ────────────────────────────────────────────────────────────────


def test_an_unrecorded_holding_file_of_a_live_track_is_put_back(world):
    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    rev = revision(world, uuid_id)
    _held, data, ino = hold(world, uuid_id)

    count = startup_pass(world)

    assert count == 0  # a file that was put back is not an orphan
    assert_put_back(world, uuid_id, data, ino)
    assert revision(world, uuid_id) == rev
    assert os.listdir(world.music / ".deleting" / str(world.owner)) == []  # its job folder went


def test_the_put_back_recreates_missing_folders_of_the_master(world):
    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    _held, data, ino = hold(world, uuid_id)
    os.rmdir(world.root(world.owner) / "Portishead" / "Dummy")
    os.rmdir(world.root(world.owner) / "Portishead")

    assert startup_pass(world) == 0
    assert_put_back(world, uuid_id, data, ino)


def test_a_master_without_an_extension_is_put_back_from_its_bare_name(world):
    uuid_id = add_master(world, "A/no-extension")
    held, data, ino = hold(world, uuid_id)
    assert held.name == uuid_id

    assert startup_pass(world) == 0
    assert_put_back(world, uuid_id, data, ino)


def test_another_users_file_is_put_back_in_their_own_library(world):
    uuid_id = add_master(world, "B/x.flac", owner=world.sam)
    _held, data, ino = hold(world, uuid_id, folder_owner=world.sam)

    assert startup_pass(world) == 0
    assert_put_back(world, uuid_id, data, ino)
    assert path_of(world, uuid_id).is_relative_to(world.root(world.sam))


def test_a_pending_job_of_a_put_back_track_then_deletes_it_normally(world):
    uuid_id = add_master(world, "A/x.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)), op=str(uuidlib.uuid4()))
    hold(world, uuid_id, op=op)

    assert startup_pass(world) == 0
    assert path_of(world, uuid_id).exists()
    drain(make_executor(world))

    assert item(world, op, uuid_id)["status"] == "deleted"
    assert item(world, op, uuid_id)["details"] == []  # not "the file was already missing"
    assert tombstone(world, uuid_id) is not None and holding(world) == {}


def test_a_second_startup_changes_nothing(world):
    uuid_id = add_master(world, "A/x.flac")
    _held, data, ino = hold(world, uuid_id)
    startup_pass(world)

    assert startup_pass(world) == 0
    assert_put_back(world, uuid_id, data, ino)


# ── kept and reported: anything that does not prove itself ──────────────────


def test_a_file_whose_place_is_taken_is_kept(world):
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id)
    path_of(world, uuid_id).write_bytes(b"someone else")

    count = startup_pass(world)

    assert count == 1 and held.read_bytes() == data
    assert path_of(world, uuid_id).read_bytes() == b"someone else"


def test_a_file_of_a_deleted_track_is_kept(world):
    uuid_id = add_master(world, "A/x.flac")
    master = path_of(world, uuid_id)
    accept_job(world, (uuid_id, revision(world, uuid_id)))
    drain(make_executor(world))  # a real, finished deletion
    assert tombstone(world, uuid_id) is not None
    held = world.music / ".deleting" / str(world.owner) / str(uuidlib.uuid4()) / f"{uuid_id}.flac"
    held.parent.mkdir(parents=True)
    held.write_bytes(b"left over")

    assert startup_pass(world) == 1
    assert held.read_bytes() == b"left over" and not master.exists()


def test_a_file_of_an_unknown_track_is_kept(world):
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id, name=f"{uuidlib.uuid4()}.flac")

    assert startup_pass(world) == 1
    assert held.read_bytes() == data and not path_of(world, uuid_id).exists()


def test_a_track_in_another_users_holding_folder_is_kept(world):
    """The owner's track under sam's folder: sam has no such track (SC-28)."""
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id, folder_owner=world.sam)

    assert startup_pass(world) == 1
    assert held.read_bytes() == data and not path_of(world, uuid_id).exists()


@pytest.mark.parametrize(
    "spelling",
    ["wrong_extension", "upper_case_track", "upper_case_operation", "not_an_operation",
     "padded_owner", "nested_deeper"],
)
def test_a_name_the_worker_would_not_have_written_is_kept(world, spelling):
    uuid_id = add_master(world, "A/x.flac")
    op = str(uuidlib.uuid4())
    folder_owner, name = str(world.owner), f"{uuid_id}.flac"
    if spelling == "wrong_extension":
        name = f"{uuid_id}.mp3"
    elif spelling == "upper_case_track":
        name = f"{uuid_id.upper()}.flac"
    elif spelling == "upper_case_operation":
        op = op.upper()
    elif spelling == "not_an_operation":
        op = "x"
    elif spelling == "padded_owner":
        folder_owner = f"0{world.owner}"
    elif spelling == "nested_deeper":
        op = f"{op}/{uuidlib.uuid4()}"
    master = path_of(world, uuid_id)
    data = master.read_bytes()
    held = world.music / ".deleting" / folder_owner / op / name
    held.parent.mkdir(parents=True)
    os.rename(master, held)

    assert startup_pass(world) == 1
    assert held.read_bytes() == data and not master.exists()


def test_a_track_with_a_journal_row_is_left_to_the_journal(world):
    """A copy under another job while the track's own journal (intent, file
    moved) still exists: recovery of the journal owns the track."""
    uuid_id, _rev, _op = crashed_at(world, "after_rename", rel="A/x.flac")
    named = journal(world, uuid_id)["quarantine_path"]
    other = world.music / ".deleting" / str(world.owner) / str(uuidlib.uuid4()) / f"{uuid_id}.flac"
    other.parent.mkdir(parents=True)
    other.write_bytes(b"a second copy")
    janitor = DeletionJanitor(world.db, executor=make_executor(world), music_library_dir=world.music)

    assert janitor.report_orphans() == 1

    assert other.read_bytes() == b"a second copy"
    assert os.path.exists(named) and not path_of(world, uuid_id).exists()


def test_a_file_of_a_user_being_deleted_is_kept(world):
    uuid_id = add_master(world, "B/x.flac", owner=world.sam)
    held, data, _ = hold(world, uuid_id, folder_owner=world.sam)
    world.db.mark_user_deleting(world.sam, 1)

    assert startup_pass(world) == 1
    assert held.read_bytes() == data and not path_of(world, uuid_id).exists()


def test_a_file_with_a_second_name_is_kept(world, tmp_path):
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id)
    os.link(held, tmp_path / "second-name")

    assert startup_pass(world) == 1
    assert held.read_bytes() == data and not path_of(world, uuid_id).exists()


def test_a_track_whose_stored_path_is_outside_its_library_is_kept(world, tmp_path):
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id)
    outside = tmp_path / "elsewhere" / "x.flac"
    set_track_path(world.db, uuid_id, outside)

    assert startup_pass(world) == 1
    assert held.read_bytes() == data and not outside.exists()


def test_a_place_another_track_uses_is_kept(world):
    uuid_id = add_master(world, "A/x.flac")
    other = add_master(world, "A/other.flac")
    held, data, _ = hold(world, uuid_id)
    # Two rows naming one file: the state the unique index now refuses.
    allow_two_tracks_on_one_path(world.db)
    set_track_path(world.db, other, path_of(world, uuid_id))

    assert startup_pass(world) == 1
    assert held.read_bytes() == data and not path_of(world, uuid_id).exists()


def test_a_locked_track_is_kept(world):
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id)
    lock = world.locks.lock_for(uuid_id)
    assert lock.acquire(timeout=0)
    try:
        count = startup_pass(world, executor=make_executor(world))
    finally:
        lock.release()

    assert count == 1
    assert held.read_bytes() == data and not path_of(world, uuid_id).exists()


def test_a_symbolic_link_in_the_holding_folder_is_neither_followed_nor_counted(world, tmp_path):
    uuid_id = add_master(world, "A/x.flac")
    master = path_of(world, uuid_id)
    target = tmp_path / "outside.flac"
    os.rename(master, target)
    link = world.music / ".deleting" / str(world.owner) / str(uuidlib.uuid4()) / f"{uuid_id}.flac"
    link.parent.mkdir(parents=True)
    link.symlink_to(target)

    assert startup_pass(world) == 0  # not a regular file: not counted, as before
    assert link.is_symlink() and target.exists() and not master.exists()


def test_the_periodic_pass_puts_nothing_back(world):
    """The put-back is a startup step: at run time a holding file always has
    its journal row, so an unrecorded one is left for the next start."""
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id)

    DeletionJanitor(world.db, executor=make_executor(world), music_library_dir=world.music).retry_cleanups()

    assert held.read_bytes() == data and not path_of(world, uuid_id).exists()


def test_the_put_back_link_is_synced_before_the_holding_name_goes(world, monkeypatch):
    """Review finding (durable point r1 #3): the new name's folder is synced
    before the holding name is removed, so a power cut never keeps the
    removal without the link."""
    from pathlib import Path

    from app.services import master_paths

    uuid_id = add_master(world, "A/x.flac")
    master = path_of(world, uuid_id)
    held, data, ino = hold(world, uuid_id)
    events = []
    real_sync, real_unlink = master_paths.fsync_dir, os.unlink

    def sync(directory):
        events.append(("sync", Path(directory)))
        return real_sync(directory)

    def unlink(path, *args, **kwargs):
        events.append(("unlink", Path(path)))
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(master_paths, "fsync_dir", sync)
    monkeypatch.setattr(os, "unlink", unlink)

    assert startup_pass(world) == 0

    assert_put_back(world, uuid_id, data, ino)
    assert events.index(("sync", master.parent)) < events.index(("unlink", held))


def test_two_unrecorded_files_of_one_track_are_both_kept(world):
    """Review finding (protection r1 #3): which of two candidates is the
    track's current master cannot be proven, so neither is put back."""
    uuid_id = add_master(world, "A/x.flac")
    held, data, _ = hold(world, uuid_id)
    second = world.music / ".deleting" / str(world.owner) / str(uuidlib.uuid4()) / held.name
    second.parent.mkdir(parents=True)
    second.write_bytes(b"an older copy")

    assert startup_pass(world) == 2
    assert held.read_bytes() == data and second.read_bytes() == b"an older copy"
    assert not path_of(world, uuid_id).exists()
