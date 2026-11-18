"""7-fix-r0 F0-3 (7A.3c review r2 #4, O-7A3c-4): "the final name is this
operation's own link" is proven without following symbolic links: both names
are regular files with the same device and inode. A symlink at the final path
that points at the work file is someone else's entry and is never taken over,
published at, or removed — in the publisher's no-replace link, in startup
recovery's "already linked" check and in the recovered-failure path."""

import os

import pytest

from app.services import organizer
from tests.upload_commit_fixtures import journal
from tests.upload_publish_fixtures import track_row
from tests.upload_recovery_fixtures import World
from tests.upload_validation_fixtures import item_row


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def _never_in_use(_path):
    return False


# ── organizer.place_no_replace (the hard link it tries first) ──────────────────────────────────────────────

def test_an_existing_hard_link_of_the_source_counts_as_linked(tmp_path):
    work = tmp_path / "work.flac"
    work.write_bytes(b"audio")
    final = tmp_path / "lib" / "a.flac"
    final.parent.mkdir()
    os.link(work, final)

    assert organizer.place_no_replace(work, final, in_use=_never_in_use) == "linked"


def test_a_symlink_to_the_source_at_the_destination_is_not_our_link(tmp_path):
    work = tmp_path / "work.flac"
    work.write_bytes(b"audio")
    final = tmp_path / "lib" / "a.flac"
    final.parent.mkdir()
    os.symlink(work, final)

    assert organizer.place_no_replace(work, final, in_use=_never_in_use) is None
    assert os.path.islink(final)


def test_a_symlinked_source_is_not_proof_either(tmp_path):
    real = tmp_path / "real.flac"
    real.write_bytes(b"audio")
    work = tmp_path / "work.flac"
    os.symlink(real, work)
    final = tmp_path / "lib" / "a.flac"
    final.parent.mkdir()
    os.link(real, final)

    assert organizer.place_no_replace(work, final, in_use=_never_in_use) is None


# ── startup recovery ───────────────────────────────────────────────────────

def _symlink_final_to_work(world, commit):
    final = journal(world.db, commit)["final_path"]
    os.makedirs(os.path.dirname(final), exist_ok=True)
    os.symlink(commit["work"], final)
    return final


def test_recovery_never_publishes_a_track_at_a_symlink_to_the_work_file(world):
    commit = world.crash_at("before_link")
    final = _symlink_final_to_work(world, commit)

    world.restart()
    world.restart()

    assert track_row(world.db, commit["track"]) is None
    assert item_row(world.db, commit)["state"] != "imported"
    assert os.path.islink(final)  # someone else's entry: untouched
    assert commit["source"].read_bytes() == commit["content"]


def test_a_recovered_failure_never_removes_a_symlink_to_the_work_file(world):
    commit = world.crash_at("before_link")
    final = _symlink_final_to_work(world, commit)
    row = next(r for r in world.db.list_upload_commit_journals_to_resume()
               if r["operation_uuid"] == journal(world.db, commit)["operation_uuid"])
    assert row["state"] == "prepared"

    assert world.publisher().fail_recovered(row) == "failed"

    assert os.path.islink(final)
    assert track_row(world.db, commit["track"]) is None
