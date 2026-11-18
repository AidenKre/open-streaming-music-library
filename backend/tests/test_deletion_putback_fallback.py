"""Sign-off DEV-7-25 link fallback, Part B: the deletion put-back on a library
that refuses hard links. ``put_back_file`` places the quarantined file back
with the shared ``file_ops.place_no_replace`` (hard link first, a rename when
the filesystem refuses it, never a copy) and never replaces anything at the
original path. After a rename the restored file is proven by the journaled
identity (dev, inode, size), else by the quarantine's own identity taken just
before the rename; a proof that fails (a filesystem whose inode numbers are
not stable: on exFAT under macOS they survive a rename and a re-mount, but an
empty file's made-up number changes once data is written; Linux vfat/exfat was
not measured) keeps the journal: the track stays hidden as recovery_required
and no file is removed."""

import errno
import os
import shutil
from pathlib import Path

import pytest

from app.services import deletion_worker, file_ops, organizer
from app.services.deletion_recovery import DeletionJanitor
from tests.deletion_recovery_helpers import crashed_at, disk, recover
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
)

_real_rename = os.rename
_real_lstat = os.lstat


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def _no_links(monkeypatch, err=errno.ENOTSUP):
    def refuse(src, dst, *args, **kwargs):
        raise OSError(err, os.strerror(err))

    monkeypatch.setattr(organizer.os, "link", refuse)


def _quarantine(world, uuid_id) -> Path:
    return Path(os.fspath(journal(world, uuid_id)["quarantine_path"]))


def _assert_kept(world, uuid_id, op, before_journal):
    assert journal(world, uuid_id) == before_journal
    assert not live(world, uuid_id)
    after = item(world, op, uuid_id)
    assert (after["status"], after["error"]) == ("failed", "recovery_required")


# ── recovery: every state of a put-back by rename ───────────────────────────

