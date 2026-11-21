"""Sign-off DEV-7-14 point 1: an archive in an import folder gets the upload
ZIP checks and a space reservation before anything is unpacked. The rules
themselves are tested once, with the shared inspection
(``test_upload_zip_inspect.py``, ``test_archive_inspect_formats.py``) and the
unpack (``test_import_archive_unpack.py``); here only the import-folder
wiring: each class of refusal reaches the import-folder outcome (the archive
stays where it is, one operator line with a fixed code and no path), an
unchanged refused archive is not inspected or logged again, a lack of space
keeps the archive for later, the reservation is released on every exit, the
limits are the upload settings, and a dead run's unpack is cleaned up at
startup."""

import logging
import tarfile
import zipfile
from unittest.mock import MagicMock

import pytest
from fastapi.testclient import TestClient

from app.services import ingestion
from app.services.import_archive import ArchiveUnpacker
from app.services.import_outcome import ImportOutcome
from app.services.ingestion import Ingestor, IngestorContext
from app.services.pipeline import make_pipeline
from app.services.storage_ledger import IMPORT_UNPACK
from tests.archive_builders import tar_info, write_tar
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.import_startup_fixtures import WATCH, _drain_imports, _tone, requires_ffmpeg
from tests.upload_zip_fixtures import Entry, LedgerSpy, build_zip, corrupt_member_data, make_ledger, tiny_limits

OPERATOR = "uvicorn.error"


def _disk_cost(*sizes):
    """What the reservation must cover for these written files: each file's
    bytes rounded up to a 4 KiB block, plus one block for its inode and one
    for the folder it is unpacked into (round 2, review: every member gets
    its own folder, whatever its path in the archive)."""
    return sum(-(-n // 4096) * 4096 + 2 * 4096 for n in sizes)


A, B = b"A" * 300, b"B" * 200


@pytest.fixture
def owner(db):
    return add_test_user(db, "sam")


@pytest.fixture(autouse=True)
def quick_check_passes(monkeypatch):
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)


def _ingestor(db, tmp_path, owner, *, free=10**12, organize=None, should_stop=None, limits=None):
    unpacker = ArchiveUnpacker(owner_id=owner, ledger=make_ledger(db, tmp_path, free=free),
                               limits=lambda: limits or tiny_limits(), chunk_size=7)
    extra = {"should_stop": should_stop} if should_stop is not None else {}
    return Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace" / f"u{owner}",
        organize_function=organize or MagicMock(return_value=ImportOutcome.IMPORTED),
        archives=unpacker, **extra))


def _folder(tmp_path):
    folder = tmp_path / "import-users" / "sam"
    folder.mkdir(parents=True, exist_ok=True)
    return folder


def _zip(path, entries):
    path.parent.mkdir(parents=True, exist_ok=True)
    return build_zip(path, entries)


def _album(path):
    return _zip(path, [Entry("a.mp3", A), Entry("b.mp3", B), Entry("notes.txt", b"n")])


def _operator_lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


def _rows(db):
    return sql(db, "SELECT owner_id, purpose, bytes FROM storage_reservations")


def _unpack_folders(tmp_path):
    root = tmp_path / "workspace"
    return [p for p in root.rglob("unpack-*")] if root.exists() else []


# --- each class of refusal reaches the import-folder outcome once ---------------

def _too_many_audio(folder):
    return _zip(folder / "album.zip", [Entry(f"{i}.mp3", b"x") for i in range(5)])


def _symlink_in_tar(folder):
    return write_tar(folder / "album.tar",
                     [("a.mp3", A), tar_info("b.mp3", kind=tarfile.SYMTYPE, linkname="/etc")])


def _zip_named_tar(folder):
    # Over one 512-byte tar block, so the tar completeness check reads it.
    _zip(folder / "src.zip", [Entry("a.mp3", b"A" * 600)]).rename(folder / "album.tar")
    return folder / "album.tar"


def _corrupt_member(folder):
    path = _zip(folder / "album.zip", [Entry("a.mp3", A), Entry("b.mp3", B)])
    corrupt_member_data(path, "b.mp3")
    return path


def _not_a_zip(folder):
    (folder / "album.zip").write_bytes(b"not a zip")
    return folder / "album.zip"


def _truncated(folder):
    path = _zip(folder / "album.zip", [Entry("a.mp3", A)])
    path.write_bytes(path.read_bytes()[:-30])
    return path


def _traversal(folder):
    return _zip(folder / "album.zip", [Entry("../evil.mp3", A), Entry("ok.mp3", B)])


