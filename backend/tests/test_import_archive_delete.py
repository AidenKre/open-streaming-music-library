"""Sign-off DEV-M-10 (changed 2026-11-17): an import-folder archive whose every
audio file was imported is deleted. The owner's rule: "only after every song
in the zip is successfully imported (so if one track fails, then the zip
stays, if EVERYTHING passes, then the zip is safe to delete)". Non-audio
entries (covers, text, macOS helper files) are ignored. A track refused for
its own content sends the archive to ``.imported/`` as before; an outside
failure keeps it in place for a retry. Every guard of the deletion has a test
here that fails when the guard is removed."""

import errno
import logging
import os
import zipfile
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from app.services import file_watcher, ingestion
from app.services.file_watcher import FileWatcher
from app.services.import_archive import ArchiveUnpacker
from app.services.import_outcome import ImportOutcome, file_identity
from app.services.ingestion import Ingestor, IngestorContext
from tests.archive_builders import write_tar
from tests.upload_zip_fixtures import tiny_limits

OPERATOR = "uvicorn.error"
OWNER = 7
DELETED = f"An archive in an import folder of user {OWNER} was imported in full (2 audio files) and deleted."


@pytest.fixture(autouse=True)
def quick_check_passes(monkeypatch):
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)


def _ingestor(tmp_path, organize=None):
    return Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace" / f"u{OWNER}",
        organize_function=organize or MagicMock(return_value=ImportOutcome.IMPORTED),
        archives=ArchiveUnpacker(owner_id=OWNER, ledger=None, limits=lambda: tiny_limits())))


def _by_name(outcomes):
    return MagicMock(side_effect=lambda p: outcomes.get(Path(p).name, ImportOutcome.IMPORTED))


def _folder(tmp_path):
    folder = tmp_path / "import-users" / "sam"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def _zip(path, members):
    with zipfile.ZipFile(path, "w") as z:
        for name, data in members.items():
            z.writestr(name, data)
    return path


ALBUM = {
    "Album/a.mp3": b"a" * 50, "Album/b.flac": b"b" * 50, "Album/cover.jpg": b"jpeg",
    "Album/notes.txt": b"notes", "__MACOSX/Album/._a.mp3": b"mac", "Album/._b.flac": b"mac",
}


def _album_zip(folder, name="album.zip"):
    return _zip(folder / name, ALBUM)


def _album_tar(folder):
    return write_tar(folder / "album.tar", list(ALBUM.items()))


def _lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


def _ingest(tmp_path, archive, caplog, organize=None):
    with caplog.at_level(logging.INFO):
        return _ingestor(tmp_path, organize).ingest(archive, imported_dir=archive.parent / ".imported")


# --- the rule ---------------------------------------------------------------------

@pytest.mark.parametrize("make", [_album_zip, _album_tar], ids=["zip", "tar"])
def test_an_archive_whose_every_audio_file_was_imported_is_deleted(tmp_path, caplog, make):
    folder = _folder(tmp_path)
    archive = make(folder)
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)

    outcome = _ingest(tmp_path, archive, caplog, organize)

    assert outcome is ImportOutcome.IMPORTED
    assert sorted(Path(c.args[0]).name for c in organize.call_args_list) == ["a.mp3", "b.flac"]
    assert not archive.exists()
    assert not (folder / ".imported").exists()
    assert list(folder.iterdir()) == []
    assert _lines(caplog) == [DELETED]
    assert list((tmp_path / "workspace" / f"u{OWNER}").iterdir()) == []


@pytest.mark.parametrize("refusal", [ImportOutcome.DUPLICATE, ImportOutcome.FAILS_CHECK, ImportOutcome.NOT_AUDIO])
def test_g1_a_track_refused_for_its_own_content_sends_the_archive_to_imported(tmp_path, caplog, refusal):
    """Also the accepted crash case: a retry after a crash before the delete
    finds the tracks already in the library (``duplicate``)."""
    folder = _folder(tmp_path)
    archive = _album_zip(folder)
    before = archive.read_bytes()

    assert _ingest(tmp_path, archive, caplog, _by_name({"b.flac": refusal})) is ImportOutcome.IMPORTED

    assert not archive.exists()
    assert (folder / ".imported" / "album.zip").read_bytes() == before
    assert DELETED not in _lines(caplog)


