"""A symbolic link in an import folder is never imported and never read
through (pre-merge review A4-01).

Before: the import followed a link (``is_file()`` does), moved the link itself
into the user's library and recorded it as the track's master, so the stream
route served whatever the link pointed to: another user's master, or any audio
file the server process can read. A linked archive was unpacked through the
link. And a ``.imported`` folder that is a link sent every archive the server
set aside to wherever it pointed (another user's import folder).

Now a link stays where it is, like any file the import cannot use, and nothing
it points to is opened.
"""

import errno
import os
import pathlib
import subprocess
import zipfile
from dataclasses import dataclass
from functools import partial
from pathlib import Path
from unittest.mock import MagicMock

import pytest

from app.database import DatabaseContext
from app.services import file_ops, ingestion
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.file_watcher import FileWatcher
from app.services.import_archive import ArchiveUnpacker
from app.services.import_folders import ImportDispatcher
from app.services.import_outcome import ImportOutcome
from app.services.ingestion import Ingestor, IngestorContext
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL
from tests.upload_zip_fixtures import tiny_limits

# Registered marker: tests/conftest.py skips without ffmpeg/ffprobe.
requires_ffmpeg = pytest.mark.requires_ffmpeg


def _tone(path: Path) -> Path:
    """A tiny real MP3 (the import reads it with the real ffprobe)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
         "-metadata", f"title={path.stem}", "-metadata", "artist=Radiohead",
         "-c:a", "libmp3lame", str(path)],
        check=True,
    )
    return path


def _entries(folder: Path) -> list[str]:
    """Every file and every link under ``folder`` (links are not followed)."""
    if not folder.exists():
        return []
    return sorted(str(p.relative_to(folder)) for p in folder.rglob("*")
                  if p.is_symlink() or p.is_file())


def _same_file(path: Path, before: os.stat_result, data: bytes) -> bool:
    after = os.lstat(path)
    return (after.st_ino, after.st_size, after.st_mtime_ns) == (
        before.st_ino, before.st_size, before.st_mtime_ns) and path.read_bytes() == data


@dataclass
class Server:
    db: OwnedTestDatabase
    sam: int
    alice: int
    music: Path
    root: Path  # USER_IMPORT_DIR
    dispatcher: ImportDispatcher
    tmp: Path

    def alices_master(self) -> Path:
        """Alice imports a song of her own; the path of its master file."""
        assert self.dispatcher.dispatch(_tone(self.root / "alice" / "Lucky.mp3")) is True
        [track] = self.db.get_tracks(owner_id=self.alice)
        assert track.file_path.is_relative_to(self.music / "alice")
        return track.file_path


@pytest.fixture
def server(tmp_path) -> Server:
    """Two users and the real import pipeline over real files."""
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
    assert db.initialize()
    sam, alice = add_test_user(db, "sam"), add_test_user(db, "alice")
    root = tmp_path / "import-users"
    (root / "sam").mkdir(parents=True)
    (root / "alice").mkdir()
    dispatcher = ImportDispatcher(
        user_import_dir=root, database=db,
        make_pipeline=partial(
            make_pipeline, database=db,
            cover_art_manager=CoverArtManager(
                CoverArtContext(cover_art_dir=tmp_path / "art", database=db)),
            music_library_dir=tmp_path / "music", workspace_root=tmp_path / "data" / "workspace",
        ),
    )
    return Server(db, sam, alice, tmp_path / "music", root, dispatcher, tmp_path)


# --- end to end: the real pipeline ------------------------------------------------------------------


@requires_ffmpeg
@pytest.mark.parametrize("target", [
    "another user's master", "an audio file outside every library", "nothing (a dangling link)",
])
def test_a_link_in_an_import_folder_is_never_imported(server, target):
    """Sam drops ``x.mp3``, a link. Sam gets no track, nothing appears in Sam's
    library, the link stays in his folder and what it points to is untouched."""
    if target == "another user's master":
        pointed = server.alices_master()
    elif target == "an audio file outside every library":
        pointed = _tone(server.tmp / "elsewhere" / "private.mp3")
    else:
        pointed = server.tmp / "nowhere.mp3"
    before = (os.lstat(pointed), pointed.read_bytes()) if pointed.exists() else None
    link = server.root / "sam" / "x.mp3"
    link.symlink_to(pointed)

    assert server.dispatcher.dispatch(link) is False

    assert server.db.get_tracks(owner_id=server.sam) == []
    assert _entries(server.music / "sam") == []
    assert link.is_symlink() and os.readlink(link) == str(pointed)
    if before is not None:
        assert _same_file(pointed, *before)
    if target == "another user's master":
        [track] = server.db.get_tracks(owner_id=server.alice)
        assert track.file_path == pointed


@requires_ffmpeg
def test_a_linked_archive_in_an_import_folder_is_never_unpacked(server):
    """The same for an archive: ``album.zip`` in Sam's folder is a link to an
    archive elsewhere. Nothing of it becomes Sam's track; the link stays where
    it is (it is not set aside either)."""
    song = _tone(server.tmp / "sources" / "Airbag.mp3")
    pointed = server.tmp / "elsewhere" / "album.zip"
    pointed.parent.mkdir()
    with zipfile.ZipFile(pointed, "w") as z:
        z.write(song, arcname="OK Computer/Airbag.mp3")
    before = (os.lstat(pointed), pointed.read_bytes())
    link = server.root / "sam" / "album.zip"
    link.symlink_to(pointed)

    assert server.dispatcher.dispatch(link) is False

    assert server.db.get_tracks(owner_id=server.sam) == []
    assert _entries(server.music / "sam") == []
    assert _entries(server.root / "sam") == ["album.zip"]
    assert link.is_symlink() and _same_file(pointed, *before)


# --- the refusal comes before anything reads the link ------------------------------------------------


def _ingestor(tmp_path, organize):
    return Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace" / "u7", organize_function=organize,
        archives=ArchiveUnpacker(owner_id=7, ledger=None, limits=lambda: tiny_limits())))


@pytest.mark.parametrize("name", ["x.flac", "album.zip"])
def test_a_link_is_refused_before_anything_reads_it(tmp_path, monkeypatch, name):
    """Not probed, not unpacked, not handed to the organizer: the outcome is the
    one of a file that is no audio file, and the link is left in the folder."""
    quick_check = MagicMock(return_value=True)
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", quick_check)
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)
    pointed = tmp_path / "elsewhere" / name
    pointed.parent.mkdir()
    if name.endswith(".zip"):
        with zipfile.ZipFile(pointed, "w") as z:
            z.writestr("Album/a.mp3", b"a" * 50)
    else:
        pointed.write_bytes(b"audio")
    folder = tmp_path / "import-users" / "sam"
    folder.mkdir(parents=True)
    link = folder / name
    link.symlink_to(pointed)

    outcome = _ingestor(tmp_path, organize).ingest(link, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.NOT_AUDIO
    quick_check.assert_not_called()
    organize.assert_not_called()
    assert _entries(folder) == [name] and link.is_symlink()
    assert not (tmp_path / "workspace").exists()


# --- a folder on the way to the file is a link --------------------------------------------------------


@requires_ffmpeg
def test_a_file_reached_through_a_linked_folder_is_never_imported(server):
    """``sam/albums`` is a link to the folder that holds Alice's master. The
    file at ``sam/albums/<name>`` is a regular file, but it does not lie in
    Sam's import folder: it is Alice's master. It is not imported, and above
    all it is not moved out of Alice's library."""
    master = server.alices_master()
    before = (os.lstat(master), master.read_bytes())
    (server.root / "sam" / "albums").symlink_to(master.parent, target_is_directory=True)

    assert server.dispatcher.dispatch(server.root / "sam" / "albums" / master.name) is False

    assert _same_file(master, *before), "another user's master was moved or changed"
    assert server.db.get_tracks(owner_id=server.sam) == []
    assert _entries(server.music / "sam") == []
    [track] = server.db.get_tracks(owner_id=server.alice)
    assert track.file_path == master