@pytest.mark.parametrize("make,code", [
    (_too_many_audio, "too_many_audio"),      # inspection, ZIP
    (_symlink_in_tar, "unsafe_member"),       # inspection, tar
    (_zip_named_tar, "invalid"),              # the format is not the extension's
    (_corrupt_member, "corrupt"),             # while copying
    (_not_a_zip, "invalid"),
    (_truncated, "invalid"),
    (_traversal, "unsafe_path"),
])
def test_a_refused_archive_stays_with_one_operator_line(db, tmp_path, owner, caplog, make, code):
    folder = _folder(tmp_path)
    archive = make(folder)
    before = archive.read_bytes()
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)

    with caplog.at_level(logging.INFO):
        handled = _ingestor(db, tmp_path, owner, organize=organize).ingest_file(
            archive, imported_dir=folder / ".imported")

    assert handled is False
    assert archive.read_bytes() == before
    assert not (folder / ".imported").exists()
    organize.assert_not_called()
    assert _unpack_folders(tmp_path) == []
    assert not (tmp_path / "import-users" / "evil.mp3").exists()
    assert _rows(db) == []
    assert _operator_lines(caplog) == [
        f"An archive in an import folder of user {owner} was not unpacked ({code}); it stays in the folder."
    ]


def test_the_outcome_of_a_refused_archive_is_refused(db, tmp_path, owner):
    archive = _too_many_audio(_folder(tmp_path))

    assert _ingestor(db, tmp_path, owner).ingest(
        archive, imported_dir=archive.parent / ".imported") is ImportOutcome.REFUSED


def test_an_unchanged_refused_archive_is_neither_inspected_nor_logged_again(db, tmp_path, owner, caplog):
    folder = _folder(tmp_path)
    archive = _too_many_audio(folder)
    ingestor = _ingestor(db, tmp_path, owner)

    with caplog.at_level(logging.INFO):
        assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.REFUSED
        first = len(caplog.records)
        assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.REFUSED

    assert first >= 1 and len(caplog.records) == first  # nothing logged the second time

    _zip(archive, [Entry("a.mp3", A)])  # replaced by an acceptable archive
    assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.IMPORTED


# --- space -------------------------------------------------------------------------

def test_without_space_the_archive_stays_and_is_tried_again(db, tmp_path, owner, caplog):
    folder = _folder(tmp_path)
    archive = _album(folder / "album.zip")
    before = archive.read_bytes()

    with caplog.at_level(logging.INFO):
        for _ in range(2):  # not remembered: each attempt checks the space again
            assert _ingestor(db, tmp_path, owner, free=10).ingest(
                archive, imported_dir=folder / ".imported") is ImportOutcome.NO_SPACE

    assert archive.read_bytes() == before
    assert not (folder / ".imported").exists()
    assert _operator_lines(caplog) == [
        f"An archive in an import folder of user {owner} was not unpacked now (insufficient_storage);"
        " it is tried again later."
    ] * 2


def test_two_archives_whose_reservations_exceed_the_free_space_do_not_both_unpack(db, tmp_path, owner):
    folder = _folder(tmp_path)
    first = _album(folder / "first.zip")
    second = _album(folder / "second.zip")
    during = []

    def should_stop():
        # Called between the copied blocks of the first ZIP: while its copy
        # holds its reservation (round 2: released once the bytes are on disk).
        if not during:
            during.append(None)
            during[0] = ingestor.ingest(second, imported_dir=folder / ".imported")
        return False

    ingestor = _ingestor(db, tmp_path, owner, free=_disk_cost(len(A), len(B)) * 2 - 1,
                         should_stop=should_stop)

    assert ingestor.ingest(first, imported_dir=folder / ".imported") is ImportOutcome.IMPORTED
    assert during == [ImportOutcome.NO_SPACE]
    assert second.exists()

    # The retry, once the first archive's space is released.
    assert ingestor.ingest(second, imported_dir=folder / ".imported") is ImportOutcome.IMPORTED
    assert _rows(db) == []


class Boom(Exception):
    pass


def test_the_reservation_is_released_when_a_member_import_raises(db, tmp_path, owner):
    folder = _folder(tmp_path)
    archive = _album(folder / "album.zip")

    with pytest.raises(Boom):
        _ingestor(db, tmp_path, owner, organize=MagicMock(side_effect=Boom)).ingest(
            archive, imported_dir=folder / ".imported")

    assert _rows(db) == []
    assert _unpack_folders(tmp_path) == []
    assert archive.exists()


