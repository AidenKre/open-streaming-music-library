"""Sign-off DEV-7-25 / DEV-7-15 point 3, link fallback (A2): an import whose
library refuses hard links is moved (same filesystem) or copied (another
filesystem) into place. Before anything moves, a placement record next to the
work file holds the prepared file's size and sha256 (flushed); after a crash
it proves whether the library file is this import's. A refusal for another
reason, a real permission problem or a full disk stays an ordinary retryable
failure (a full disk answers ``insufficient_storage``)."""

import errno
import hashlib
import json
import os
import shutil
from collections import namedtuple
from pathlib import Path

import pytest

from app.services import organizer, upload_placement
from tests.identity_worker_fixtures import make_db, sql
from tests.upload_commit_fixtures import accept, journal, library_root, make_commit_worker, ready_item
from tests.upload_publish_fixtures import make_publisher, prepared_commit
from tests.upload_validation_fixtures import item_row

_real_link = os.link
_Usage = namedtuple("_Usage", "total used free")


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _accepted(db, music, content=b"audio-A"):
    return accept(db, ready_item(db, music / ".uploads", content=content))


def _refuse(monkeypatch, err, *, only_uploads=None):
    """``os.link`` refuses with ``err``; with ``only_uploads`` only links whose
    source is under that folder (the temp -> final link then really happens)."""

    def link(src, dst, *args, **kwargs):
        if only_uploads is None or Path(src).is_relative_to(only_uploads):
            raise OSError(err, os.strerror(err))
        return _real_link(src, dst, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "link", link)


MODES = {
    "rename-EPERM": dict(err=errno.EPERM, cross=False),
    "rename-ENOTSUP": dict(err=errno.ENOTSUP, cross=False),
    "rename-EMLINK": dict(err=errno.EMLINK, cross=False),
    "copy-linked": dict(err=errno.EXDEV, cross=True),
    "copy-renamed": dict(err=errno.EXDEV, cross=False),
}


def _mode(monkeypatch, music, name):
    spec = MODES[name]
    _refuse(monkeypatch, spec["err"], only_uploads=music / ".uploads" if spec["cross"] else None)


def _tree(root: Path) -> set:
    return {p.relative_to(root) for p in root.rglob("*")} if root.exists() else set()


def _record(commit) -> Path:
    return Path(str(commit["work"]) + ".place")


def _final(db, commit) -> Path:
    return Path(journal(db, commit)["final_path"])


# ── the import goes through on a library without hard links ─────────────────

@pytest.mark.parametrize("mode", list(MODES))
def test_a_library_without_hard_links_still_imports(db, music, monkeypatch, caplog, mode):
    commit = _accepted(db, music)
    _mode(monkeypatch, music, mode)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    with caplog.at_level("INFO", logger="uvicorn.error"):
        assert worker.process_one() == "imported"

    item = item_row(db, commit)
    assert item["state"] == "imported"
    [track] = sql(db, "SELECT file_path FROM tracks WHERE uuid_id = ?", (commit["track"],))
    assert Path(track["file_path"]).read_bytes() == commit["content"]
    assert not commit["work"].exists()
    assert not os.path.lexists(organizer.temp_name_for(Path(track["file_path"])))
    record = json.loads(_record(commit).read_text())  # kept until the journal clean-up
    assert record == {"v": 1, "sha256": hashlib.sha256(commit["content"]).hexdigest(),
                      "size": len(commit["content"]), "final": track["file_path"],
                      "temp": mode.startswith("copy")}
    operator = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert len(operator) == 1 and "hard links" in operator[0] and "/" not in operator[0]


def test_the_operator_line_is_written_once_per_process(db, music, monkeypatch, caplog):
    publisher = make_publisher(db, music)
    worker = make_commit_worker(db, music, after_prepared=publisher)
    _mode(monkeypatch, music, "rename-ENOTSUP")

    with caplog.at_level("INFO", logger="uvicorn.error"):
        first = _accepted(db, music, b"audio-A")
        assert worker.process_one() == "imported"
        second = _accepted(db, music, b"audio-B")
        assert worker.process_one() == "imported"

    assert item_row(db, first)["state"] == item_row(db, second)["state"] == "imported"
    assert len([r for r in caplog.records if r.name == "uvicorn.error"]) == 1