def test_g2_an_archive_without_audio_is_set_aside_not_deleted(tmp_path, caplog):
    folder = _folder(tmp_path)
    archive = _zip(folder / "readme.zip", {"readme.txt": b"no songs", "cover.jpg": b"jpeg"})

    assert _ingest(tmp_path, archive, caplog) is ImportOutcome.IMPORTED

    assert [p.name for p in (folder / ".imported").iterdir()] == ["readme.zip"]
    assert _lines(caplog) == []


def test_an_outside_failure_keeps_the_archive_in_place(tmp_path, caplog):
    folder = _folder(tmp_path)
    archive = _album_zip(folder)

    outcome = _ingest(tmp_path, archive, caplog, _by_name({"b.flac": ImportOutcome.DATABASE_ERROR}))

    assert outcome is ImportOutcome.DATABASE_ERROR
    assert archive.exists() and not (folder / ".imported").exists()


def test_g3_an_archive_replaced_during_the_import_is_not_deleted(tmp_path, caplog):
    """The replacement has the same size and modification time (so the
    signature check cannot see it) but is another file."""
    folder = _folder(tmp_path)
    archive = _album_zip(folder)
    st = os.stat(archive)
    replacement = b"R" * st.st_size

    def organize(path):
        if Path(path).name == "b.flac":
            spare = folder / "spare"
            spare.write_bytes(replacement)
            os.utime(spare, ns=(st.st_atime_ns, st.st_mtime_ns))
            os.replace(spare, archive)
        return ImportOutcome.IMPORTED

    outcome = _ingest(tmp_path, archive, caplog, MagicMock(side_effect=organize))

    assert outcome is ImportOutcome.CHANGED
    assert archive.read_bytes() == replacement
    assert not (folder / ".imported").exists()
    assert DELETED not in _lines(caplog)


def test_g3_the_identity_is_checked_again_right_before_the_unlink(tmp_path, caplog, monkeypatch):
    folder = _folder(tmp_path)
    archive = _album_zip(folder)
    events = []
    real_identity, real_unlink = ingestion.file_identity, os.unlink

    def unlink(path, *args, **kwargs):  # os.unlink is global: rmtree uses it too
        if os.path.basename(os.fspath(path)) == archive.name:
            events.append(("unlink", archive.name))
        return real_unlink(path, *args, **kwargs)

    # By name: the removal names the file relative to its opened folder. The
    # check before the unpack is made by path, the one before the unlink
    # inside the opened folder, which tells the two apart.
    monkeypatch.setattr(ingestion, "file_identity",
                        lambda p, **kw: events.append(("identity", Path(p).name, "dir_fd" in kw))
                        or real_identity(p, **kw))
    monkeypatch.setattr(ingestion.os, "unlink", unlink)

    assert _ingest(tmp_path, archive, caplog) is ImportOutcome.IMPORTED

    assert events[-2:] == [("identity", archive.name, True), ("unlink", archive.name)]
    assert [e for e in events if e[0] == "unlink"] == [("unlink", archive.name)]


def test_g5_a_planned_audio_file_missing_from_the_unpack_keeps_the_archive(tmp_path, caplog):
    folder = _folder(tmp_path)
    archive = _album_zip(folder)

    def organize(path):
        # The other unpacked files (each member has a folder of its own).
        for sibling in Path(path).parent.parent.rglob("*"):
            if sibling.is_file() and sibling != Path(path):
                sibling.unlink()
        return ImportOutcome.IMPORTED

    outcome = _ingest(tmp_path, archive, caplog, MagicMock(side_effect=organize))

    assert outcome is ImportOutcome.CHANGED
    assert archive.exists() and not (folder / ".imported").exists()


