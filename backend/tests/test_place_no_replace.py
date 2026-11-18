"""Sign-off DEV-7-25 / DEV-7-15 point 3, link fallback (A1): the one primitive
"put a file at a library name without ever replacing anything, hard link
first". Where the filesystem refuses the hard link it moves the file (same
filesystem) or copies it through a temporary name in the destination folder
(EXDEV), calling the caller's record hook before anything moves."""

import errno
import os
import shutil
from collections import namedtuple
from pathlib import Path

import pytest

from app.services import organizer

FALLBACK_RENAME = [errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EMLINK]
_real_link = os.link
_real_rename = os.rename
_Usage = namedtuple("_Usage", "total used free")


def _never(_path):
    return False


@pytest.fixture
def paths(tmp_path):
    source = tmp_path / "uploads" / "work.flac"
    source.parent.mkdir()
    source.write_bytes(b"prepared-bytes" * 100)
    library = tmp_path / "library"
    library.mkdir()
    return source, library, library / "Artist" / "Album" / "song.flac"


def _refuse(monkeypatch, err, *, only_from=None):
    """``os.link`` refuses with ``err`` (only for links whose source is
    ``only_from`` when given; other links really happen)."""

    def link(src, dst, *args, **kwargs):
        if only_from is None or Path(src) == Path(only_from):
            raise OSError(err, os.strerror(err))
        return _real_link(src, dst, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "link", link)


def _tree(root: Path) -> set:
    return {p.relative_to(root) for p in root.rglob("*")}


class Recorder:
    """Records hook calls, fsyncs, links and renames in order."""

    def __init__(self, monkeypatch):
        self.events = []
        self.modes = []
        monkeypatch.setattr(organizer, "fsync_file", self._fsync_file, raising=False)
        monkeypatch.setattr(organizer, "fsync_dir", self._fsync_dir)
        link, rename = os.link, os.rename

        def rec_link(src, dst, *args, **kwargs):
            self.events.append(("link", Path(src).name, Path(dst).name))
            return link(src, dst, *args, **kwargs)

        def rec_rename(src, dst, *args, **kwargs):
            self.events.append(("rename", Path(src).name, Path(dst).name))
            return rename(src, dst, *args, **kwargs)

        monkeypatch.setattr(organizer.os, "link", rec_link)
        monkeypatch.setattr(organizer.os, "rename", rec_rename)

    def hook(self, mode):
        self.modes.append(mode)
        self.events.append(("hook", mode))

    def _fsync_file(self, path):
        self.events.append(("fsync_file", Path(path).name))

    def _fsync_dir(self, path):
        self.events.append(("fsync_dir", Path(path).name))


def test_the_temp_name_is_hidden_next_to_the_final_name_and_bounded(tmp_path):
    """Review T-1: a fixed-length name, so a final name near the filesystem's
    255-byte limit still has a temp name that fits."""
    final = tmp_path / "Artist" / "song-1234.flac"
    long_final = tmp_path / "Artist" / (("é" * 120) + "-1234.flac")  # 255 bytes in UTF-8
    temp, long_temp = organizer.temp_name_for(final), organizer.temp_name_for(long_final)

    assert temp.parent == long_temp.parent == tmp_path / "Artist"
    for name in (temp.name, long_temp.name):
        assert name.startswith(".") and name.endswith(".osml-part")
        assert len(name.encode()) <= 48
    assert temp != long_temp
    assert organizer.temp_name_for(final) == temp  # derived, not random


def test_a_filesystem_that_takes_links_links_and_never_calls_the_hook(paths, monkeypatch):
    source, _library, final = paths
    modes = []
    monkeypatch.setattr(shutil, "disk_usage", lambda p: pytest.fail("floor consulted"))

    assert organizer.place_no_replace(
        source, final, in_use=_never, before_fallback=modes.append, copy_floor_bytes=10**15) == "linked"

    assert os.path.samefile(source, final)
    assert modes == []


@pytest.mark.parametrize("err", FALLBACK_RENAME)
def test_a_refused_link_on_one_filesystem_renames_after_the_hook(paths, monkeypatch, err):
    source, _library, final = paths
    content = source.read_bytes()
    rec = Recorder(monkeypatch)
    _refuse(monkeypatch, err)  # replaces the recording link: links refuse
    monkeypatch.setattr(shutil, "disk_usage", lambda p: pytest.fail("floor consulted"))

    assert organizer.place_no_replace(
        source, final, in_use=_never, before_fallback=rec.hook, copy_floor_bytes=10**15) == "moved"

    assert final.read_bytes() == content
    assert not source.exists()
    assert rec.modes == ["rename"]
    names = [e[0] for e in rec.events]
    assert names.index("hook") < names.index("rename")
    assert ("fsync_dir", "Album") in rec.events[names.index("rename"):]


