"""Sign-off DEV-7-25 link fallback, review round 1 (link-fallback-review-table.md
T-1/T-2/T-4, link-fallback-review-durability.md D-1/D-2/D-3 and nits): a temp
is removed only when the record proves this operation made it, only as a
regular file in a folder inside the owner's root; a placement that took effect
but reported an error is still removed with the failure; long names, FIFOs and
torn retries never leave a row that cannot be cleaned or a hung reader."""

import errno
import json
import os
from pathlib import Path

import pytest

from app.services import organizer, upload_placement, upload_recovery
from tests.identity_worker_fixtures import make_db, sql
from tests.upload_commit_fixtures import FakeCoverArt, journal, library_root
from tests.upload_publish_fixtures import make_publisher, prepared_commit
from tests.upload_recovery_fixtures import World
from tests.upload_validation_fixtures import item_row

_real_rename = os.rename
_real_unlink = os.unlink


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def _refuse(monkeypatch, err):
    def link(src, dst, *args, **kwargs):
        raise OSError(err, os.strerror(err))

    monkeypatch.setattr(organizer.os, "link", link)


def _record(commit) -> Path:
    return Path(str(commit["work"]) + ".place")


def _clean(db, music, commit) -> bool:
    return upload_recovery.clean_finished_journal(
        db, journal(db, commit), uploads_root=music / ".uploads", music_library_dir=music,
        cover_art=FakeCoverArt())


def _journals(db) -> int:
    return sql(db, "SELECT count(*) AS n FROM upload_commit_journal")[0]["n"]


