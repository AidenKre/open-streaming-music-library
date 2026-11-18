"""Sign-off DEV-7-14 point 1: the reserved, bounded unpack of an import-folder
archive. The inspection rules are tested once (``test_upload_zip_inspect.py``,
``test_archive_inspect_formats.py``) and the byte counters once
(``test_upload_zip_stream.py``); here only what this module adds: only the
audio entries are written, into a fresh ``unpack-<hex>`` folder of the owner's
workspace; the worst case is reserved first (purpose ``import_unpack``) and
released on every exit; refusals are remembered by the file's identity and the
limits in effect; and the startup sweep removes only the server's own unpack
folders."""

import builtins
import errno
import logging
import os
import re
import zipfile
from pathlib import Path

import pytest

from app.services import import_archive
from app.services.import_archive import (
    REFUSAL_CODES, ArchiveNoSpace, ArchiveRefused, ArchiveStopped, ArchiveUnpacker, ArchiveWriteFailed,
    sweep_workspace,
)
from app.services.storage_ledger import IMPORT_UNPACK
from app.services.upload_zip import ArchivePlan, Member
from tests.archive_builders import rar4, rar5, write_rar, write_tar
from tests.identity_worker_fixtures import make_db, sql
from tests.owned_database import add_test_user
from tests.upload_zip_fixtures import Entry, build_zip, corrupt_member_data, make_ledger, tiny_limits

A, B = b"A" * 300, b"B" * 200
UNPACK = re.compile(r"^unpack-[0-9a-f]{32}$")


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def owner(db):
    return add_test_user(db, "sam")


def _unpacker(db, tmp_path, owner, *, free=10**12, limits=None, ledger="real"):
    lim = limits or tiny_limits()
    return ArchiveUnpacker(
        owner_id=owner,
        ledger=make_ledger(db, tmp_path, free=free) if ledger == "real" else ledger,
        limits=(lambda: lim) if not callable(lim) else lim,
        chunk_size=7,
    )


def _rows(db):
    return sql(db, "SELECT owner_id, purpose, bytes FROM storage_reservations")


def _album_zip(path, **extra):
    path.parent.mkdir(parents=True, exist_ok=True)
    entries = [Entry("Album/a.flac", A), Entry("Album/cover.jpg", b"jpeg"), Entry("Album/b.mp3", B)]
    return build_zip(path, entries + [Entry(n, d) for n, d in extra.items()])


def _never():
    return False