def test_a_stop_request_between_members_releases_the_reservation(db, tmp_path, owner):
    folder = _folder(tmp_path)
    archive = _album(folder / "album.zip")
    stop = []
    organize = MagicMock(side_effect=lambda p: stop.append(1) or ImportOutcome.IMPORTED)

    outcome = _ingestor(db, tmp_path, owner, organize=organize, should_stop=lambda: bool(stop)).ingest(
        archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.STOPPED
    assert organize.call_count == 1
    assert _rows(db) == []
    assert _unpack_folders(tmp_path) == []
    assert archive.exists() and not (folder / ".imported").exists()


# --- the pipeline wiring -------------------------------------------------------------

def test_the_pipeline_unpacks_with_the_given_ledger_and_limits_for_its_owner(db, tmp_path, owner):
    ledger = LedgerSpy(make_ledger(db, tmp_path))
    limits = {"now": tiny_limits(max_archive_members=2)}
    _, ingestor = make_pipeline(
        db.get_user(owner), database=db, cover_art_manager=MagicMock(),
        music_library_dir=tmp_path / "music", workspace_root=tmp_path / "workspace",
        archive_ledger=ledger, archive_limits=lambda: limits["now"])
    ingestor.organize_function = MagicMock(return_value=ImportOutcome.IMPORTED)
    folder = _folder(tmp_path)
    archive = _album(folder / "album.zip")  # three entries

    assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.REFUSED
    assert ledger.reserves == []

    limits["now"] = tiny_limits(max_archive_members=3)
    assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.IMPORTED
    assert ledger.reserves == [
        {"owner_id": owner, "purpose": IMPORT_UNPACK, "nbytes": _disk_cost(len(A), len(B)), "subject_ref": None}
    ]


# --- the running server -----------------------------------------------------------------

def _zip_of_tone(path, title, tmp_path):
    song = tmp_path / "src" / f"{title}.mp3"
    _tone(song, title)
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        z.write(song, f"{title}.mp3")
        z.writestr("notes.txt", "liner notes")
    return path


def _boot_and_drain(configure_app, env=None):
    with TestClient(configure_app(env={**WATCH, **(env or {})}).app) as c:
        _drain_imports(c)
        return c.app.state.database


@requires_ffmpeg
def test_raising_a_setting_admits_an_archive_the_lower_limit_refused(configure_app, tmp_path, caplog):
    """Round 2: import-folder archives have no size or count limit, only the
    count-bomb guard IMPORT_ARCHIVE_MAX_ENTRIES (and the ratio and disk
    rules); a raised value applies at the next attempt (here the next start's
    scan) with no code change."""
    from app.library import Library

    with TestClient(configure_app().app) as c:
        sam = add_test_user(c.app.state.database, "sam")
    archive = _zip_of_tone(tmp_path / "import-users" / "sam" / "album.zip", "Lucky", tmp_path)

    with caplog.at_level(logging.INFO):
        db = _boot_and_drain(configure_app, {"IMPORT_ARCHIVE_MAX_ENTRIES": "1"})

    assert Library(db, sam).get_tracks() == []
    assert archive.exists()
    assert (f"An archive in an import folder of user {sam} was not unpacked (too_many_members);"
            " it stays in the folder.") in _operator_lines(caplog)

    db = _boot_and_drain(configure_app, {"IMPORT_ARCHIVE_MAX_ENTRIES": "2"})

    assert [t.metadata.title for t in Library(db, sam).get_tracks()] == ["Lucky"]
    assert not archive.exists()


def test_startup_releases_a_dead_runs_unpack_and_removes_only_its_folder(configure_app, tmp_path):
    with TestClient(configure_app().app) as c:
        database = c.app.state.database
        sam = add_test_user(database, "sam")
    sql(database, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id,"
                  " created_at) VALUES (?, ?, NULL, 500, 'a-dead-boot', 0)", (sam, IMPORT_UNPACK))
    workspace = tmp_path / "data" / "workspace" / f"u{sam}"
    left = workspace / ("unpack-" + "0" * 32)
    (left / "Album").mkdir(parents=True)
    (left / "Album" / "a.mp3").write_bytes(A)
    (workspace / "notes.txt").write_text("not the server's")

    with TestClient(configure_app().app) as c:
        database = c.app.state.database

    assert sql(database, "SELECT * FROM storage_reservations WHERE purpose = ?", (IMPORT_UNPACK,)) == []
    assert not left.exists()
    assert (workspace / "notes.txt").read_text() == "not the server's"


def test_the_unpack_ledger_reads_the_workspace_disk_with_the_server_floor(configure_app, tmp_path):
    with TestClient(configure_app(env={"STORAGE_FREE_SPACE_FLOOR_BYTES": "12345"}).app) as c:
        ledger = c.app.state.import_unpack_ledger
        workspace = (tmp_path / "data" / "workspace").resolve()

    assert ledger._path.resolve() == workspace
    assert ledger._floor == 12345
