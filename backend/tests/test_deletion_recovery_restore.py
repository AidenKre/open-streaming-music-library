"""Phase 8A.3d S3 (spec §5 "Startup recovery before serving consumers", cases
2 and 5, "No unrelated path may be overwritten during recovery"; review
8-U06, 8-D09): the "deletion journal" step where a file sits in quarantine.

- Journal + own live track at the journaled revision + the journaled file in
  quarantine + nothing at the original path: the master is put back (a
  no-replace hard link, the own-link proof, then the quarantine name is
  unlinked), the journal is cleared, the revision is unchanged.
- Both names on one inode (a put-back whose unlink failed): the quarantine
  name is unlinked only after the own-link proof.
- The original intact and a foreign file at the quarantine path: the journal
  is cleared, the foreign file kept.
- Anything else keeps the journal, marks a running item
  ``failed:recovery_required`` and touches no file: original and quarantine
  both missing, the original path taken (a file or a dangling symlink), a
  different file in quarantine, an identity that cannot be read, the original
  path named by another track, a symlinked folder on the way back, a
  quarantine path that is not exactly ``.deleting/<owner>/<op>/<uuid><ext>``
  under real directories, a track whose stored path lies outside its owner's
  root.
"""

import os
import shutil

import pytest

from tests.deletion_recovery_helpers import crashed_at, disk, recover, restarted_db
from tests.deletion_world import (
    add_master,
    build_world,
    item,
    journal,
    live,
    path_of,
    revision,
    sql,
)
from tests.track_paths import allow_two_tracks_on_one_path, set_track_path


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def quarantine_of(world, uuid_id):
    return os.fspath(journal(world, uuid_id)["quarantine_path"])


def assert_kept(world, uuid_id, op, before, *, owner=None):
    """Journal unchanged, every file unchanged, the item recovery_required."""
    assert journal(world, uuid_id) == before["journal"]
    assert disk(world) == before["disk"]
    assert not live(world, uuid_id)
    after = item(world, op, uuid_id, owner=owner)
    assert (after["status"], after["error"]) == ("failed", "recovery_required")


def snapshot(world, uuid_id):
    return {"journal": journal(world, uuid_id), "disk": disk(world)}


# ── case 2: restore an uncommitted deletion ─────────────────────────────────


@pytest.mark.parametrize("point", ["after_rename", "after_moved"])
def test_a_quarantined_master_is_put_back_with_its_revision_unchanged(world, point):
    uuid_id, rev, op = crashed_at(world, point)
    master = path_of(world, uuid_id)
    q = quarantine_of(world, uuid_id)
    inode, data = os.lstat(q).st_ino, open(q, "rb").read()
    assert not master.exists()

    recover(world)

    assert master.read_bytes() == data and os.lstat(master).st_ino == inode
    assert not os.path.lexists(q)
    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert item(world, op, uuid_id)["status"] == "running"  # the reclaim step requeues it


def test_putting_back_twice_changes_nothing_more(world):
    uuid_id, rev, op = crashed_at(world, "after_moved")
    recover(world)
    first = (disk(world), journal(world, uuid_id), item(world, op, uuid_id), revision(world, uuid_id))

    recover(world)

    assert (disk(world), journal(world, uuid_id), item(world, op, uuid_id), revision(world, uuid_id)) == first