def test_a_hard_link_import_writes_no_record(db, music):
    commit = _accepted(db, music)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "imported"

    assert not _record(commit).exists()


def test_the_record_is_on_disk_before_the_file_moves(db, music, monkeypatch):
    commit = _accepted(db, music)
    events = []
    real_rename = os.rename
    monkeypatch.setattr(upload_placement, "fsync_file",
                        lambda p: events.append(("fsync_file", Path(p).name)))
    monkeypatch.setattr(upload_placement, "fsync_dir",
                        lambda p: events.append(("fsync_dir", Path(p))))

    def rename(src, dst, *args, **kwargs):
        events.append(("rename", Path(src).name))
        return real_rename(src, dst, *args, **kwargs)

    _mode(monkeypatch, music, "rename-ENOTSUP")
    monkeypatch.setattr(organizer.os, "rename", rename)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "imported"

    moved = events.index(("rename", commit["work"].name))
    assert ("fsync_file", _record(commit).name) in events[:moved]
    assert ("fsync_dir", commit["work"].parent) in events[:moved]


# ── failures stay ordinary and retryable ────────────────────────────────────

def test_a_real_permission_refusal_behind_eperm_places_nothing(db, music, monkeypatch):
    commit = _accepted(db, music)
    library = library_root(db, music, commit["owner_id"])
    library.mkdir(parents=True, exist_ok=True)
    before = _tree(library)
    _refuse(monkeypatch, errno.EPERM)

    def rename(src, dst, *args, **kwargs):
        raise PermissionError(errno.EACCES, os.strerror(errno.EACCES))

    monkeypatch.setattr(organizer.os, "rename", rename)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "failed"

    item = item_row(db, commit)
    assert (item["state"], item["error_code"], item["error_retryable"]) == (
        "review_ready", "upload_commit_failed", 1)
    assert _tree(library) == before  # nothing placed, no folder left
    assert not commit["work"].exists()
    assert commit["source"].exists()


def _full_disk(*_args, **_kwargs):
    raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))


@pytest.mark.parametrize("where", ["link", "rename", "copy"])
def test_a_full_disk_while_placing_answers_insufficient_storage(db, music, monkeypatch, where):
    """O2: ENOSPC while placing is the retryable full-disk answer in every mode."""
    commit = _accepted(db, music)
    library = library_root(db, music, commit["owner_id"])
    library.mkdir(parents=True, exist_ok=True)
    seam = None
    if where == "link":
        _refuse(monkeypatch, errno.ENOSPC)
    elif where == "rename":
        _refuse(monkeypatch, errno.ENOTSUP)
        monkeypatch.setattr(organizer.os, "rename", _full_disk)
    else:
        _refuse(monkeypatch, errno.EXDEV)

        def seam(name):
            if name == "mid_copy":
                _full_disk()

    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music, seam=seam))

    assert worker.process_one() == "failed"

    item = item_row(db, commit)
    assert (item["state"], item["error_code"], item["error_retryable"]) == (
        "review_ready", "insufficient_storage", 1)
    assert _tree(library) == set()  # no temp, no folder
    assert commit["source"].exists()


def test_a_quota_refusal_while_placing_also_answers_insufficient_storage(db, music, monkeypatch):
    commit = _accepted(db, music)
    _refuse(monkeypatch, errno.EDQUOT)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "failed"

    assert item_row(db, commit)["error_code"] == "insufficient_storage"


def test_another_failure_while_placing_stays_upload_commit_failed(db, music, monkeypatch):
    commit = _accepted(db, music)
    _refuse(monkeypatch, errno.EIO)
    worker = make_commit_worker(db, music, after_prepared=make_publisher(db, music))

    assert worker.process_one() == "failed"

    item = item_row(db, commit)
    assert (item["error_code"], item["error_retryable"]) == ("upload_commit_failed", 1)


# ── the free-space floor before a copy (Q1) ─────────────────────────────────