def _disk_cost(*sizes):
    """What the reservation must cover for these written files: each file's
    bytes rounded up to a 4 KiB block, plus one block for its inode and one
    for the folder it is unpacked into (round 2, review: every member gets
    its own folder, whatever its path in the archive)."""
    return sum(-(-n // 4096) * 4096 + 2 * 4096 for n in sizes)


# --- what is written ---------------------------------------------------------

def _zip(p):
    return _album_zip(p)


def _tar(p):
    return write_tar(p, [("Album/a.flac", A), ("Album/cover.jpg", b"jpeg"), ("Album/b.mp3", B)])


def _tgz(p):
    return write_tar(p, [("Album/a.flac", A), ("Album/cover.jpg", b"jpeg"), ("Album/b.mp3", B)],
                     mode="w:gz")


def _rar(build):
    return lambda p: write_rar(p, [("Album/a.flac", A), ("Album/cover.jpg", b"jpeg"), ("Album/b.mp3", B)],
                               build=build)


@pytest.mark.parametrize("name,make", [
    ("a.zip", _zip), ("a.tar", _tar), ("a.tar.gz", _tgz), ("a.rar", _rar(rar5)), ("b.rar", _rar(rar4)),
])
def test_only_the_audio_entries_are_written_into_a_fresh_unpack_folder(db, tmp_path, owner, name, make):
    archive = make(tmp_path / "import" / name)
    workspace = tmp_path / "workspace" / f"u{owner}"

    with _unpacker(db, tmp_path, owner).unpack(archive, workspace, should_stop=_never) as unpacked:
        assert unpacked.folder.parent == workspace and UNPACK.match(unpacked.folder.name)
        # Round 2 (review): each member in a folder of its own, named by its
        # position, whatever its path in the archive (no deep trees).
        assert unpacked.files == (unpacked.folder / "0" / "a.flac", unpacked.folder / "1" / "b.mp3")
        assert [f.read_bytes() for f in unpacked.files] == [A, B]
        assert sorted(str(p.relative_to(unpacked.folder)) for p in unpacked.folder.rglob("*")) \
            == ["0", "0/a.flac", "1", "1/b.mp3"]
        folder = unpacked.folder

    assert not folder.exists()
    assert list(workspace.iterdir()) == []


def test_two_unpacks_of_one_archive_use_different_folders(db, tmp_path, owner):
    archive = _album_zip(tmp_path / "a.zip")
    unpacker = _unpacker(db, tmp_path, owner)
    workspace = tmp_path / "ws"

    with unpacker.unpack(archive, workspace, should_stop=_never) as first:
        with unpacker.unpack(archive, workspace, should_stop=_never) as second:
            assert first.folder != second.folder
            assert first.files[0].read_bytes() == second.files[0].read_bytes() == A


# --- the reservation -----------------------------------------------------------

def test_the_worst_case_is_reserved_while_copying_and_released_once_on_disk(db, tmp_path, owner):
    """Round 2 (review): the reservation covers the copy only. Once the bytes
    are on disk the free space shows them, so holding it through the import
    would count them twice and refuse other users' work."""
    archive = _album_zip(tmp_path / "a.zip")
    during_copy = []

    def look():
        if not during_copy:
            during_copy.append(_rows(db))
        return False

    with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=look) as unpacked:
        # The audio entries' disk cost; the non-audio entry is never written.
        assert during_copy == [[{"owner_id": owner, "purpose": IMPORT_UNPACK,
                                 "bytes": _disk_cost(len(A), len(B))}]]
        assert _rows(db) == []
        folder = unpacked.folder

    assert not folder.exists()
    assert _rows(db) == []


def test_the_ledger_is_the_one_the_unpacker_was_given(db, tmp_path, owner):
    """The free space read is the workspace disk's: whatever ledger the
    pipeline built for it (here a fake disk one byte short)."""
    archive = _album_zip(tmp_path / "a.zip")

    with pytest.raises(ArchiveNoSpace) as ei:
        with _unpacker(db, tmp_path, owner, free=_disk_cost(len(A), len(B)) - 1).unpack(
                archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked without space")

    assert ei.value.code == "insufficient_storage"
    assert _rows(db) == []
    assert not (tmp_path / "ws").exists() or list((tmp_path / "ws").iterdir()) == []


def test_two_archives_whose_reservations_exceed_the_free_space_do_not_both_unpack(db, tmp_path, owner):
    first = _album_zip(tmp_path / "first.zip")
    second = _album_zip(tmp_path / "second.zip")
    unpacker = _unpacker(db, tmp_path, owner, free=_disk_cost(len(A), len(B)) * 2 - 1)
    during_copy = []

    def second_while_the_first_copies():
        if not during_copy:
            with pytest.raises(ArchiveNoSpace):
                with unpacker.unpack(second, tmp_path / "ws", should_stop=_never):
                    pytest.fail("both unpacked")
            during_copy.append(len(_rows(db)))
        return False

    with unpacker.unpack(first, tmp_path / "ws", should_stop=second_while_the_first_copies):
        assert during_copy == [1]

    # Not remembered: once the first is done, the second unpacks.
    with unpacker.unpack(second, tmp_path / "ws", should_stop=_never) as unpacked:
        assert [f.read_bytes() for f in unpacked.files] == [A, B]
    assert _rows(db) == []


class Boom(Exception):
    pass


def test_the_reservation_is_released_when_the_body_raises(db, tmp_path, owner):
    archive = _album_zip(tmp_path / "a.zip")

    with pytest.raises(Boom):
        with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
            folder = unpacked.folder
            raise Boom

    assert not folder.exists()
    assert _rows(db) == []


def test_a_stop_request_while_copying_stops_and_releases(db, tmp_path, owner):
    archive = _album_zip(tmp_path / "a.zip")
    calls = []

    def stop_after_a_few():
        calls.append(1)
        return len(calls) > 3

    with pytest.raises(ArchiveStopped):
        with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=stop_after_a_few):
            pytest.fail("unpacked despite the stop")

    assert _rows(db) == []
    assert list((tmp_path / "ws").iterdir()) == []


def test_a_copy_never_writes_more_than_was_reserved(db, tmp_path, owner, monkeypatch):
    """An entry whose real size exceeds its declared size is stopped at its
    declared size (round 2: each member's cap is its own declared size, so a
    copy can never pass the reservation); the archive is refused as corrupt."""
    archive = build_zip(tmp_path / "a.zip", [Entry("a.flac", A)])
    monkeypatch.setattr(import_archive, "inspect",
                        lambda path, limits, **kw: ArchivePlan((Member(0, "a.flac", 10, len(A)),), 0))
    with pytest.raises(ArchiveRefused) as ei:
        with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked beyond the reservation")

    assert ei.value.code == "corrupt"
    assert _rows(db) == []
    assert list((tmp_path / "ws").iterdir()) == []


# --- refusals ------------------------------------------------------------------

def test_an_inspection_refusal_creates_nothing_and_reserves_nothing(db, tmp_path, owner):
    archive = tmp_path / "a.zip"
    archive.write_bytes(b"not a zip")

    with pytest.raises(ArchiveRefused) as ei:
        with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked a refused archive")

    assert ei.value.code == "invalid" and ei.value.code in REFUSAL_CODES
    assert not ei.value.remembered
    assert _rows(db) == []
    assert not (tmp_path / "ws").exists() or list((tmp_path / "ws").iterdir()) == []


def test_a_copy_time_refusal_removes_the_folder_and_releases(db, tmp_path, owner):
    archive = build_zip(tmp_path / "a.zip", [Entry("a.flac", A), Entry("b.flac", B)])
    corrupt_member_data(archive, "b.flac")

    with pytest.raises(ArchiveRefused) as ei:
        with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked a corrupt archive")

    assert ei.value.code == "corrupt"
    assert _rows(db) == []
    assert list((tmp_path / "ws").iterdir()) == []


def test_two_entries_whose_archive_paths_clash_are_both_written(db, tmp_path, owner):
    """Round 2 (review): each member has its own folder, so ``a.flac`` and
    ``a.flac/b.mp3`` no longer clash (they were refused as invalid)."""
    archive = build_zip(tmp_path / "a.zip", [Entry("a.flac", A), Entry("a.flac/b.mp3", B)])

    with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
        assert [(f.name, f.read_bytes()) for f in unpacked.files] == [("a.flac", A), ("b.mp3", B)]


def test_the_refusal_codes_are_the_thirteen_upload_codes():
    assert REFUSAL_CODES == frozenset({
        "invalid", "corrupt", "unsafe_path", "unsafe_member", "encrypted", "unsupported_compression",
        "duplicate_names", "nested", "too_many_members", "too_many_audio", "member_too_large",
        "expanded_too_large", "ratio_exceeded",
    })


# --- the refusal memory ---------------------------------------------------------

def _spy_inspect(monkeypatch):
    calls = []
    real = import_archive.inspect
    # The unpack may hand the inspection its open file rather than the path.
    monkeypatch.setattr(import_archive, "inspect",
                        lambda path, limits, **kw: calls.append(Path(path if isinstance(path, os.PathLike) else path.name))
                        or real(path, limits, **kw))
    return calls


def _refused(unpacker, archive, tmp_path):
    with pytest.raises(ArchiveRefused) as ei:
        with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked")
    return ei.value


def test_a_refused_archive_is_not_inspected_again_while_it_is_unchanged(db, tmp_path, owner, monkeypatch):
    archive = build_zip(tmp_path / "a.zip", [Entry(f"{i}.flac", b"x") for i in range(5)])  # 5 > 4 audio
    calls = _spy_inspect(monkeypatch)
    unpacker = _unpacker(db, tmp_path, owner)

    first = _refused(unpacker, archive, tmp_path)
    second = _refused(unpacker, archive, tmp_path)

    assert (first.code, first.remembered) == ("too_many_audio", False)
    assert (second.code, second.remembered) == ("too_many_audio", True)
    assert calls == [archive]


def test_a_changed_archive_is_inspected_again(db, tmp_path, owner, monkeypatch):
    archive = build_zip(tmp_path / "a.zip", [Entry(f"{i}.flac", b"x") for i in range(5)])
    calls = _spy_inspect(monkeypatch)
    unpacker = _unpacker(db, tmp_path, owner)
    _refused(unpacker, archive, tmp_path)

    build_zip(tmp_path / "a.zip", [Entry("0.flac", b"x")])
    with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
        assert len(unpacked.files) == 1

    assert calls == [archive, archive]


def test_a_raised_limit_applies_to_the_next_attempt(db, tmp_path, owner, monkeypatch):
    """The limits are read for each archive; the memory is keyed by them too,
    so raising a setting admits an archive refused before."""
    archive = build_zip(tmp_path / "a.zip", [Entry(f"{i}.flac", b"x") for i in range(5)])
    current = {"limits": tiny_limits()}
    unpacker = _unpacker(db, tmp_path, owner, limits=lambda: current["limits"])
    assert _refused(unpacker, archive, tmp_path).code == "too_many_audio"

    current["limits"] = tiny_limits(max_audio_items_per_batch=5)
    with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
        assert len(unpacked.files) == 5


def test_no_space_is_not_remembered(db, tmp_path, owner, monkeypatch):
    archive = _album_zip(tmp_path / "a.zip")
    calls = _spy_inspect(monkeypatch)
    unpacker = _unpacker(db, tmp_path, owner, free=10)
    for _ in range(2):
        with pytest.raises(ArchiveNoSpace):
            with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never):
                pass

    assert calls == [archive, archive]