def test_both_names_on_one_inode_unlink_only_the_quarantine_name(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    q = quarantine_of(world, uuid_id)
    os.link(q, master)  # a put-back whose unlink of the quarantine name failed

    recover(world)

    assert master.exists() and not os.path.lexists(q)
    assert journal(world, uuid_id) is None and revision(world, uuid_id) == rev


def test_a_foreign_file_at_the_quarantine_path_is_kept_and_the_journal_cleared(world):
    uuid_id, rev, op = crashed_at(world, "after_journal")
    master = path_of(world, uuid_id)
    q = quarantine_of(world, uuid_id)
    os.makedirs(os.path.dirname(q))
    with open(q, "wb") as f:
        f.write(b"not ours")

    recover(world)

    assert open(q, "rb").read() == b"not ours"
    assert master.exists() and journal(world, uuid_id) is None and live(world, uuid_id)


# ── never guessed: the journal is kept, nothing touched ─────────────────────


def test_original_and_quarantine_both_missing_clears_the_journal_and_touches_no_file(world):
    # Changed by fix round 1 (8-R1-05, TR-DELETE-03): with the owner's root
    # proven present, a master gone from both places is no longer a journal
    # kept for ever; the journal is cleared (no file exists to protect) and the
    # rerun deletes the track as a catalog-only deletion
    # (test_deletion_kept_journals.py). Was: kept, item recovery_required.
    uuid_id, rev, op = crashed_at(world, "after_rename")
    os.unlink(quarantine_of(world, uuid_id))
    before = snapshot(world, uuid_id)

    recover(world)

    assert journal(world, uuid_id) is None
    assert disk(world) == before["disk"]
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert item(world, op, uuid_id)["status"] == "running"  # the jobs step requeues it


def test_an_original_path_taken_by_another_file_is_never_overwritten(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    path_of(world, uuid_id).write_bytes(b"a new file someone put here")
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)


def test_a_dangling_symlink_at_the_original_path_is_never_replaced(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    os.symlink(world.tmp / "nowhere", master)
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)
    assert os.path.islink(master)


def test_a_different_file_in_quarantine_is_never_restored(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    q = quarantine_of(world, uuid_id)
    os.unlink(q)
    with open(q, "wb") as f:
        f.write(b"another file, another inode")
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)


def test_an_original_path_another_track_names_is_never_restored_to(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    other = add_master(world, "Other/x.flac")
    # Two rows naming one file: the state the unique index now refuses.
    allow_two_tracks_on_one_path(world.db)
    set_track_path(world.db, other, master)
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)


def test_a_symlinked_folder_on_the_way_back_is_never_followed(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    album = path_of(world, uuid_id).parent
    elsewhere = world.tmp / "elsewhere"
    elsewhere.mkdir()
    shutil.rmtree(album)
    os.symlink(elsewhere, album)
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)
    assert list(elsewhere.iterdir()) == []


@pytest.mark.parametrize("where", ["quarantine folder", "original folder"])
@pytest.mark.requires_chmod_denial
def test_an_identity_that_cannot_be_read_keeps_the_journal(world, where):
    uuid_id, rev, op = crashed_at(
        world, "after_rename" if where == "quarantine folder" else "after_journal"
    )
    folder = (
        os.path.dirname(quarantine_of(world, uuid_id))
        if where == "quarantine folder"
        else str(path_of(world, uuid_id).parent)
    )
    before = snapshot(world, uuid_id)
    os.chmod(folder, 0)
    try:
        recover(world)
    finally:
        os.chmod(folder, 0o755)

    assert_kept(world, uuid_id, op, before)


# ── forged or planted journals ──────────────────────────────────────────────


def _forge(world, uuid_id, new_q):
    os.makedirs(os.path.dirname(new_q), exist_ok=True)
    os.rename(quarantine_of(world, uuid_id), new_q)
    sql(world, "UPDATE deletion_journal SET quarantine_path = ? WHERE uuid_id = ?", (str(new_q), uuid_id))


@pytest.mark.parametrize("place", ["outside the library", "another owner's quarantine",
                                   "another operation's folder", "a dot-dot path", "another name"])
def test_a_forged_quarantine_path_restores_and_deletes_nothing(world, place):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    real_q = quarantine_of(world, uuid_id)
    deleting = world.music / ".deleting"
    new_q = {
        "outside the library": world.tmp / "outside" / f"{uuid_id}.flac",
        "another owner's quarantine": deleting / str(world.sam) / op / f"{uuid_id}.flac",
        "another operation's folder": deleting / str(world.owner) / "other-op" / f"{uuid_id}.flac",
        "a dot-dot path": deleting / str(world.owner) / op / ".." / op / f"{uuid_id}.flac",
        "another name": deleting / str(world.owner) / op / "renamed.flac",
    }[place]
    if place == "a dot-dot path":
        sql(world, "UPDATE deletion_journal SET quarantine_path = ? WHERE uuid_id = ?",
            (str(new_q), uuid_id))
        assert os.path.exists(new_q) and os.path.samefile(new_q, real_q)
    else:
        _forge(world, uuid_id, new_q)
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)


