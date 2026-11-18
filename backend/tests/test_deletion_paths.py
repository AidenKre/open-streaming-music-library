"""Phase 8A.3c (spec §5 step 1 "an allowed master path within the configured
library. Reject symlink/out-of-root targets instead of deleting arbitrary
paths"; plan D35; SC-28 rule 5; review 8-D10): a master whose path is not
plainly the owner's own regular file is ``failed:path_rejected`` and nothing is
touched: no journal row, no move, no catalog change. Sentinels live in an
owned scratch area outside the library; their bytes are compared by hash.
"""

import hashlib
import os

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
    revision,
    tombstone,
)
from tests.track_paths import set_track_path


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


@pytest.fixture
def sentinel(tmp_path):
    path = tmp_path / "outside" / "secret.flac"
    path.parent.mkdir()
    path.write_bytes(b"not the library's file")
    return path


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _point_at(world, uuid_id, path):
    set_track_path(world.db, uuid_id, path)


def _disk(world):
    """Every file of the scratch area except the database itself."""
    return {k: v for k, v in files_under(world.tmp).items() if not k.startswith("db.sqlite")}


def _run_rejected(world, uuid_id, sentinel=None):
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    before_hash = _sha(sentinel) if sentinel is not None else None
    before_files = _disk(world)
    before_links = sorted(str(p) for p in world.tmp.rglob("*") if p.is_symlink())

    make_executor(world).run_one()

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == (
        "failed", "path_rejected",
    )
    assert journal(world, uuid_id) is None
    assert revision(world, uuid_id) == rev and tombstone(world, uuid_id) is None
    assert live(world, uuid_id)
    assert _disk(world) == before_files
    assert sorted(str(p) for p in world.tmp.rglob("*") if p.is_symlink()) == before_links
    if sentinel is not None:
        assert _sha(sentinel) == before_hash


def test_a_symlinked_master_is_rejected_and_its_target_untouched(world, sentinel):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac", create_file=False)
    link = world.root(world.owner) / "Radiohead" / "OK Computer" / "01 Lucky.flac"
    link.parent.mkdir(parents=True)
    link.symlink_to(sentinel)

    _run_rejected(world, uuid_id, sentinel)

    assert link.is_symlink()


def test_a_symlinked_folder_on_the_way_is_rejected(world, sentinel):
    uuid_id = add_master(world, "Radiohead/outside/secret.flac", create_file=False)
    (world.root(world.owner) / "Radiohead").mkdir()
    (world.root(world.owner) / "Radiohead" / "outside").symlink_to(
        sentinel.parent, target_is_directory=True
    )

    _run_rejected(world, uuid_id, sentinel)


def test_a_master_outside_every_library_root_is_rejected(world, sentinel):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    _point_at(world, uuid_id, sentinel)

    _run_rejected(world, uuid_id, sentinel)


def test_a_master_inside_another_users_root_is_rejected(world):
    theirs = world.root(world.sam) / "Radiohead" / "01 Lucky.flac"
    theirs.parent.mkdir(parents=True)
    theirs.write_bytes(b"sam's master")
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    _point_at(world, uuid_id, theirs)

    _run_rejected(world, uuid_id, theirs)


def test_a_dot_dot_path_that_leaves_the_root_is_rejected(world, sentinel):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    sneaky = world.root(world.owner) / ".." / ".." / "outside" / "secret.flac"
    assert os.path.exists(sneaky)
    _point_at(world, uuid_id, sneaky)

    _run_rejected(world, uuid_id, sentinel)


def test_a_master_that_is_a_folder_is_rejected(world):
    uuid_id = add_master(world, "Radiohead/OK Computer/01 Lucky.flac", create_file=False)
    folder = world.root(world.owner) / "Radiohead" / "OK Computer" / "01 Lucky.flac"
    folder.mkdir(parents=True)
    (folder / "keep.txt").write_bytes(b"keep")

    _run_rejected(world, uuid_id)

    assert (folder / "keep.txt").read_bytes() == b"keep"


def test_a_symlinked_library_root_is_rejected(world, tmp_path):
    # The owner's whole root redirected elsewhere: nothing below it is plainly
    # the owner's own file.
    elsewhere = tmp_path / "elsewhere"
    (elsewhere / "Radiohead").mkdir(parents=True)
    victim = elsewhere / "Radiohead" / "01 Lucky.flac"
    victim.write_bytes(b"elsewhere")
    root = world.root(world.owner)
    root.rmdir()
    root.symlink_to(elsewhere, target_is_directory=True)
    uuid_id = add_master(world, "Radiohead/01 Lucky.flac", create_file=False)

    _run_rejected(world, uuid_id, victim)


def test_the_quarantine_folders_have_one_spelling(tmp_path):
    """``.deleting`` under the music folder, and one folder per owner id below
    it: the worker, recovery and the janitor all ask these two functions."""
    from app.services.master_paths import quarantine_base, quarantine_dir

    music = tmp_path / "music"

    assert quarantine_base(music) == music / ".deleting"
    assert quarantine_dir(music, 7) == music / ".deleting" / "7"
    assert quarantine_dir(str(music), 7) == music / ".deleting" / "7"