@pytest.mark.parametrize("err", [errno.ENOTSUP, errno.EPERM, errno.EOPNOTSUPP, errno.EMLINK])
def test_quarantined_and_original_free_is_put_back_by_rename(world, monkeypatch, err):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    q = _quarantine(world, uuid_id)
    ino, data = os.lstat(q).st_ino, q.read_bytes()
    _no_links(monkeypatch, err)

    recover(world)

    assert master.read_bytes() == data and os.lstat(master).st_ino == ino
    assert not os.path.lexists(q)
    assert journal(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev


def test_a_crash_right_after_the_put_back_rename_is_cleared(world, monkeypatch):
    """The original is the journaled file again and the quarantine is free."""
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    data = _quarantine(world, uuid_id).read_bytes()
    os.rename(_quarantine(world, uuid_id), master)  # what a rename put-back leaves
    _no_links(monkeypatch)

    recover(world)

    assert master.read_bytes() == data
    assert journal(world, uuid_id) is None and live(world, uuid_id)


def test_both_names_present_but_not_one_file_keeps_everything(world, monkeypatch):
    """A rename never leaves both names; a copy at the original (another inode)
    is not the journaled file, so nothing is removed or replaced."""
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    shutil.copyfile(_quarantine(world, uuid_id), master)
    _no_links(monkeypatch)
    before, files = journal(world, uuid_id), disk(world)

    recover(world)

    _assert_kept(world, uuid_id, op, before)
    assert disk(world) == files


def test_a_refused_link_and_a_failing_rename_keep_the_journal_and_every_file(world, monkeypatch):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    q = _quarantine(world, uuid_id)
    _no_links(monkeypatch)

    def rename(src, dst, *args, **kwargs):
        if Path(src) == q:
            raise PermissionError(errno.EACCES, os.strerror(errno.EACCES))
        return _real_rename(src, dst, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "rename", rename)
    before, files = journal(world, uuid_id), disk(world)

    recover(world)

    _assert_kept(world, uuid_id, op, before)
    assert disk(world) == files


def test_a_quarantine_on_another_filesystem_is_never_copied_back(world, monkeypatch):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    _no_links(monkeypatch, errno.EXDEV)
    before, files = journal(world, uuid_id), disk(world)

    recover(world)

    _assert_kept(world, uuid_id, op, before)
    assert disk(world) == files  # no copy, no temp


def test_a_name_that_appears_at_the_original_just_before_the_rename_is_never_replaced(
        world, monkeypatch):
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    q = _quarantine(world, uuid_id)
    data = q.read_bytes()

    def refuse_after_another_program_writes(src, dst, *args, **kwargs):
        if Path(dst) == master:
            master.write_bytes(b"someone else's file")
        raise OSError(errno.ENOTSUP, os.strerror(errno.ENOTSUP))

    monkeypatch.setattr(organizer.os, "link", refuse_after_another_program_writes)
    before = journal(world, uuid_id)

    recover(world)

    assert master.read_bytes() == b"someone else's file"
    assert q.read_bytes() == data
    _assert_kept(world, uuid_id, op, before)


def test_a_rename_whose_identity_changes_keeps_the_journal_and_removes_nothing(world, monkeypatch):
    """A restored file whose inode number differs from the quarantine's (exFAT
    on macOS keeps numbers across a rename except an empty file's made-up one;
    other filesystems were not measured) cannot be proven. The put-back answers False: the file stays at its original path, the
    journal stays, the track stays hidden as recovery_required, and a later
    pass still keeps it (never a deletion on a failed proof)."""
    uuid_id, rev, op = crashed_at(world, "after_rename", data=b"")
    master = path_of(world, uuid_id)
    q = _quarantine(world, uuid_id)
    _no_links(monkeypatch)

    def lstat(path, *args, **kwargs):
        st = _real_lstat(path, *args, **kwargs)
        if Path(path) == master:  # the number the filesystem made up after the rename
            fields = list(st)
            fields[1] = st.st_ino + 1_000_000
            return os.stat_result(fields)
        return st

    monkeypatch.setattr(os, "lstat", lstat)
    before = journal(world, uuid_id)

    recover(world)
    recover(world)

    assert master.exists() and master.read_bytes() == b""
    assert not os.path.lexists(q)
    _assert_kept(world, uuid_id, op, before)


# ── the worker's own put-backs ──────────────────────────────────────────────

def test_a_revision_changed_after_the_move_is_put_back_by_rename(world, monkeypatch):
    """After a failed commit the restore is proven by the journaled identity."""
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    ino = os.lstat(master).st_ino
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    _no_links(monkeypatch)

    def seam(name):
        if name == "after_moved":
            sql(world, "UPDATE tracks SET revision = revision + 1000 WHERE uuid_id = ?", (uuid_id,))

    make_executor(world, seam=seam).run_one()

    after = item(world, op, uuid_id)
    assert (after["status"], after["error"]) == ("conflict", "conflict")
    assert os.lstat(master).st_ino == ino and master.read_bytes() == b"master A/Album/a.flac"
    assert files_under(world.music / ".deleting") == {}
    assert journal(world, uuid_id) is None and live(world, uuid_id)


def test_a_file_replaced_right_after_the_move_is_put_back_by_rename(world, monkeypatch):
    """Right after its own move (another file now in quarantine) the worker puts
    back what it just moved, proven by the quarantine's identity taken just
    before the rename."""
    uuid_id = add_master(world, "A/Album/a.flac")
    master = path_of(world, uuid_id)
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    real_move = file_ops.move_file

    def move(source, destination):
        moved = real_move(source, destination)
        if moved and Path(source) == master:
            copy = Path(str(destination) + ".copy")
            shutil.copyfile(destination, copy)
            os.replace(copy, destination)  # same bytes, another inode
        return moved

    monkeypatch.setattr(file_ops, "move_file", move)
    _no_links(monkeypatch)

    make_executor(world).run_one()

    after = item(world, op, uuid_id)
    assert (after["status"], after["error"]) == ("conflict", "conflict")
    assert master.read_bytes() == b"master A/Album/a.flac"
    assert files_under(world.music / ".deleting") == {}
    assert journal(world, uuid_id) is None and live(world, uuid_id)


# ── the startup put-back of a holding file no journal names ─────────────────

def test_an_unrecorded_holding_file_is_put_back_by_rename(world, monkeypatch):
    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac")
    master = path_of(world, uuid_id)
    data, ino = master.read_bytes(), os.lstat(master).st_ino
    held = world.music / ".deleting" / str(world.owner) / "0b6c5d3e-2f43-4c8e-9a43-7e2f5c1d9a10" / (
        f"{uuid_id}{master.suffix}")
    held.parent.mkdir(parents=True)
    os.rename(master, held)
    _no_links(monkeypatch)

    janitor = DeletionJanitor(world.db, executor=make_executor(world), music_library_dir=world.music)
    janitor.retry_cleanups()

    assert janitor.report_orphans() == 0
    assert master.read_bytes() == data and os.lstat(master).st_ino == ino
    assert files_under(world.music / ".deleting") == {}
    assert live(world, uuid_id)


# ── the primitive is the only link mechanism ────────────────────────────────

def test_the_put_back_uses_the_shared_primitive_without_copies(world, monkeypatch, tmp_path):
    calls = []
    real = file_ops.place_no_replace

    def spy(source, destination, **kwargs):
        calls.append(kwargs.get("allow_copy", True))
        return real(source, destination, **kwargs)

    monkeypatch.setattr(file_ops, "place_no_replace", spy)
    q = tmp_path / "q" / "x.flac"
    q.parent.mkdir()
    q.write_bytes(b"x")
    original = tmp_path / "lib" / "x.flac"

    assert deletion_worker.put_back_file(original, q, prove_identity=None) is True

    assert calls == [False]
    assert not hasattr(organizer, "link_no_replace") and not hasattr(file_ops, "link_no_replace")


def test_without_a_journaled_identity_a_rename_is_proven_by_the_quarantines_own(
        world, monkeypatch, tmp_path):
    """The worker's put-back right after its own move passes no journaled
    identity: the rename must still prove the restored file is the one it moved
    (same device and inode as the quarantine just before the rename)."""
    q = tmp_path / "q" / "x.flac"
    q.parent.mkdir()
    q.write_bytes(b"x")
    original = tmp_path / "lib" / "x.flac"
    _no_links(monkeypatch)

    def lstat(path, *args, **kwargs):
        st = _real_lstat(path, *args, **kwargs)
        if Path(path) == original:  # another file than the one renamed
            fields = list(st)
            fields[1] = st.st_ino + 1_000_000
            return os.stat_result(fields)
        return st

    monkeypatch.setattr(os, "lstat", lstat)

    assert deletion_worker.put_back_file(original, q, prove_identity=None) is False

    assert original.read_bytes() == b"x"  # nothing removed on a failed proof


def test_a_put_back_whose_quarantine_vanishes_before_the_rename_keeps_everything(
        world, monkeypatch, tmp_path):
    """The hook's look at the quarantine raises (the file vanished just before
    the rename): nothing is renamed, the folder made for it goes again, the
    journal stays."""
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    q = _quarantine(world, uuid_id)
    elsewhere = tmp_path / "taken-away"
    _no_links(monkeypatch)
    for folder in (master.parent, master.parent.parent):  # so the put-back makes them
        if folder.exists() and not any(folder.iterdir()):
            folder.rmdir()
    real = file_ops.place_no_replace
    hooked = []

    def place(source, destination, **kwargs):
        hook = kwargs["before_fallback"]

        def vanish_then_hook(mode):
            hooked.append(mode)
            os.rename(q, elsewhere)  # another program takes it away
            return hook(mode)

        return real(source, destination, **{**kwargs, "before_fallback": vanish_then_hook})

    monkeypatch.setattr(file_ops, "place_no_replace", place)
    before = journal(world, uuid_id)

    recover(world)

    assert hooked == ["rename"]
    assert not os.path.lexists(master) and not master.parent.exists()
    assert elsewhere.exists()
    _assert_kept(world, uuid_id, op, before)