def test_a_symlinked_archive_is_never_deleted(tmp_path, caplog):
    """Since the pre-merge review (A4-01) a link is not read through either: it
    is not unpacked and not set aside, it stays where it is."""
    folder = _folder(tmp_path)
    target = _album_zip(tmp_path, "elsewhere.zip")
    before = target.read_bytes()
    link = folder / "album.zip"
    link.symlink_to(target)
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)

    assert _ingest(tmp_path, link, caplog, organize) is ImportOutcome.NOT_AUDIO

    organize.assert_not_called()
    assert target.read_bytes() == before
    assert link.is_symlink() and not (folder / ".imported").exists()
    assert DELETED not in _lines(caplog)


def test_exactly_the_archive_is_removed(tmp_path, caplog):
    folder = _folder(tmp_path)
    (folder / ".imported").mkdir()
    keep = {
        folder / ".imported" / "album.zip": b"an older album",
        folder / ".imported" / "other.zip": b"another",
        folder / "other.zip": b"not this one",
        folder / "album.zip.part": b"a partial copy",
    }
    for path, data in keep.items():
        path.write_bytes(data)
    archive = _album_zip(folder)

    assert _ingest(tmp_path, archive, caplog) is ImportOutcome.IMPORTED

    assert not archive.exists()
    assert {p: p.read_bytes() for p in keep} == keep
    assert sorted(p.name for p in folder.iterdir()) == [".imported", "album.zip.part", "other.zip"]


# --- a deletion that fails ----------------------------------------------------------

def _refuse_unlink(monkeypatch, archive):
    real_unlink = os.unlink

    def refuse(path, *args, **kwargs):  # os.unlink is global: rmtree uses it too
        if os.path.basename(os.fspath(path)) == archive.name:  # by name: maybe relative to its folder
            raise PermissionError(errno.EACCES, "Permission denied", str(path))
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(ingestion.os, "unlink", refuse)


def test_a_failed_deletion_leaves_the_archive_with_one_line(tmp_path, caplog, monkeypatch):
    folder = _folder(tmp_path)
    archive = _album_zip(folder)
    before = archive.read_bytes()
    _refuse_unlink(monkeypatch, archive)

    assert _ingest(tmp_path, archive, caplog) is ImportOutcome.IMPORTED

    assert archive.read_bytes() == before
    assert not (folder / ".imported").exists()
    assert _lines(caplog) == [
        f"An archive in an import folder of user {OWNER} was imported in full but could not be"
        " deleted (EACCES); it stays in the folder."
    ]
    assert str(tmp_path) not in _lines(caplog)[0]


def test_a_failed_deletion_is_not_retried_in_the_same_run(tmp_path, caplog, monkeypatch):
    folder = _folder(tmp_path)
    archive = _album_zip(folder)
    _refuse_unlink(monkeypatch, archive)
    monkeypatch.setattr(file_watcher, "wait_until_ready", lambda path, stop=None: True)
    ingestor = _ingestor(tmp_path)
    calls = []
    watcher = FileWatcher(folder, on_file=lambda p: calls.append(p) or ingestor.ingest_file(
        p, imported_dir=folder / ".imported"))
    try:
        assert watcher.process_file_after_stable(archive) is True
        watcher._queue = MagicMock()
        watcher._on_event(archive)  # a modify event for the unchanged archive

        assert calls == [archive]
        watcher._queue.assert_not_called()
        assert file_identity(archive) is not None
    finally:
        watcher.executor.shutdown(wait=True)



def test_a_folder_swapped_between_the_check_and_the_removal_never_costs_another_archive(
        tmp_path, caplog, monkeypatch):
    """After the last identity check and before the removal, the archive's
    folder is swapped for a link to another user's folder, which holds an
    archive of the same name. The removal goes to the folder that was checked
    (wherever it is now), never through the name: the other archive stays."""
    folder = _folder(tmp_path)
    albums = folder / "albums"
    albums.mkdir()
    archive = _album_zip(albums)
    alices = tmp_path / "import-users" / "alice"
    alices.mkdir(parents=True)
    theirs = _album_zip(alices)
    theirs_bytes = theirs.read_bytes()
    real_unlink = os.unlink
    swapped = []

    def swap_then_unlink(path, *args, **kwargs):  # os.unlink is global: rmtree uses it too
        if not swapped and os.path.basename(os.fspath(path)) == archive.name:
            swapped.append(path)
            os.rename(albums, folder / "albums-moved-away")
            os.symlink(alices, albums, target_is_directory=True)
        return real_unlink(path, *args, **kwargs)

    monkeypatch.setattr(ingestion.os, "unlink", swap_then_unlink)

    with caplog.at_level(logging.INFO):
        outcome = _ingestor(tmp_path).ingest(archive, imported_dir=folder / ".imported")

    assert swapped, "the archive was never removed"
    assert theirs.read_bytes() == theirs_bytes
    assert not (folder / "albums-moved-away" / archive.name).exists()
    assert outcome is ImportOutcome.IMPORTED and _lines(caplog) == [DELETED]