def test_a_copy_below_the_floor_is_refused_as_a_full_disk(db, music, monkeypatch):
    commit = _accepted(db, music)
    library = library_root(db, music, commit["owner_id"])
    library.mkdir(parents=True, exist_ok=True)
    _refuse(monkeypatch, errno.EXDEV)
    monkeypatch.setattr(shutil, "disk_usage", lambda p: _Usage(10**9, 0, 10**6))
    worker = make_commit_worker(
        db, music, after_prepared=make_publisher(db, music, copy_floor_bytes=10**6))

    assert worker.process_one() == "failed"

    item = item_row(db, commit)
    assert (item["state"], item["error_code"], item["error_retryable"]) == (
        "review_ready", "insufficient_storage", 1)
    assert _tree(library) == set()
    assert commit["source"].exists()


@pytest.mark.parametrize("mode", ["link", "rename-ENOTSUP"])
def test_the_floor_is_not_consulted_when_nothing_is_copied(db, music, monkeypatch, mode):
    commit = _accepted(db, music)
    library = library_root(db, music, commit["owner_id"])
    if mode != "link":
        _mode(monkeypatch, music, mode)
    asked = []
    real_usage = shutil.disk_usage

    def usage(p):
        asked.append(Path(p))
        return real_usage(p)

    monkeypatch.setattr(shutil, "disk_usage", usage)
    worker = make_commit_worker(
        db, music, after_prepared=make_publisher(db, music, copy_floor_bytes=10**18))

    assert worker.process_one() == "imported"

    assert not [p for p in asked if p.is_relative_to(library)]


# ── the proof: size + sha256 of the final against the record ────────────────