def _copy_events(rec):
    return [e for e in rec.events if e[0] in ("hook", "fsync_file", "link", "rename")]


def test_a_link_across_filesystems_copies_through_the_temp_and_links_it(paths, monkeypatch):
    source, _library, final = paths
    content = source.read_bytes()
    rec = Recorder(monkeypatch)
    recording_link = os.link

    def link(src, dst, *args, **kwargs):
        if Path(src) == source:
            raise OSError(errno.EXDEV, os.strerror(errno.EXDEV))
        return recording_link(src, dst, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "link", link)
    temp = organizer.temp_name_for(final)

    assert organizer.place_no_replace(source, final, in_use=_never, before_fallback=rec.hook) == "copied"

    assert final.read_bytes() == content
    assert source.read_bytes() == content  # the caller removes the source after its journal
    assert not os.path.lexists(temp)
    assert _copy_events(rec) == [("hook", "copy"), ("fsync_file", temp.name),
                                 ("link", temp.name, final.name)]
    placed = rec.events.index(("link", temp.name, final.name))
    assert ("fsync_dir", "Album") in rec.events[placed:]


def test_a_copy_onto_a_filesystem_without_links_renames_the_temp(paths, monkeypatch):
    source, _library, final = paths
    content = source.read_bytes()
    rec = Recorder(monkeypatch)
    _refuse(monkeypatch, errno.EXDEV)  # every link refused
    temp = organizer.temp_name_for(final)

    assert organizer.place_no_replace(source, final, in_use=_never, before_fallback=rec.hook) == "copied"

    assert final.read_bytes() == content
    assert source.read_bytes() == content
    assert not os.path.lexists(temp)
    assert [e for e in _copy_events(rec) if e[0] != "link"] == [
        ("hook", "copy"), ("fsync_file", temp.name), ("rename", temp.name, final.name)]


@pytest.mark.parametrize("err", [errno.ENOTSUP, errno.EXDEV])
def test_an_existing_final_name_is_never_replaced(paths, monkeypatch, err):
    source, _library, final = paths
    final.parent.mkdir(parents=True)
    final.write_bytes(b"someone else's file")
    _refuse(monkeypatch, err)

    assert organizer.place_no_replace(source, final, in_use=_never) is None

    assert final.read_bytes() == b"someone else's file"
    assert source.exists()
    assert not os.path.lexists(organizer.temp_name_for(final))


def test_a_name_that_appears_just_before_the_rename_is_never_replaced(paths, monkeypatch):
    source, _library, final = paths
    _refuse(monkeypatch, errno.ENOTSUP)

    def hook(_mode):  # another program writes the name after the link was refused
        final.write_bytes(b"someone else's file")

    assert organizer.place_no_replace(source, final, in_use=_never, before_fallback=hook) is None

    assert final.read_bytes() == b"someone else's file"
    assert source.exists()


@pytest.mark.parametrize("inner_link", [True, False])
def test_a_name_that_appears_during_the_copy_is_never_replaced(paths, monkeypatch, inner_link):
    source, _library, final = paths
    _refuse(monkeypatch, errno.EXDEV, only_from=source if inner_link else None)

    def seam(name):
        if name == "after_copy":
            final.write_bytes(b"someone else's file")

    assert organizer.place_no_replace(source, final, in_use=_never, seam=seam) is None

    assert final.read_bytes() == b"someone else's file"
    assert source.exists()
    assert not os.path.lexists(organizer.temp_name_for(final))


@pytest.mark.parametrize("err", [errno.ENOTSUP, errno.EXDEV])
def test_a_name_a_track_uses_is_refused_before_the_hook(paths, monkeypatch, err):
    source, library, final = paths
    _refuse(monkeypatch, err)
    modes = []

    assert organizer.place_no_replace(source, final, in_use=lambda p: p == final,
                                      before_fallback=modes.append) is None

    assert modes == []
    assert _tree(library) == set()
    assert source.exists()