def _alices_archive(tmp_path):
    """Another user's folder with an archive of the same name, other bytes."""
    alices = tmp_path / "import-users" / "alice"
    alices.mkdir(parents=True)
    return alices, _zip(alices / "album.zip", {"x.txt": b"alice's"})


def test_a_folder_swapped_right_before_the_set_aside_never_moves_another_archive(
        tmp_path, caplog, monkeypatch):
    """The archive is set aside (one track is already in the library). Its
    folder is swapped for a link to another user's folder, holding an archive
    of the same name, at the very move. The move takes the file from the
    folder that was checked, never through the name."""
    folder = _folder(tmp_path)
    albums = folder / "albums"
    albums.mkdir()
    archive = _album_zip(albums)
    ours = archive.read_bytes()
    alices, theirs = _alices_archive(tmp_path)
    theirs_bytes = theirs.read_bytes()
    real_rename = os.rename
    swapped = []

    def swap_then_rename(src, dst, *args, **kwargs):
        if not swapped and os.path.basename(os.fspath(src)) == archive.name:
            swapped.append(src)
            real_rename(albums, folder / "albums-moved-away")
            os.symlink(alices, albums, target_is_directory=True)
        return real_rename(src, dst, *args, **kwargs)

    monkeypatch.setattr(ingestion.os, "rename", swap_then_rename)

    outcome = _ingestor(tmp_path, _by_name({"b.flac": ImportOutcome.DUPLICATE})).ingest(
        archive, imported_dir=folder / ".imported")

    assert swapped, "the archive was never moved"
    assert theirs.read_bytes() == theirs_bytes
    assert (folder / ".imported" / "album.zip").read_bytes() == ours
    assert outcome is ImportOutcome.IMPORTED


def test_a_folder_swapped_before_the_set_aside_opens_it_is_a_changed_file(tmp_path, caplog, monkeypatch):
    """The swap comes after the last look by name and before the move opens
    the archive's folder: the folder it opens is the other user's, the file of
    that name there is not the one that was imported, and nothing is moved."""
    folder = _folder(tmp_path)
    albums = folder / "albums"
    albums.mkdir()
    archive = _album_zip(albums)
    alices, theirs = _alices_archive(tmp_path)
    theirs_bytes = theirs.read_bytes()
    real_open = os.open
    swapped = []

    def swap_then_open(path, flags, *args, **kwargs):
        if not swapped and Path(os.fspath(path)) == albums:
            swapped.append(path)
            os.rename(albums, folder / "albums-moved-away")
            os.symlink(alices, albums, target_is_directory=True)
        return real_open(path, flags, *args, **kwargs)

    monkeypatch.setattr(ingestion.os, "open", swap_then_open)

    with caplog.at_level(logging.INFO):
        outcome = _ingestor(tmp_path, _by_name({"b.flac": ImportOutcome.DUPLICATE})).ingest(
            archive, imported_dir=folder / ".imported")

    assert swapped, "the archive's folder was never opened"
    assert outcome is ImportOutcome.CHANGED
    assert theirs.read_bytes() == theirs_bytes
    assert (folder / "albums-moved-away" / "album.zip").exists()
    assert not (folder / ".imported").exists() or list((folder / ".imported").iterdir()) == []
    assert _lines(caplog) == []