# --- the startup sweep ---------------------------------------------------------

def test_the_sweep_removes_only_the_servers_own_unpack_folders(tmp_path, caplog):
    root = tmp_path / "data" / "workspace"
    outside = tmp_path / "outside"
    (outside / ("unpack-" + "c" * 32)).mkdir(parents=True)
    (outside / ("unpack-" + "c" * 32) / "keep.flac").write_bytes(b"keep")
    ours = root / "u1" / ("unpack-" + "a" * 32)
    (ours / "Album").mkdir(parents=True)
    (ours / "Album" / "a.flac").write_bytes(b"x")
    (root / "u1" / "foreign.txt").write_text("not ours")
    (root / "u1" / "old-album").mkdir()
    (root / "u2").mkdir()
    os.symlink(outside / ("unpack-" + "c" * 32), root / "u2" / ("unpack-" + "b" * 32))
    os.symlink(outside, root / "u3")
    (root / "stray.zip").write_bytes(b"x")

    with caplog.at_level(logging.INFO):
        sweep_workspace(root)

    assert not ours.exists()
    assert (root / "u1" / "foreign.txt").exists() and (root / "u1" / "old-album").is_dir()
    assert (root / "u2" / ("unpack-" + "b" * 32)).is_symlink()
    assert (root / "u3").is_symlink() and (root / "stray.zip").exists()
    assert (outside / ("unpack-" + "c" * 32) / "keep.flac").read_bytes() == b"keep"
    lines = [r.getMessage() for r in caplog.records if r.name == "uvicorn.error"]
    assert len(lines) == 1, lines
    assert "5" in lines[0]  # foreign.txt, old-album, the two symlinks, stray.zip
    assert str(tmp_path) not in lines[0] and "foreign" not in lines[0] and "stray" not in lines[0]