@pytest.mark.parametrize("err", [errno.EIO, errno.EACCES, errno.ENOSPC, errno.EROFS])
def test_another_link_refusal_is_not_a_fallback(paths, monkeypatch, err):
    source, library, final = paths
    _refuse(monkeypatch, err)
    modes = []

    with pytest.raises(organizer.HardLinkError) as e:
        organizer.place_no_replace(source, final, in_use=_never, before_fallback=modes.append)

    assert e.value.errno == err
    assert modes == []
    assert _tree(library) == set()  # the folders made for the link are gone
    assert source.exists()


def test_a_real_permission_refusal_after_eperm_fails_with_nothing_placed(paths, monkeypatch):
    """EPERM is a fallback trigger; if it was a real permission problem the
    rename fails too: a plain OSError, nothing placed, no folder left."""
    source, library, final = paths
    _refuse(monkeypatch, errno.EPERM)

    def rename(src, dst, *args, **kwargs):
        raise PermissionError(errno.EACCES, os.strerror(errno.EACCES))

    monkeypatch.setattr(organizer.os, "rename", rename)

    with pytest.raises(OSError) as e:
        organizer.place_no_replace(source, final, in_use=_never)

    assert not isinstance(e.value, organizer.HardLinkError)
    assert e.value.errno == errno.EACCES
    assert _tree(library) == set()
    assert source.exists()


def test_a_failed_copy_removes_its_temp_and_folders(paths, monkeypatch):
    source, library, final = paths
    _refuse(monkeypatch, errno.EXDEV)

    def seam(name):
        if name == "mid_copy":
            raise OSError(errno.ENOSPC, os.strerror(errno.ENOSPC))

    with pytest.raises(OSError) as e:
        organizer.place_no_replace(source, final, in_use=_never, seam=seam)

    assert not isinstance(e.value, organizer.HardLinkError)
    assert e.value.errno == errno.ENOSPC
    assert _tree(library) == set()  # temp and the folders made for it are gone
    assert source.exists()


def test_a_failing_hook_places_nothing_and_leaves_no_folder(paths, monkeypatch):
    source, library, final = paths
    _refuse(monkeypatch, errno.ENOTSUP)

    def hook(_mode):
        raise OSError(errno.EIO, os.strerror(errno.EIO))

    with pytest.raises(OSError):
        organizer.place_no_replace(source, final, in_use=_never, before_fallback=hook)

    assert _tree(library) == set()
    assert source.exists()


def test_a_crash_mid_copy_leaves_the_temp_for_recovery(paths, monkeypatch):
    class Crash(BaseException):
        pass

    source, _library, final = paths
    _refuse(monkeypatch, errno.EXDEV)

    def seam(name):
        if name == "mid_copy":
            raise Crash()

    with pytest.raises(Crash):
        organizer.place_no_replace(source, final, in_use=_never, seam=seam)

    assert os.path.lexists(organizer.temp_name_for(final))
    assert not os.path.lexists(final)


def test_a_file_already_at_the_temp_name_is_never_overwritten_or_removed(paths, monkeypatch):
    source, _library, final = paths
    temp = organizer.temp_name_for(final)
    temp.parent.mkdir(parents=True)
    temp.write_bytes(b"not this call's")
    _refuse(monkeypatch, errno.EXDEV)

    with pytest.raises(OSError):
        organizer.place_no_replace(source, final, in_use=_never)

    assert temp.read_bytes() == b"not this call's"
    assert not os.path.lexists(final)
    assert source.exists()


def test_a_temp_that_cannot_be_removed_after_its_link_still_counts_as_placed(paths, monkeypatch):
    source, _library, final = paths
    _refuse(monkeypatch, errno.EXDEV, only_from=source)
    temp = organizer.temp_name_for(final)
    real_unlink = os.unlink

    def unlink(path, *args, **kwargs):
        if Path(path) == temp:
            raise PermissionError(errno.EACCES, "denied")
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(organizer.os, "unlink", unlink)

    assert organizer.place_no_replace(source, final, in_use=_never) == "copied"

    assert final.read_bytes() == source.read_bytes()


# ── the free-space floor before a copy (Q1) ────────────────────────────────