def _placed_row(db, music, *, content=b"audio-A", final_bytes=None):
    """A prepared journal in the owner's library whose record was written and
    whose work file was then moved (or replaced) at the final name."""
    commit = prepared_commit(db, music, content=content)
    work = Path(commit["work"])
    work.write_bytes(content)
    root = library_root(db, music, commit["owner_id"])
    final = root / "Artist" / f"{commit['track']}.flac"
    sql(db, "UPDATE upload_commit_journal SET final_path = ? WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), commit["owner_id"], commit["op"]))
    row = journal(db, commit)
    # as a copy writes it: the temp (made first, with O_EXCL) is this call's
    upload_placement.write_record(row, uploads_root=music / ".uploads", library_root=root, temp=True)
    final.parent.mkdir(parents=True, exist_ok=True)
    if final_bytes is None:
        os.rename(work, final)
    else:
        final.write_bytes(final_bytes)
    return commit, row, root, work, final


def _placed(music, row, root):
    return upload_placement.final_is_placed(row, uploads_root=music / ".uploads", library_root=root)


def test_a_final_with_the_recorded_bytes_is_proven_ours(db, music):
    _commit, row, root, _work, _final = _placed_row(db, music)

    assert _placed(music, row, root) is True


def test_a_final_with_other_bytes_of_the_same_size_is_not_ours(db, music):
    _commit, row, root, _work, _final = _placed_row(db, music, final_bytes=b"audio-B")

    assert _placed(music, row, root) is False


def test_without_a_record_even_identical_bytes_are_not_proof(db, music):
    _commit, row, root, work, final = _placed_row(db, music)
    Path(str(work) + ".place").unlink()

    assert _placed(music, row, root) is False


@pytest.mark.parametrize("text", ["", "{", '{"v": 2, "sha256": "x", "size": 7}', '{"v": 1}', "[]"])
def test_an_unusable_record_is_no_proof(db, music, text):
    _commit, row, root, work, _final = _placed_row(db, music)
    Path(str(work) + ".place").write_text(text)

    assert _placed(music, row, root) is False


def test_a_symlink_at_the_final_name_is_never_ours(db, music, tmp_path):
    _commit, row, root, _work, final = _placed_row(db, music)
    real = tmp_path / "elsewhere.flac"
    os.rename(final, real)
    final.symlink_to(real)  # same bytes behind it

    assert _placed(music, row, root) is False


def test_a_final_that_cannot_be_read_is_unknown(db, music, monkeypatch):
    _commit, row, root, _work, final = _placed_row(db, music)
    real_open = os.open

    def deny(path, *args, **kwargs):
        if Path(path) == final:
            raise PermissionError(errno.EACCES, "denied")
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr(upload_placement.os, "open", deny)

    with pytest.raises(organizer.LinkUnknown):
        _placed(music, row, root)


def test_the_final_is_hashed_in_bounded_blocks_without_following_links(db, music, monkeypatch):
    content = b"x" * 1000
    _commit, row, root, _work, final = _placed_row(db, music, content=content)
    monkeypatch.setattr(upload_placement, "HASH_BLOCK_BYTES", 64)
    opened, sizes, final_fds = [], [], set()
    real_open, real_read = os.open, os.read

    def spy_open(path, flags, *args, **kwargs):
        opened.append((Path(path), flags))
        fd = real_open(path, flags, *args, **kwargs)
        if Path(path) == final:
            final_fds.add(fd)
        return fd

    def spy_read(fd, n):
        if fd in final_fds:
            sizes.append(n)
        return real_read(fd, n)

    monkeypatch.setattr(upload_placement.os, "open", spy_open)
    monkeypatch.setattr(upload_placement.os, "read", spy_read)

    assert _placed(music, row, root) is True

    final_flags = [flags for path, flags in opened if path == final]
    assert final_flags and all(flags & os.O_NOFOLLOW for flags in final_flags)
    assert len(sizes) >= len(content) // 64 and max(sizes) <= 64


def test_a_tampered_final_outside_the_owners_root_is_never_hashed(db, music, tmp_path, monkeypatch):
    _commit, row, root, _work, final = _placed_row(db, music)
    outside = tmp_path / "outside" / final.name
    outside.parent.mkdir()
    os.rename(final, outside)
    row = {**row, "final_path": str(outside)}
    record = Path(row["work_path"] + ".place")  # the record names it too: only the root guard is left
    record.write_text(json.dumps({**json.loads(record.read_text()), "final": str(outside)}))
    opened = []
    real_open = os.open

    def spy_open(path, *args, **kwargs):
        opened.append(Path(path))
        return real_open(path, *args, **kwargs)

    monkeypatch.setattr(upload_placement.os, "open", spy_open)

    assert _placed(music, row, root) is False
    assert outside not in opened


# ── leftovers: the temp and the record ─────────────────────────────────────

def _leftovers(music, row, root):
    return upload_placement.clear_leftovers(row, uploads_root=music / ".uploads", library_root=root)


def test_the_clean_up_removes_the_temp_then_the_record(db, music):
    _commit, row, root, work, final = _placed_row(db, music)
    temp = organizer.temp_name_for(final)
    temp.write_bytes(b"half a cop")

    assert _leftovers(music, row, root) is True

    assert not os.path.lexists(temp)
    assert not Path(str(work) + ".place").exists()
    assert final.exists()  # the placed file is never a leftover


def test_a_temp_without_a_record_is_never_touched(db, music):
    _commit, row, root, work, final = _placed_row(db, music)
    Path(str(work) + ".place").unlink()
    temp = organizer.temp_name_for(final)
    temp.write_bytes(b"not provably ours")

    assert _leftovers(music, row, root) is True

    assert temp.read_bytes() == b"not provably ours"


def test_the_record_stays_while_the_temp_cannot_be_removed(db, music, monkeypatch):
    _commit, row, root, work, final = _placed_row(db, music)
    temp = organizer.temp_name_for(final)
    temp.write_bytes(b"half a cop")
    real_unlink = os.unlink

    def unlink(path, *args, **kwargs):
        if Path(path) == temp:
            raise PermissionError(errno.EACCES, "denied")
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(os, "unlink", unlink)

    assert _leftovers(music, row, root) is False

    assert Path(str(work) + ".place").exists()  # still the proof for a later pass


def test_a_tampered_final_outside_the_owners_root_has_no_temp_removed(db, music, tmp_path):
    """The temp is found from the record (written before the temp existed),
    never from the row: a row naming an outside final touches nothing there."""
    _commit, row, root, work, final = _placed_row(db, music)
    outside = tmp_path / "outside" / final.name
    outside.parent.mkdir()
    temp = organizer.temp_name_for(outside)
    temp.write_bytes(b"someone else's")
    row = {**row, "final_path": str(outside)}

    _leftovers(music, row, root)

    assert temp.read_bytes() == b"someone else's"


def test_a_record_naming_a_final_outside_the_owners_root_removes_nothing(db, music, tmp_path):
    _commit, row, root, work, final = _placed_row(db, music)
    outside = tmp_path / "outside" / final.name
    outside.parent.mkdir()
    temp = organizer.temp_name_for(outside)
    temp.write_bytes(b"someone else's")
    record = Path(str(work) + ".place")
    record.write_text(json.dumps({**json.loads(record.read_text()), "final": str(outside)}))

    assert _leftovers(music, row, root) is False
    assert _placed(music, {**row, "final_path": str(outside)}, root) is False

    assert temp.read_bytes() == b"someone else's"
    assert record.exists()


def test_a_record_for_another_final_name_is_no_proof(db, music):
    _commit, row, root, work, final = _placed_row(db, music)
    record = Path(str(work) + ".place")
    record.write_text(json.dumps({**json.loads(record.read_text()),
                                  "final": str(final.with_name("other.flac"))}))

    assert _placed(music, row, root) is False


def test_the_temp_of_a_journal_whose_final_path_was_cleared_is_still_found(db, music):
    """A crash mid-copy, then a conflict or a recovered failure clears the
    journal's final_path: the record still names the temp's folder."""
    _commit, row, root, work, final = _placed_row(db, music, final_bytes=b"")
    final.unlink()
    temp = organizer.temp_name_for(final)
    temp.write_bytes(b"half a cop")

    assert _leftovers(music, {**row, "final_path": None}, root) is True

    assert not os.path.lexists(temp)
    assert not Path(str(work) + ".place").exists()


def test_a_tampered_work_path_outside_the_owners_stage_is_never_trusted(db, music, tmp_path):
    _commit, row, root, work, final = _placed_row(db, music)
    elsewhere = tmp_path / "elsewhere" / work.name
    elsewhere.parent.mkdir()
    os.rename(str(work) + ".place", str(elsewhere) + ".place")
    row = {**row, "work_path": str(elsewhere)}

    assert _placed(music, row, root) is False
    assert _leftovers(music, row, root) is False
    assert Path(str(elsewhere) + ".place").exists()


# ── a retry after a crash in the middle of a copy ───────────────────────────

def test_a_retry_removes_its_own_half_copy_and_imports(db, music, monkeypatch):
    commit = _accepted(db, music)
    _refuse(monkeypatch, errno.EXDEV)

    class Crash(BaseException):
        pass

    def seam(name):
        if name == "mid_copy":
            raise Crash()

    publisher = make_publisher(db, music, seam=seam)
    with pytest.raises(Crash):
        make_commit_worker(db, music, after_prepared=publisher).process_one()
    row = journal(db, commit)
    temp = organizer.temp_name_for(Path(row["final_path"]))
    assert os.path.lexists(temp) and _record(commit).exists()

    assert make_publisher(db, music)(row) == "imported"

    assert not os.path.lexists(temp)
    assert Path(journal(db, commit)["final_path"]).read_bytes() == commit["content"]


def test_a_file_at_the_temp_name_without_a_record_fails_the_copy_and_stays(db, music, monkeypatch):
    commit = prepared_commit(db, music)
    work = Path(commit["work"])
    work.write_bytes(b"audio-A")
    root = library_root(db, music, commit["owner_id"])
    final = root / "Artist" / f"{commit['track']}.flac"
    sql(db, "UPDATE upload_commit_journal SET final_path = ? WHERE owner_id = ? AND operation_uuid = ?",
        (str(final), commit["owner_id"], commit["op"]))
    temp = organizer.temp_name_for(final)
    temp.parent.mkdir(parents=True)
    temp.write_bytes(b"someone else's")
    _refuse(monkeypatch, errno.EXDEV)

    assert make_publisher(db, music)(journal(db, commit)) == "failed"

    assert temp.read_bytes() == b"someone else's"
    assert not final.exists()
    assert item_row(db, commit)["error_code"] == "upload_commit_failed"