def test_a_forged_quarantine_path_that_is_a_second_name_of_the_master_deletes_nothing(world):
    uuid_id, rev, op = crashed_at(world, "after_journal")
    master = path_of(world, uuid_id)
    outside = world.tmp / "outside" / f"{uuid_id}.flac"
    outside.parent.mkdir()
    os.link(master, outside)
    sql(world, "UPDATE deletion_journal SET quarantine_path = ? WHERE uuid_id = ?", (str(outside), uuid_id))
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)
    assert outside.exists() and master.exists()


def test_a_symlinked_owner_quarantine_folder_is_never_trusted(world):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    owner_q = world.music / ".deleting" / str(world.owner)
    real = world.tmp / "real-quarantine"
    os.rename(owner_q, real)
    os.symlink(real, owner_q)
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)
    assert not path_of(world, uuid_id).exists()


def test_a_symlinked_quarantine_base_folder_is_never_trusted(world):
    """The same for .deleting itself: the owner's folder below a symbolic
    link reads as a real folder, so only the check of the base catches it."""
    uuid_id, rev, op = crashed_at(world, "after_rename")
    base = world.music / ".deleting"
    real = world.tmp / "real-quarantine-base"
    os.rename(base, real)
    os.symlink(real, base)
    before = snapshot(world, uuid_id)

    recover(world)

    assert_kept(world, uuid_id, op, before)
    assert not path_of(world, uuid_id).exists()


def test_another_owners_journal_resolves_under_that_owners_root(world):
    mine = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    mine_before = path_of(world, mine).read_bytes()
    theirs, rev, op = crashed_at(world, "after_rename", owner=world.sam)
    their_master = path_of(world, theirs)
    assert str(their_master).startswith(str(world.root(world.sam)))

    recover(world)

    assert their_master.exists() and journal(world, theirs) is None
    assert revision(world, theirs) == rev
    assert path_of(world, mine).read_bytes() == mine_before


def test_a_journal_whose_track_points_into_another_owners_root_touches_nothing(world):
    """A planted pair (track row and journal row of Sam naming a path in the
    owner's root): the path is judged under Sam's root and refused."""
    theirs, rev, op = crashed_at(world, "after_rename", owner=world.sam)
    planted = world.root(world.owner) / "Portishead" / "Dummy" / "01 Mysterons.flac"
    set_track_path(world.db, theirs, planted)
    sql(world, "UPDATE deletion_journal SET original_path = ? WHERE uuid_id = ?", (str(planted), theirs))
    before = snapshot(world, theirs)

    recover(world)

    assert_kept(world, theirs, op, before, owner=world.sam)
    assert not planted.exists()


def test_a_kept_journal_is_resolved_once_the_original_path_is_free_again(world):
    """End state N1: a journal kept because the original path was taken is
    put back on a later start once the path is free."""
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    master.write_bytes(b"in the way")
    recover(world)
    assert journal(world, uuid_id) is not None
    master.unlink()

    recover(world, database=restarted_db(world))

    assert master.exists() and journal(world, uuid_id) is None and live(world, uuid_id)
    assert item(world, op, uuid_id)["error"] == "recovery_required"  # terminal: never rewritten


@pytest.mark.requires_chmod_denial
def test_an_unreadable_quarantine_beside_an_intact_original_keeps_the_journal(world):
    """Unknown is never "free": with the original intact and the quarantine
    path unreadable, the journal is not cleared (the mutation spot-check that
    read an unreadable quarantine as free survived without this test)."""
    uuid_id, rev, op = crashed_at(world, "after_journal")
    op_dir = os.path.dirname(quarantine_of(world, uuid_id))
    os.makedirs(op_dir)
    before = snapshot(world, uuid_id)
    os.chmod(op_dir, 0)
    try:
        recover(world)
    finally:
        os.chmod(op_dir, 0o755)

    assert_kept(world, uuid_id, op, before)