def test_a_copy_that_would_go_below_the_floor_is_refused_with_nothing_made(paths, monkeypatch):
    source, library, final = paths
    _refuse(monkeypatch, errno.EXDEV)
    size = source.stat().st_size
    monkeypatch.setattr(shutil, "disk_usage", lambda p: _Usage(10**9, 0, 1000 + size - 1))
    modes = []

    with pytest.raises(OSError) as e:
        organizer.place_no_replace(source, final, in_use=_never, before_fallback=modes.append,
                                   copy_floor_bytes=1000)

    assert e.value.errno == errno.ENOSPC
    assert not isinstance(e.value, organizer.HardLinkError)
    assert _tree(library) == set()
    assert source.exists()


def test_a_copy_that_stays_above_the_floor_goes_ahead(paths, monkeypatch):
    source, _library, final = paths
    _refuse(monkeypatch, errno.EXDEV)
    size = source.stat().st_size
    seen = []

    def usage(p):
        seen.append(Path(p))
        return _Usage(10**9, 0, 1000 + size)

    monkeypatch.setattr(shutil, "disk_usage", usage)

    assert organizer.place_no_replace(source, final, in_use=_never, copy_floor_bytes=1000) == "copied"

    assert seen and all(p.is_relative_to(final.parent.parent.parent) for p in seen)


def test_without_copies_allowed_a_link_across_filesystems_fails_with_nothing_placed(paths, monkeypatch):
    source, library, final = paths
    _refuse(monkeypatch, errno.EXDEV)

    with pytest.raises(OSError) as e:
        organizer.place_no_replace(source, final, in_use=_never, allow_copy=False)

    assert e.value.errno == errno.EXDEV
    assert _tree(library) == set()
    assert source.exists()


# ── link_no_replace keeps its contract (Phase 8's put-back still uses it) ──

@pytest.mark.parametrize("err", [errno.EXDEV, errno.ENOTSUP, errno.EPERM])
def test_link_no_replace_still_reports_a_refused_link(paths, monkeypatch, err):
    source, library, final = paths
    _refuse(monkeypatch, err)

    with pytest.raises(organizer.HardLinkError):
        organizer.link_no_replace(source, final, in_use=_never)

    assert _tree(library) == set()
    assert source.exists()


# ── review fixes (link-fallback review D-1 and nits) ────────────────────────

def test_in_copy_mode_the_hook_runs_only_once_the_temp_is_this_calls(paths, monkeypatch):
    """D-1: the record (written by the hook) proves the temp ours only when the
    temp was created first, with O_EXCL."""
    source, _library, final = paths
    _refuse(monkeypatch, errno.EXDEV)
    temp = organizer.temp_name_for(final)
    seen = []

    def hook(mode):
        seen.append((mode, os.path.lexists(temp)))

    assert organizer.place_no_replace(source, final, in_use=_never, before_fallback=hook) == "copied"

    assert seen == [("copy", True)]


def test_a_file_already_at_the_temp_name_never_reaches_the_hook(paths, monkeypatch):
    source, _library, final = paths
    temp = organizer.temp_name_for(final)
    temp.parent.mkdir(parents=True)
    temp.write_bytes(b"not this call's")
    _refuse(monkeypatch, errno.EXDEV)
    modes = []

    with pytest.raises(FileExistsError):
        organizer.place_no_replace(source, final, in_use=_never, before_fallback=modes.append)

    assert modes == []
    assert temp.read_bytes() == b"not this call's"


def test_a_taken_name_is_a_collision_even_on_a_nearly_full_disk(paths, monkeypatch):
    source, _library, final = paths
    final.parent.mkdir(parents=True)
    final.write_bytes(b"someone else's file")
    _refuse(monkeypatch, errno.EXDEV)
    monkeypatch.setattr(shutil, "disk_usage", lambda p: _Usage(10**9, 0, 0))

    assert organizer.place_no_replace(source, final, in_use=_never, copy_floor_bytes=1) is None

    assert final.read_bytes() == b"someone else's file"


def test_after_renaming_the_temp_its_name_is_not_ours_any_more(paths, monkeypatch):
    """A file another program puts at the temp name right after our rename is
    never removed (the temp is unlinked only after a link placement)."""
    source, _library, final = paths
    _refuse(monkeypatch, errno.EXDEV)
    temp = organizer.temp_name_for(final)

    def rename(src, dst, *args, **kwargs):
        _real_rename(src, dst, *args, **kwargs)
        if Path(src) == temp:
            temp.write_bytes(b"someone else's")

    monkeypatch.setattr(organizer.os, "rename", rename)

    assert organizer.place_no_replace(source, final, in_use=_never) == "copied"

    assert temp.read_bytes() == b"someone else's"