def test_an_archive_gone_at_its_set_aside_is_a_changed_file_not_a_kept_one(tmp_path, caplog, monkeypatch):
    """Removed by someone between the last look and the move: nothing is kept,
    so no line says it stays, and nothing is remembered."""
    folder = _folder(tmp_path)
    archive = _album_zip(folder)
    real_rename = os.rename

    def removed_then_rename(src, dst, *args, **kwargs):
        if os.path.basename(os.fspath(src)) == archive.name and archive.exists():
            archive.unlink()
        return real_rename(src, dst, *args, **kwargs)

    monkeypatch.setattr(ingestion.os, "rename", removed_then_rename)
    ingestor = _ingestor(tmp_path, _by_name({"b.flac": ImportOutcome.DUPLICATE}))

    with caplog.at_level(logging.INFO):
        outcome = ingestor.ingest(archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.CHANGED
    assert _lines(caplog) == []
    assert not ingestor._archives.remembered(archive)


# --- a set-aside that fails ---------------------------------------------------------

def _kept_line(reason):
    return (f"An archive in an import folder of user {OWNER} could not be set aside in .imported"
            f" ({reason}); it stays in the folder and is tried again when it changes or when the"
            " server restarts.")


def _set_aside_twice(tmp_path, caplog):
    """An archive the server sets aside (one track is already in the library),
    offered twice; how often its members were handed to the organizer."""
    folder = _folder(tmp_path)
    archive = _album_zip(folder)
    organize = _by_name({"b.flac": ImportOutcome.DUPLICATE})
    ingestor = _ingestor(tmp_path, organize)
    with caplog.at_level(logging.INFO):
        first = ingestor.ingest(archive, imported_dir=folder / ".imported")
        again = ingestor.ingest(archive, imported_dir=folder / ".imported")
    return folder, archive, ingestor, organize, (first, again)


@pytest.mark.parametrize("err", [errno.EACCES, errno.EROFS, errno.ENOSPC, errno.EXDEV],
                         ids=["EACCES", "EROFS", "ENOSPC", "EXDEV"])
def test_a_refused_set_aside_keeps_the_archive_with_one_line_and_is_not_unpacked_again(
        tmp_path, caplog, monkeypatch, err):
    def refuse(src, dst, **kwargs):
        raise OSError(err, os.strerror(err))

    monkeypatch.setattr(ingestion.os, "rename", refuse)

    folder, archive, _, organize, outcomes = _set_aside_twice(tmp_path, caplog)

    assert outcomes == (ImportOutcome.MOVE_FAILED, ImportOutcome.REFUSED)
    assert organize.call_count == 2  # the two audio files of one unpack, not of a second
    assert archive.exists() and list((folder / ".imported").iterdir()) == []
    assert _lines(caplog) == [_kept_line(errno.errorcode[err])]
    assert str(tmp_path) not in _lines(caplog)[0]


def test_an_imported_folder_that_cannot_be_made_keeps_the_archive_the_same_way(
        tmp_path, caplog, monkeypatch):
    real_mkdir = Path.mkdir

    def no_permission(self, *args, **kwargs):
        if self.name == ".imported":
            raise PermissionError(errno.EACCES, "Permission denied", str(self))
        return real_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", no_permission)

    folder, archive, _, organize, outcomes = _set_aside_twice(tmp_path, caplog)

    assert outcomes == (ImportOutcome.MOVE_FAILED, ImportOutcome.REFUSED)
    assert organize.call_count == 2
    assert archive.exists() and not (folder / ".imported").exists()
    assert _lines(caplog) == [_kept_line("EACCES")]


def test_an_archive_kept_after_a_refused_set_aside_is_tried_again_once_it_changes(
        tmp_path, caplog, monkeypatch):
    def refuse(src, dst, **kwargs):
        raise OSError(errno.EACCES, os.strerror(errno.EACCES))

    monkeypatch.setattr(ingestion.os, "rename", refuse)
    folder, archive, ingestor, organize, _ = _set_aside_twice(tmp_path, caplog)
    st = archive.stat()
    os.utime(archive, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))

    assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.MOVE_FAILED
    assert organize.call_count == 4


# --- review r1 #2: songs in formats the server does not import ------------------------