def _prepared_in_library(db, music):
    commit = prepared_commit(db, music)
    work = Path(commit["work"])
    work.write_bytes(b"audio-A")
    root = library_root(db, music, commit["owner_id"])
    final = root / "Artist" / f"{commit['track']}.flac"
    sql(db, "UPDATE upload_commit_journal SET final_path = ?,"
            " final_metadata = json_set(final_metadata, '$.codec', 'flac')"
            " WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), commit["owner_id"], commit["op"]))
    return commit, work, root, final


# ── D-1: a file already at the temp name is never ours ──────────────────────

def test_a_foreign_file_at_the_temp_name_survives_the_failure_and_the_clean_up(db, music, monkeypatch):
    commit, _work, _root, final = _prepared_in_library(db, music)
    temp = organizer.temp_name_for(final)
    temp.parent.mkdir(parents=True)
    temp.write_bytes(b"someone else's")
    _refuse(monkeypatch, errno.EXDEV)

    assert make_publisher(db, music)(journal(db, commit)) == "failed"
    assert not _record(commit).exists()  # nothing recorded: the temp was never this call's

    assert _clean(db, music, commit)

    assert temp.read_bytes() == b"someone else's"
    assert _journals(db) == 0


def test_a_rename_records_no_temp_and_its_clean_up_removes_none(db, music, monkeypatch):
    commit, _work, root, final = _prepared_in_library(db, music)
    _refuse(monkeypatch, errno.ENOTSUP)
    temp = organizer.temp_name_for(final)

    def collide_then_place(name):
        if name == "after_place_record":
            temp.write_bytes(b"someone else's")  # appears at the temp name meanwhile

    assert make_publisher(db, music, seam=collide_then_place)(journal(db, commit)) == "imported"
    assert json.loads(_record(commit).read_text())["temp"] is False

    assert _clean(db, music, commit)

    assert temp.read_bytes() == b"someone else's"


def test_a_retry_removes_the_earlier_temp_durably_before_its_new_record(world, db, music, monkeypatch):
    """T-4: the earlier attempt's temp goes, and its folder is flushed, before
    the new record is written, so a power cut cannot bring that temp back
    behind a record that no longer names it."""
    commit = world.commit()
    _refuse(monkeypatch, errno.EXDEV)
    world.crash_at("mid_copy", commit)
    row = journal(db, commit)
    temp = organizer.temp_name_for(Path(row["final_path"]))
    record = _record(commit)
    events = []

    def unlink(path, *args, **kwargs):
        events.append(("unlink", Path(path)))
        return _real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", unlink)
    monkeypatch.setattr(upload_placement, "fsync_dir", lambda p: events.append(("fsync_dir", Path(p))))
    monkeypatch.setattr(upload_placement, "fsync_file", lambda p: events.append(("fsync_file", Path(p))))

    assert make_publisher(db, music)(row) == "imported"

    removed = events.index(("unlink", temp))
    flushed = events.index(("fsync_dir", temp.parent), removed)
    rewritten = [i for i, e in enumerate(events) if e[0] == "fsync_file" and e[1].name.startswith(record.name)]
    assert rewritten and flushed < rewritten[0]


# ── D-2: the temp's folder must really be inside the owner's root ───────────

def test_a_record_whose_final_is_a_symlink_from_outside_removes_nothing_outside(
        db, music, tmp_path):
    commit, work, root, final = _prepared_in_library(db, music)
    upload_placement.write_record(journal(db, commit), uploads_root=music / ".uploads",
                                  library_root=root, temp=True)
    final.parent.mkdir(parents=True, exist_ok=True)
    final.write_bytes(b"audio-A")
    outside = tmp_path / "outside"
    outside.mkdir()
    link = outside / final.name
    link.symlink_to(final)  # resolves inside the root
    foreign = organizer.temp_name_for(link)
    foreign.write_bytes(b"someone else's")
    record = _record(commit)
    record.write_text(json.dumps({**json.loads(record.read_text()), "final": str(link)}))

    upload_placement.clear_leftovers(journal(db, commit), uploads_root=music / ".uploads",
                                     library_root=root)

    assert foreign.read_bytes() == b"someone else's"


def test_a_symlink_at_the_temp_name_is_never_removed(db, music, tmp_path):
    commit, _work, root, final = _prepared_in_library(db, music)
    upload_placement.write_record(journal(db, commit), uploads_root=music / ".uploads",
                                  library_root=root, temp=True)
    target = tmp_path / "theirs.bin"
    target.write_bytes(b"someone else's")
    temp = organizer.temp_name_for(final)
    temp.parent.mkdir(parents=True)
    temp.symlink_to(target)

    upload_placement.clear_leftovers(journal(db, commit), uploads_root=music / ".uploads",
                                     library_root=root)

    assert temp.is_symlink() and target.read_bytes() == b"someone else's"


# ── D-3: never block on a FIFO swapped in ───────────────────────────────────

def test_the_record_and_the_final_are_opened_without_blocking(db, music, monkeypatch):
    commit, work, root, final = _prepared_in_library(db, music)
    upload_placement.write_record(journal(db, commit), uploads_root=music / ".uploads",
                                  library_root=root, temp=False)
    final.parent.mkdir(parents=True, exist_ok=True)
    os.rename(work, final)
    flags = {}
    real_open = os.open

    def spy(path, f, *args, **kwargs):
        flags[Path(path)] = f
        return real_open(path, f, *args, **kwargs)

    monkeypatch.setattr(os, "open", spy)

    assert upload_placement.final_is_placed(journal(db, commit), uploads_root=music / ".uploads",
                                            library_root=root) is True

    for path in (final, _record(commit)):
        assert flags[path] & os.O_NONBLOCK and flags[path] & os.O_NOFOLLOW


# ── T-1: a name the filesystem cannot hold is gone, never "not removed" ─────

def test_a_temp_name_too_long_to_exist_does_not_keep_the_row(db, music, monkeypatch):
    commit, _work, root, final = _prepared_in_library(db, music)
    upload_placement.write_record(journal(db, commit), uploads_root=music / ".uploads",
                                  library_root=root, temp=True)
    temp = organizer.temp_name_for(final)
    real_lstat = os.lstat

    def too_long(path, *args, **kwargs):
        if Path(path) == temp:
            raise OSError(errno.ENAMETOOLONG, os.strerror(errno.ENAMETOOLONG))
        return real_lstat(path, *args, **kwargs)

    monkeypatch.setattr(os, "lstat", too_long)

    assert upload_placement.clear_leftovers(journal(db, commit), uploads_root=music / ".uploads",
                                            library_root=root) is True
    assert not _record(commit).exists()


# ── T-2: a placement that took effect but reported an error ─────────────────

def test_a_rename_that_happened_but_reported_an_error_is_removed_with_the_failure(
        db, music, monkeypatch):
    commit, work, _root, final = _prepared_in_library(db, music)
    _refuse(monkeypatch, errno.ENOTSUP)

    def rename(src, dst, *args, **kwargs):
        _real_rename(src, dst, *args, **kwargs)
        raise FileNotFoundError(errno.ENOENT, "reply lost")  # an NFS retransmit

    monkeypatch.setattr(organizer.os, "rename", rename)

    assert make_publisher(db, music)(journal(db, commit)) == "failed"

    assert item_row(db, commit)["state"] == "review_ready"
    assert journal(db, commit)["final_path"] == str(final)  # recorded as placed
    assert not final.exists()  # removed with the failure, never orphaned
    assert _clean(db, music, commit)
    assert not _record(commit).exists()


@pytest.mark.parametrize("err", [errno.ENOTSUP, errno.EXDEV])
def test_a_fallback_failure_after_placement_removes_the_placed_file(world, db, music, monkeypatch, err):
    commit = world.commit()
    _refuse(monkeypatch, err)

    def boom(**kwargs):
        raise RuntimeError("insert failed")

    monkeypatch.setattr(db, "publish_upload_commit", boom)

    assert world.worker().process_one() == "failed"
    row = journal(db, commit)
    final = Path(row["final_path"])

    assert not final.exists()
    assert item_row(db, commit)["state"] == "review_ready"
    assert commit["source"].exists()
    assert _clean(db, music, commit)
    assert not _record(commit).exists()
    assert not os.path.lexists(organizer.temp_name_for(final))


# ── nits ────────────────────────────────────────────────────────────────────

def test_the_records_removal_is_flushed(db, music, monkeypatch):
    commit, _work, root, _final = _prepared_in_library(db, music)
    upload_placement.write_record(journal(db, commit), uploads_root=music / ".uploads",
                                  library_root=root, temp=False)
    events = []

    def unlink(path, *args, **kwargs):
        events.append(("unlink", Path(path)))
        return _real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", unlink)
    monkeypatch.setattr(upload_placement, "fsync_dir", lambda p: events.append(("fsync_dir", Path(p))))

    assert upload_placement.clear_leftovers(journal(db, commit), uploads_root=music / ".uploads",
                                            library_root=root) is True

    removed = events.index(("unlink", _record(commit)))
    assert ("fsync_dir", _record(commit).parent) in events[removed:]


def test_a_journal_without_a_work_path_has_no_leftovers(db, music):
    commit, _work, root, _final = _prepared_in_library(db, music)

    assert upload_placement.clear_leftovers({**journal(db, commit), "work_path": None},
                                            uploads_root=music / ".uploads", library_root=root) is True


# ── re-check R1-1: the copy's work-file hash happens before its temp exists ──

def test_a_copy_reads_the_work_file_before_it_creates_its_temp(db, music, monkeypatch):
    """The window between the temp's O_EXCL create and the flushed record
    (where a kill leaves a temp nobody can prove) holds no full read of the
    work file, only the record's write."""
    commit, work, _root, final = _prepared_in_library(db, music)
    _refuse(monkeypatch, errno.EXDEV)
    temp = organizer.temp_name_for(final)
    opened = []
    real_open = os.open

    def spy(path, flags, *args, **kwargs):
        opened.append((Path(path), flags))
        return real_open(path, flags, *args, **kwargs)

    monkeypatch.setattr(os, "open", spy)

    assert make_publisher(db, music)(journal(db, commit)) == "imported"

    hashed = [i for i, (p, f) in enumerate(opened) if p == work and not f & (os.O_WRONLY | os.O_RDWR)]
    created = [i for i, (p, f) in enumerate(opened) if p == temp and f & os.O_EXCL]
    assert hashed and created and hashed[0] < created[0]
    assert json.loads(_record(commit).read_text())["temp"] is True