def test_the_sweep_of_a_clean_or_missing_workspace_says_nothing(tmp_path, caplog):
    (tmp_path / "workspace" / "u1").mkdir(parents=True)
    with caplog.at_level(logging.INFO):
        sweep_workspace(tmp_path / "workspace")
        sweep_workspace(tmp_path / "missing")

    assert [r for r in caplog.records if r.name == "uvicorn.error"] == []
    assert (tmp_path / "workspace" / "u1").is_dir()


# --- review r1 (s7-import-archives-review.md) -------------------------------------

def test_r1_5_a_name_the_disk_cannot_hold_is_a_remembered_refusal(db, tmp_path, owner, monkeypatch):
    archive = build_zip(tmp_path / "a.zip", [Entry("a" * 300 + ".mp3", A)])
    calls = _spy_inspect(monkeypatch)
    unpacker = _unpacker(db, tmp_path, owner)

    first = _refused(unpacker, archive, tmp_path)
    second = _refused(unpacker, archive, tmp_path)

    assert (first.code, second.code, second.remembered) == ("invalid", "invalid", True)
    assert calls == [archive]
    assert _rows(db) == []


@pytest.mark.parametrize("name,make", [("a.zip", _zip), ("a.tar", _tar), ("a.tar.gz", _tgz)])
def test_r1_7_the_copy_reads_the_file_that_was_inspected(db, tmp_path, owner, monkeypatch, name, make):
    """The archive is opened once: a file swapped in at the path between the
    inspection and the copy is never read (the ingestor then sees the change)."""
    archive = make(tmp_path / "import" / name)
    real = import_archive.inspect

    def inspect_then_swap(source, limits, **kw):
        plan = real(source, limits, **kw)
        swapped = archive.with_name("swap" + name)
        build_zip(swapped, [Entry("z.mp3", b"Z" * 50)])
        os.replace(swapped, archive)
        return plan

    monkeypatch.setattr(import_archive, "inspect", inspect_then_swap)

    with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
        assert [f.read_bytes() for f in unpacked.files] == [A, B]