@pytest.mark.parametrize("name", ["x.flac", "album.zip"])
@pytest.mark.parametrize("depth", ["the file's own folder", "a folder further up"])
def test_a_file_under_a_linked_folder_is_refused_before_anything_reads_it(
    tmp_path, monkeypatch, name, depth
):
    quick_check = MagicMock(return_value=True)
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", quick_check)
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)
    elsewhere = tmp_path / "elsewhere" / "Artist" / "Album"
    elsewhere.mkdir(parents=True)
    if name.endswith(".zip"):
        with zipfile.ZipFile(elsewhere / name, "w") as z:
            z.writestr("Album/a.mp3", b"a" * 50)
    else:
        (elsewhere / name).write_bytes(b"audio")
    data = (elsewhere / name).read_bytes()
    folder = tmp_path / "import-users" / "sam"
    folder.mkdir(parents=True)
    if depth == "the file's own folder":
        (folder / "Album").symlink_to(elsewhere, target_is_directory=True)
        path = folder / "Album" / name
    else:
        (folder / "Artist").symlink_to(elsewhere.parent, target_is_directory=True)
        path = folder / "Artist" / "Album" / name

    outcome = _ingestor(tmp_path, organize).ingest(path, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.NOT_AUDIO
    quick_check.assert_not_called()
    organize.assert_not_called()
    assert (elsewhere / name).read_bytes() == data
    assert not (tmp_path / "workspace").exists() and not (folder / ".imported").exists()


def test_a_real_folder_below_the_import_folder_is_still_imported_from(tmp_path, monkeypatch):
    """The control: real folders, and an import folder that is itself reached
    through a link (an operator's choice), import as before."""
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)
    real = tmp_path / "disk" / "sam"
    (real / "Artist" / "Album").mkdir(parents=True)
    (real / "Artist" / "Album" / "x.flac").write_bytes(b"audio")
    (tmp_path / "import-users").mkdir()
    (tmp_path / "import-users" / "sam").symlink_to(real, target_is_directory=True)
    folder = tmp_path / "import-users" / "sam"
    path = folder / "Artist" / "Album" / "x.flac"

    outcome = _ingestor(tmp_path, organize).ingest(path, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.IMPORTED
    organize.assert_called_once_with(path)


# --- the archive is swapped after it was looked at ------------------------------------------------


def _audio_zip(path: Path, member: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Album/a.mp3", member)
    return path


@pytest.mark.parametrize("swap", ["a link at the archive's name", "a link at its folder's name"])
def test_an_archive_swapped_after_the_look_is_never_unpacked(tmp_path, monkeypatch, swap):
    """The archive was a regular file in a real folder when the import looked
    at it. Before it is opened, its name (or its folder's name) is swapped for
    a link that leads to another user's archive of the same size and time.
    The file that is opened is not the file that was looked at: nothing of it
    is unpacked or handed on, and the attempt ends as "changed"."""
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    organized = []

    def organize(path):
        organized.append(Path(path).read_bytes())
        return ImportOutcome.IMPORTED

    sams, alices = tmp_path / "import-users" / "sam", tmp_path / "import-users" / "alice"
    archive = _audio_zip(sams / "Albums" / "album.zip", b"sam's own audio")
    theirs = _audio_zip(alices / "album.zip", b"alice's audio..")
    st = os.stat(archive)
    os.utime(theirs, ns=(st.st_atime_ns, st.st_mtime_ns))
    assert (os.stat(theirs).st_size, os.stat(theirs).st_mtime_ns) == (st.st_size, st.st_mtime_ns)
    before = (os.lstat(theirs), theirs.read_bytes())
    real_complete = ingestion.archive_is_complete

    def complete_then_swapped(path, **kwargs):  # runs after the look, before the archive is opened
        answer = real_complete(path, **kwargs)
        if swap == "a link at the archive's name":
            os.rename(archive, sams / "set-aside-by-sam.zip")
            os.symlink(theirs, archive)
        else:
            os.rename(sams / "Albums", sams / "Albums-moved-away")
            os.symlink(alices, sams / "Albums", target_is_directory=True)
        return answer

    monkeypatch.setattr(ingestion, "archive_is_complete", complete_then_swapped)

    ingestor = _ingestor(tmp_path, organize)  # one unpacker: it remembers what it refused
    outcome = ingestor.ingest(archive, imported_dir=sams / ".imported")

    assert organized == [], "audio of an archive that was never looked at was handed on"
    assert outcome is ImportOutcome.CHANGED
    assert _same_file(theirs, *before)
    assert _entries(tmp_path / "workspace") == []
    assert not (sams / ".imported").exists()

    # Not remembered as refused: once the name is the real file again, it imports.
    monkeypatch.setattr(ingestion, "archive_is_complete", real_complete)
    if swap == "a link at the archive's name":
        os.unlink(archive)
        os.rename(sams / "set-aside-by-sam.zip", archive)
    else:
        os.unlink(sams / "Albums")
        os.rename(sams / "Albums-moved-away", sams / "Albums")
    assert ingestor.ingest(archive, imported_dir=sams / ".imported") is ImportOutcome.IMPORTED
    assert organized == [b"sam's own audio"]


# --- the move itself --------------------------------------------------------------------------------


@pytest.mark.parametrize("pointed_exists", [True, False])
def test_move_file_never_moves_a_link(tmp_path, monkeypatch, pointed_exists):
    """Not even for a moment: no rename is made at all."""
    pointed = tmp_path / "elsewhere" / "song.flac"
    pointed.parent.mkdir()
    if pointed_exists:
        pointed.write_bytes(b"audio")
    link = tmp_path / "drop" / "song.flac"
    link.parent.mkdir()
    link.symlink_to(pointed)
    dest = tmp_path / "music" / "Artist" / "song.flac"
    real_replace = pathlib.Path.replace
    renames = []
    monkeypatch.setattr(
        pathlib.Path, "replace",
        lambda self, target: renames.append(self) or real_replace(self, target))

    assert file_ops.move_file(link, dest) is False

    assert renames == []
    assert link.is_symlink() and not os.path.lexists(dest)


def test_a_link_swapped_in_just_before_the_move_does_not_stay_in_the_library(
    tmp_path, monkeypatch
):
    """The file was a regular file when it was looked at and is a link at the
    moment of the rename (someone keeps swapping it). The link that was moved
    is moved back and the move answers False: no link is left at the
    destination."""
    pointed = tmp_path / "elsewhere" / "song.flac"
    pointed.parent.mkdir()
    pointed.write_bytes(b"someone else's audio")
    source = tmp_path / "drop" / "song.flac"
    source.parent.mkdir()
    source.write_bytes(b"a real file")
    dest = tmp_path / "music" / "Artist" / "song.flac"
    real_replace = pathlib.Path.replace
    swapped = []

    def replace_after_the_swap(self, target):
        if not swapped:  # only the move itself, not the way back
            swapped.append(self)
            os.unlink(self)
            os.symlink(pointed, self)
        return real_replace(self, target)

    monkeypatch.setattr(pathlib.Path, "replace", replace_after_the_swap)

    assert file_ops.move_file(source, dest) is False

    assert swapped == [source]
    assert not os.path.lexists(dest)
    assert source.is_symlink()  # put back where it came from
    assert pointed.read_bytes() == b"someone else's audio"


# --- the folder archives are set aside in -----------------------------------------------------------


@pytest.mark.parametrize("pointed_exists", [True, False])
def test_an_archive_is_never_set_aside_through_a_linked_imported_folder(
    tmp_path, monkeypatch, pointed_exists
):
    """Sam's ``.imported`` is a link to another user's import folder. An archive
    the server would set aside there stays in Sam's folder; nothing is written
    where the link points. The outcome is the one of a failed move."""
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    sams, alices = tmp_path / "import-users" / "sam", tmp_path / "import-users" / "alice"
    sams.mkdir(parents=True)
    if pointed_exists:
        alices.mkdir()
    (sams / ".imported").symlink_to(alices, target_is_directory=True)
    archive = sams / "readme.zip"
    with zipfile.ZipFile(archive, "w") as z:  # no audio: an archive that is set aside
        z.writestr("readme.txt", b"no songs")
    data = archive.read_bytes()

    outcome = _ingestor(tmp_path, MagicMock(return_value=ImportOutcome.IMPORTED)).ingest(
        archive, imported_dir=sams / ".imported")

    assert outcome is ImportOutcome.MOVE_FAILED
    assert archive.read_bytes() == data
    assert _entries(alices) == []
    assert (sams / ".imported").is_symlink()


def _set_aside_world(tmp_path, monkeypatch):
    """Sam's and Alice's import folders, and an archive of Sam's that the
    server sets aside (it holds no audio)."""
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    sams, alices = tmp_path / "import-users" / "sam", tmp_path / "import-users" / "alice"
    sams.mkdir(parents=True)
    alices.mkdir()
    archive = sams / "readme.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("readme.txt", b"no songs")
    return sams, alices, archive


def test_a_link_put_at_imported_right_after_the_look_is_not_written_through(
    tmp_path, monkeypatch
):
    """Someone keeps swapping: ``.imported`` was not there when it was looked
    at and is a link to another user's folder a moment later. The folder is
    opened without following a link, so the archive stays where it is."""
    sams, alices, archive = _set_aside_world(tmp_path, monkeypatch)
    real_is_symlink = pathlib.Path.is_symlink

    def is_symlink_then_the_link_appears(self):
        answer = real_is_symlink(self)
        if self == sams / ".imported" and not os.path.lexists(self):
            os.symlink(alices, self, target_is_directory=True)
        return answer

    monkeypatch.setattr(pathlib.Path, "is_symlink", is_symlink_then_the_link_appears)

    outcome = _ingestor(tmp_path, MagicMock(return_value=ImportOutcome.IMPORTED)).ingest(
        archive, imported_dir=sams / ".imported")

    assert outcome is ImportOutcome.MOVE_FAILED
    assert archive.exists() and _entries(alices) == []


def test_an_archive_goes_into_the_folder_that_was_opened_not_where_its_name_points_later(
    tmp_path, monkeypatch
):
    """The real ``.imported`` folder was opened; then its name is swapped for a
    link to another user's folder. The archive is moved into the folder that
    was opened (wherever it is now), never through the name."""
    sams, alices, archive = _set_aside_world(tmp_path, monkeypatch)
    data = archive.read_bytes()
    (sams / ".imported").mkdir()
    real_open = os.open
    swapped = []

    def open_then_the_name_is_swapped(path, flags, *args, **kwargs):
        fd = real_open(path, flags, *args, **kwargs)
        if not swapped and Path(os.fspath(path)) == sams / ".imported":
            swapped.append(path)
            os.rename(sams / ".imported", sams / "moved-away")
            os.symlink(alices, sams / ".imported", target_is_directory=True)
        return fd

    monkeypatch.setattr(os, "open", open_then_the_name_is_swapped)

    outcome = _ingestor(tmp_path, MagicMock(return_value=ImportOutcome.IMPORTED)).ingest(
        archive, imported_dir=sams / ".imported")

    assert swapped, "the folder was never opened: the move went by its name"
    assert _entries(alices) == []
    assert (sams / "moved-away" / "readme.zip").read_bytes() == data
    assert outcome is ImportOutcome.IMPORTED and not archive.exists()


def test_setting_aside_never_replaces_anything_in_imported_not_even_a_dangling_link(
    tmp_path, monkeypatch
):
    sams, _alices, archive = _set_aside_world(tmp_path, monkeypatch)
    (sams / ".imported").mkdir()
    (sams / ".imported" / "readme.zip").symlink_to(tmp_path / "nowhere")

    outcome = _ingestor(tmp_path, MagicMock(return_value=ImportOutcome.IMPORTED)).ingest(
        archive, imported_dir=sams / ".imported")

    assert outcome is ImportOutcome.IMPORTED
    assert _entries(sams / ".imported") == ["readme-2.zip", "readme.zip"]
    assert (sams / ".imported" / "readme.zip").is_symlink()


def test_a_dangling_link_put_at_imported_right_after_the_look_is_a_failed_move(
    tmp_path, monkeypatch
):
    sams, alices, archive = _set_aside_world(tmp_path, monkeypatch)
    real_is_symlink = pathlib.Path.is_symlink

    def is_symlink_then_the_link_appears(self):
        answer = real_is_symlink(self)
        if self == sams / ".imported" and not os.path.lexists(self):
            os.symlink(tmp_path / "nowhere", self)
        return answer

    monkeypatch.setattr(pathlib.Path, "is_symlink", is_symlink_then_the_link_appears)

    outcome = _ingestor(tmp_path, MagicMock(return_value=ImportOutcome.IMPORTED)).ingest(
        archive, imported_dir=sams / ".imported")

    assert outcome is ImportOutcome.MOVE_FAILED
    assert archive.exists() and not (tmp_path / "nowhere").exists()


def test_an_imported_folder_on_another_filesystem_is_a_failed_move_not_a_copy(
    tmp_path, monkeypatch
):
    """The set-aside is a rename into the opened folder. Where that cannot be
    done because the folder is on another filesystem, the archive stays where
    it is (it is not copied by its name)."""
    sams, _alices, archive = _set_aside_world(tmp_path, monkeypatch)
    data = archive.read_bytes()

    def other_filesystem(src, dst, **kwargs):
        raise OSError(errno.EXDEV, os.strerror(errno.EXDEV))

    monkeypatch.setattr(ingestion.os, "rename", other_filesystem)

    outcome = _ingestor(tmp_path, MagicMock(return_value=ImportOutcome.IMPORTED)).ingest(
        archive, imported_dir=sams / ".imported")

    assert outcome is ImportOutcome.MOVE_FAILED
    assert archive.read_bytes() == data and _entries(sams / ".imported") == []


def test_an_archive_that_is_no_longer_the_file_that_was_read_is_not_set_aside(
    tmp_path, monkeypatch
):
    """After the archive was unpacked (it holds no audio, so it is set aside),
    the folder it lies in is swapped for a link to another user's folder, where
    an archive of the same name, size and time lies. That file is not the one
    the import looked at first: it is not moved (the outcome is "changed"), as
    it would not be deleted either."""
    sams, alices, _ = _set_aside_world(tmp_path, monkeypatch)
    sub = sams / "albums"
    sub.mkdir()
    archive = sub / "album.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("readme.txt", b"no songs")
    theirs = alices / "album.zip"
    with zipfile.ZipFile(theirs, "w") as z:
        z.writestr("readme.txt", b"NO SONGS")  # other bytes, the same size
    st = os.stat(archive)
    os.utime(theirs, ns=(st.st_atime_ns, st.st_mtime_ns))
    assert (os.stat(theirs).st_size, os.stat(theirs).st_mtime_ns) == (st.st_size, st.st_mtime_ns)
    before = (os.lstat(theirs), theirs.read_bytes())
    real_signature = ingestion.file_signature
    looks = []

    def signature_and_the_folder_is_swapped_after_the_unpack(path):
        # The import reads the signature before the unpack, right after it and
        # once more before the archive leaves its folder: swap before that last one.
        looks.append(path)
        if len(looks) == 3:
            os.rename(sub, sams / "albums-moved-away")
            os.symlink(alices, sub, target_is_directory=True)
        return real_signature(path)

    monkeypatch.setattr(ingestion, "file_signature", signature_and_the_folder_is_swapped_after_the_unpack)

    outcome = _ingestor(tmp_path, MagicMock(return_value=ImportOutcome.IMPORTED)).ingest(
        archive, imported_dir=sams / ".imported")

    assert len(looks) == 3 and sub.is_symlink(), "the swap was not made after the unpack"
    assert outcome is ImportOutcome.CHANGED
    assert _same_file(theirs, *before)
    assert _entries(sams / ".imported") == []


# --- what the scan reaches --------------------------------------------------------------------------


def test_the_scan_does_not_walk_into_a_linked_folder(tmp_path, monkeypatch):
    """A folder link inside an import folder is not followed by the start-up
    scan, so no file of the folder it points to is ever offered for import
    (which would move that file away from where it is)."""
    elsewhere = tmp_path / "music" / "alice" / "Album"
    elsewhere.mkdir(parents=True)
    (elsewhere / "song.flac").write_bytes(b"alice's master")
    root = tmp_path / "import-users"
    (root / "sam").mkdir(parents=True)
    (root / "sam" / "own.flac").write_bytes(b"sam's file")
    (root / "sam" / "albums").symlink_to(elsewhere, target_is_directory=True)
    watcher = FileWatcher(root, on_file=lambda path: True)
    submitted = []
    monkeypatch.setattr(watcher, "_submit_new", submitted.append)

    watcher.scan_existing()
    watcher.executor.shutdown()

    assert submitted == [root / "sam" / "own.flac"]