@pytest.mark.parametrize("other", ["bonus.ogg", "Bonus/live.OPUS", "x.aiff", "y.wma", "z.aac", "w.alac"])
def test_r1_2_an_archive_with_audio_the_server_cannot_import_is_set_aside_not_deleted(
        tmp_path, caplog, other):
    """"Every song" includes songs in formats the server does not import:
    deleting the archive would lose them, so it is set aside instead."""
    folder = _folder(tmp_path)
    archive = _zip(folder / "album.zip", {"a.mp3": b"a" * 50, "b.flac": b"b" * 50, other: b"o" * 50})

    assert _ingest(tmp_path, archive, caplog) is ImportOutcome.IMPORTED

    assert not archive.exists()
    assert [p.name for p in (folder / ".imported").iterdir()] == ["album.zip"]
    assert DELETED not in _lines(caplog)


def test_r1_2_a_macos_helper_named_like_audio_does_not_count(tmp_path, caplog):
    folder = _folder(tmp_path)
    archive = _zip(folder / "album.zip", {"a.mp3": b"a" * 50, "b.flac": b"b" * 50,
                                          "._bonus.ogg": b"mac", "__MACOSX/._x.ogg": b"mac"})

    assert _ingest(tmp_path, archive, caplog) is ImportOutcome.IMPORTED

    assert not archive.exists() and not (folder / ".imported").exists()
    assert _lines(caplog) == [DELETED]


def test_an_archive_whose_member_clashes_with_a_different_track_is_deleted_after_a_full_import(
        tmp_path, caplog, monkeypatch):
    """Bug row U05-B-01: a member landing on a library name a different track
    already uses is imported under a numbered name (IMPORTED), so the archive is
    deleted under the DEV-M-10 rule instead of being set aside."""
    from unittest.mock import patch

    from tests.name_clash_rig import META, Rig

    rig = Rig(tmp_path, monkeypatch)
    rig.seed_track("b.flac", b"library|t")
    folder = _folder(tmp_path)
    archive = _zip(folder / "album.zip", {"Album/a.flac": b"a|t", "Album/b.flac": b"member b|t"})

    with (
        patch("app.services.organizer.get_track_metadata", return_value=META),
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
        caplog.at_level(logging.INFO),
    ):
        outcome = rig.ingestor.ingest(archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.IMPORTED
    assert not archive.exists()
    assert not (folder / ".imported").exists()
    assert rig.names() == ["a.flac", "b (2).flac", "b.flac"]
    assert (rig.folder / "b.flac").read_bytes() == b"library|t"


def test_an_archive_whose_member_meets_a_library_file_that_cannot_be_read_now_stays(
        tmp_path, caplog, monkeypatch):
    """Owner's decision 2026-11-17 (U05-B-01 review #4) with DEV-M-10 ("an
    outside failure -> stays"): the member's import is environmental, so the
    archive stays where it is, neither set aside nor deleted, for a later try."""
    from unittest.mock import patch

    from tests.name_clash_rig import META, Rig

    rig = Rig(tmp_path, monkeypatch)
    rig.folder.mkdir(parents=True)
    existing = rig.folder / "b.flac"
    existing.write_bytes(b"library|untracked")
    rig.failures[existing] = "tool_missing"
    folder = _folder(tmp_path)
    archive = _zip(folder / "album.zip", {"Album/a.flac": b"a|t", "Album/b.flac": b"member b|t"})
    before = archive.read_bytes()

    with (
        patch("app.services.organizer.get_track_metadata", return_value=META),
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
        caplog.at_level(logging.INFO),
    ):
        outcome = rig.ingestor.ingest(archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.TOOL_UNAVAILABLE
    assert archive.read_bytes() == before
    assert not (folder / ".imported").exists()
    assert sorted(p.name for p in rig.folder.iterdir()) == ["a.flac", "b.flac"]
    assert existing.read_bytes() == b"library|untracked"
    deferred = [r.getMessage() for r in caplog.records if r.name == "app.services.organizer"]
    assert "import deferred: the audio of the file already under this name cannot be read now" in deferred
    assert not any(str(tmp_path) in line for line in deferred)