def test_r1_8_a_planned_entry_the_copy_never_reaches_is_a_refusal(db, tmp_path, owner, monkeypatch):
    archive = _tar(tmp_path / "a.tar")
    real = import_archive.inspect
    monkeypatch.setattr(import_archive, "inspect", lambda path, limits, **kw: ArchivePlan(
        real(path, limits, **kw).members + (Member(99, "ghost.mp3", 10, 10),), 0))

    with pytest.raises(ArchiveRefused) as ei:
        with _unpacker(db, tmp_path, owner).unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("a planned entry was never written")

    assert ei.value.code == "corrupt"
    assert _rows(db) == []


def test_r1_10_a_failed_release_does_not_replace_the_outcome(db, tmp_path, owner, caplog):
    archive = _album_zip(tmp_path / "a.zip")
    unpacker = _unpacker(db, tmp_path, owner)

    def release(reservation_id):
        raise RuntimeError("database is locked")

    unpacker._ledger.release = release
    with caplog.at_level(logging.INFO):
        with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
            files = unpacked.files

    assert len(files) == 2
    assert any("RuntimeError" in r.getMessage() for r in caplog.records if r.name == "uvicorn.error")


# --- U11-B-03: a read error that can pass is not a remembered refusal ------------

def _fails_once(monkeypatch, owner_obj, name, err):
    real = getattr(owner_obj, name, None) or getattr(builtins, name)
    failed = []

    def wrapper(*args, **kwargs):
        if not failed:
            failed.append(True)
            raise OSError(err, os.strerror(err))
        return real(*args, **kwargs)

    monkeypatch.setattr(owner_obj, name, wrapper, raising=False)
    return failed


@pytest.mark.parametrize("kind", ["zip", "tar"])
def test_a_passing_read_error_while_inspecting_is_tried_again(db, tmp_path, owner, monkeypatch, kind):
    if kind == "zip":
        archive = _album_zip(tmp_path / "a.zip")
        failed = _fails_once(monkeypatch, zipfile, "_EndRecData", errno.EIO)
    else:
        archive = _tar(tmp_path / "a.tar")
        failed = _fails_once(monkeypatch, import_archive, "_list", errno.EIO)
    unpacker = _unpacker(db, tmp_path, owner)

    with pytest.raises(ArchiveWriteFailed):
        with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked")

    assert failed
    assert not unpacker.remembered(archive)
    assert _rows(db) == []
    with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
        assert len(unpacked.files) == 2


@pytest.mark.parametrize("err", [errno.EMFILE, errno.EIO])
def test_a_passing_error_opening_the_archive_is_tried_again(db, tmp_path, owner, monkeypatch, err):
    archive = _album_zip(tmp_path / "a.zip")
    failed = _fails_once(monkeypatch, import_archive, "open", err)
    unpacker = _unpacker(db, tmp_path, owner)

    with pytest.raises(ArchiveWriteFailed):
        with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked")

    assert failed
    assert not unpacker.remembered(archive)
    with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
        assert len(unpacked.files) == 2


def test_a_passing_read_error_reported_by_libarchive_is_tried_again(db, tmp_path, owner, monkeypatch):
    """libarchive reports a failed read as ArchiveError carrying the errno (a RAR,
    or a tar it lists): environmental, like the same OSError."""
    from libarchive.exception import ArchiveError

    archive = _tar(tmp_path / "a.tar")
    real = import_archive._list
    failed = []

    def fails_once(*args, **kwargs):
        if not failed:
            failed.append(True)
            raise ArchiveError("read failed", errno=errno.EIO)
        return real(*args, **kwargs)

    monkeypatch.setattr(import_archive, "_list", fails_once)
    unpacker = _unpacker(db, tmp_path, owner)

    with pytest.raises(ArchiveWriteFailed):
        with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never):
            pytest.fail("unpacked")

    assert failed
    assert not unpacker.remembered(archive)
    with unpacker.unpack(archive, tmp_path / "ws", should_stop=_never) as unpacked:
        assert len(unpacked.files) == 2
