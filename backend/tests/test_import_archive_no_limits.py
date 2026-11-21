"""Import-folder archives, round 2 (owner, 2026-11-17): "We should have no
limits on archives, just like we have no limits on files. Of course, we do not
want zip bombs, or archives that will expand to overflow the disc space, so we
need to protect against that." And on an archive that also holds songs the
server cannot import: "Keep it, and warn the user."

So, for import-folder archives only: no cap on the total unpacked size, on one
member's size or on the number of audio files. What stays: the compression
ratio (size bombs), the bounded header walks, the space reservation and the
free-disk floor (a full disk), and one count-bomb guard far above any real
archive (IMPORT_ARCHIVE_MAX_ENTRIES). Uploaded ZIPs keep every limit
(``test_upload_zip_*`` unchanged)."""

import io
import logging
import struct
import tarfile
import zipfile
import zlib
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from app.config import Settings
from app.services import import_archive, ingestion
from app.services.import_archive import (
    ArchiveNoSpace, ArchiveRefused, ArchiveStopped, ArchiveUnpacker, ImportArchiveLimits, import_archive_limits,
)
from app.services.import_outcome import ImportOutcome
from app.services.ingestion import Ingestor, IngestorContext
from app.services.storage_ledger import IMPORT_UNPACK, StorageLedger
from app.services.upload_validation import ValidationFailed
from app.services.upload_zip import ArchivePlan, Member, inspect_archive
from tests.archive_builders import write_rar, write_tar
from tests.identity_worker_fixtures import sql
from tests.owned_database import add_test_user
from tests.upload_zip_fixtures import Entry, build_zip, patch_eocd_count, tiny_limits
from tests.import_startup_fixtures import WATCH, _drain_imports

OPERATOR = "uvicorn.error"
MiB, GiB = 1024**2, 1024**3


def _defaults() -> ImportArchiveLimits:
    """The import-folder limits from the settings' defaults."""
    return import_archive_limits(Settings.model_construct())


def _disk_cost(*sizes):
    return sum(-(-n // 4096) * 4096 + 2 * 4096 for n in sizes)  # data, inode, own folder


def _fail(path, code, limits):
    with pytest.raises(ValidationFailed) as ei:
        import_archive.inspect(path, limits)
    assert ei.value.error.code == code


def _sparse_tar(path, name, declared):
    """A plain tar whose one member declares ``declared`` bytes of zeros,
    written as a sparse file (no real gigabytes)."""
    info = tarfile.TarInfo(name)
    info.size = declared
    header = info.tobuf(format=tarfile.PAX_FORMAT)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(header)
        f.truncate(len(header) + -(-declared // 512) * 512 + 1024)  # data, then the end marker
    return path


@pytest.fixture
def owner(db):
    return add_test_user(db, "sam")


@pytest.fixture(autouse=True)
def quick_check_passes(monkeypatch):
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)


# --- the limits for import folders ------------------------------------------------

def test_the_import_limits_have_no_size_or_audio_count_cap():
    limits = _defaults()

    assert limits.max_expanded_member_bytes is None
    assert limits.max_expanded_bytes_per_batch is None
    assert limits.max_audio_items_per_batch is None
    assert limits.max_compression_ratio == Settings.model_fields["upload_max_compression_ratio"].default
    assert limits.max_archive_members == 100_000


def test_the_guard_and_the_ratio_come_from_the_settings():
    limits = import_archive_limits(Settings.model_construct(import_archive_max_entries=7,
                                                            upload_max_compression_ratio=33,
                                                            upload_max_archive_members=1,
                                                            upload_max_expanded_member_bytes=1))

    assert (limits.max_archive_members, limits.max_compression_ratio) == (7, 33)
    assert limits.max_expanded_member_bytes is None  # the upload setting does not reach imports


# --- no size caps ------------------------------------------------------------------------

@pytest.mark.parametrize("declared", [300 * MiB, 3 * GiB], ids=["over-the-old-file-cap", "3GiB"])
def test_a_member_of_any_honest_size_is_listed(tmp_path, declared):
    """Not a bomb: a stored (1:1) member of any size passes the ratio; only
    the disk rule bounds it."""
    path = _sparse_tar(tmp_path / "big.tar", "big.flac", declared)

    plan = import_archive.inspect(path, _defaults())

    assert [(m.name, m.declared_bytes) for m in plan.members] == [("big.flac", declared)]


def test_more_audio_files_and_entries_than_the_old_caps_are_listed(tmp_path):
    entries = [Entry(f"{i:04}.mp3", b"") for i in range(1001)] + [Entry(f"{i:04}.txt", b"") for i in range(1000)]
    path = build_zip(tmp_path / "many.zip", entries)

    plan = import_archive.inspect(path, _defaults())

    assert len(plan.members) == 1001 and plan.skipped == 1000


def test_more_audio_files_than_the_old_cap_are_unpacked(db, tmp_path, owner):
    path = build_zip(tmp_path / "many.zip", [Entry(f"{i:04}.mp3", b"x") for i in range(1001)])
    unpacker = ArchiveUnpacker(owner_id=owner, ledger=None, limits=_defaults)

    with unpacker.unpack(path, tmp_path / "ws", should_stop=lambda: False) as unpacked:
        assert len(unpacked.files) == 1001


# --- the size-bomb guard stays -----------------------------------------------------------

def test_a_zip_bomb_is_still_refused_by_its_ratio(tmp_path):
    path = build_zip(tmp_path / "bomb.zip", [Entry("a.mp3", bytes(2 * MiB), compress_type=zipfile.ZIP_DEFLATED)])

    _fail(path, "upload_archive_ratio_exceeded", _defaults())


def test_a_tar_gz_bomb_is_still_refused_by_its_ratio(tmp_path):
    path = write_tar(tmp_path / "bomb.tar.gz", [("a.mp3", bytes(4 * MiB))], mode="w:gz")

    _fail(path, "upload_archive_ratio_exceeded", _defaults())


# --- the count-bomb guard ----------------------------------------------------------------

def _guard(n):
    return ImportArchiveLimits(max_archive_members=n, max_compression_ratio=100)


def test_the_count_guard_refuses_one_entry_over_it(tmp_path):
    path = build_zip(tmp_path / "a.zip", [Entry(f"{i}.mp3", b"") for i in range(51)])

    _fail(path, "upload_archive_too_many_members", _guard(50))
    assert len(import_archive.inspect(path, _guard(51)).members) == 51


def test_the_count_guard_refuses_before_the_central_directory_is_parsed(tmp_path, monkeypatch):
    path = build_zip(tmp_path / "a.zip", [Entry("a.mp3", b"")])
    patch_eocd_count(path, 60_000)
    monkeypatch.setattr(zipfile, "ZipFile", MagicMock(side_effect=AssertionError("parsed")))

    _fail(path, "upload_archive_too_many_members", _guard(50_000))


def test_the_count_guard_holds_when_the_end_record_understates_the_count(tmp_path):
    """The end record's count is only a first check: the entries actually
    listed are counted too."""
    path = build_zip(tmp_path / "a.zip", [Entry(f"{i}.mp3", b"") for i in range(51)])
    patch_eocd_count(path, 1)

    _fail(path, "upload_archive_too_many_members", _guard(50))


def test_an_oversized_central_directory_is_refused_for_imports(tmp_path):
    """The import bound is 1 KiB of central directory per allowed entry (the
    upload one is 4 KiB): at the guard that is about 100 MiB read into memory."""
    path = build_zip(tmp_path / "a.zip", [Entry("d" * 1500 + f"/{i}.mp3", b"") for i in range(3)])

    _fail(path, "upload_archive_too_many_members", _guard(3))
    assert len(inspect_archive(path, tiny_limits(max_archive_members=3)).members) == 3  # an upload passes


@pytest.mark.parametrize("gz", [False, True])
def test_the_count_guard_applies_to_a_tar(tmp_path, gz):
    path = write_tar(tmp_path / ("a.tar.gz" if gz else "a.tar"),
                     [(f"{i}.mp3", b"") for i in range(6)], mode="w:gz" if gz else "w")

    _fail(path, "upload_archive_too_many_members", _guard(5))


def test_the_reservation_covers_a_block_and_an_entry_per_file(db, tmp_path, owner):
    """Without a count cap, many tiny files would cost disk blocks the
    reservation did not count."""
    path = build_zip(tmp_path / "a.zip", [Entry("a.mp3", b""), Entry("b.mp3", b"b"), Entry("c.mp3", b"c" * 5000)])
    ledger = StorageLedger(db, path=tmp_path, floor_bytes=0, boot_id="boot",
                           disk_usage=lambda p: SimpleNamespace(free=10**12))
    unpacker = ArchiveUnpacker(owner_id=owner, ledger=ledger, limits=_defaults)
    rows = []

    def during_the_copy():
        if not rows:
            rows.extend(sql(db, "SELECT purpose, bytes FROM storage_reservations"))
        return False

    with unpacker.unpack(path, tmp_path / "ws", should_stop=during_the_copy):
        pass

    assert rows == [{"purpose": IMPORT_UNPACK, "bytes": _disk_cost(0, 1, 5000)}]


# --- the disk rule ----------------------------------------------------------------------

def _ingestor(db, tmp_path, owner, *, free, floor):
    ledger = StorageLedger(db, path=tmp_path, floor_bytes=floor, boot_id="boot",
                           disk_usage=lambda p: SimpleNamespace(free=free))
    return Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace" / f"u{owner}",
        organize_function=MagicMock(return_value=ImportOutcome.IMPORTED),
        archives=ArchiveUnpacker(owner_id=owner, ledger=ledger, limits=_defaults)))


def test_an_archive_that_would_go_below_the_floor_is_kept_and_leaves_nothing(db, tmp_path, owner, caplog):
    folder = tmp_path / "import-users" / "sam"
    archive = _sparse_tar(folder / "album.tar", "big.flac", 8 * MiB)
    floor = 1 * MiB
    free = _disk_cost(8 * MiB) + floor - 1  # one byte short

    with caplog.at_level(logging.INFO):
        outcome = _ingestor(db, tmp_path, owner, free=free, floor=floor).ingest(
            archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.NO_SPACE
    assert archive.exists() and not (folder / ".imported").exists()
    assert not (tmp_path / "workspace").exists() or list((tmp_path / "workspace").rglob("unpack-*")) == []
    assert sql(db, "SELECT * FROM storage_reservations") == []
    assert [r.getMessage() for r in caplog.records if r.name == OPERATOR] == [
        f"An archive in an import folder of user {owner} was not unpacked now (insufficient_storage);"
        " it is tried again later."
    ]


def test_an_archive_that_fits_above_the_floor_is_unpacked(db, tmp_path, owner):
    folder = tmp_path / "import-users" / "sam"
    archive = _sparse_tar(folder / "album.tar", "big.flac", 8 * MiB)
    floor = 1 * MiB

    outcome = _ingestor(db, tmp_path, owner, free=_disk_cost(8 * MiB) + floor, floor=floor).ingest(
        archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.IMPORTED


def test_a_member_writing_more_than_it_declared_is_stopped_and_nothing_is_left(db, tmp_path, owner, monkeypatch):
    path = build_zip(tmp_path / "a.zip", [Entry("a.mp3", b"A" * 300)])
    monkeypatch.setattr(import_archive, "inspect",
                        lambda source, limits, **kw: ArchivePlan((Member(0, "a.mp3", 10, 300),), 0))
    ledger = StorageLedger(db, path=tmp_path, floor_bytes=0, boot_id="boot",
                           disk_usage=lambda p: SimpleNamespace(free=10**12))
    unpacker = ArchiveUnpacker(owner_id=owner, ledger=ledger, limits=_defaults, chunk_size=7)

    with pytest.raises(ArchiveRefused) as ei:
        with unpacker.unpack(path, tmp_path / "ws", should_stop=lambda: False):
            pytest.fail("unpacked beyond its declared size")

    assert ei.value.code == "corrupt"
    assert list((tmp_path / "ws").iterdir()) == []
    assert sql(db, "SELECT * FROM storage_reservations") == []


# --- the warning for a kept archive ---------------------------------------------------------

def test_an_archive_kept_for_songs_the_server_cannot_import_is_warned_about(db, tmp_path, owner, caplog):
    folder = tmp_path / "import-users" / "sam"
    (folder / "Albums").mkdir(parents=True)
    archive = folder / "Albums" / "album.zip"
    with zipfile.ZipFile(archive, "w") as z:
        for name in ("a.mp3", "b.flac", "bonus.ogg", "cover.jpg"):
            z.writestr(name, b"x" * 50)
    ingestor = Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace" / f"u{owner}",
        organize_function=MagicMock(return_value=ImportOutcome.IMPORTED),
        archives=ArchiveUnpacker(owner_id=owner, ledger=None, limits=_defaults)))

    with caplog.at_level(logging.INFO):
        assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.IMPORTED

    assert (folder / ".imported" / "album.zip").exists() and not archive.exists()
    lines = [r.getMessage() for r in caplog.records if r.name == OPERATOR]
    assert lines == [
        f"An archive in an import folder of user {owner} was kept as .imported/album.zip"
        " (it was Albums/album.zip): 2 songs imported, 1 song in a format the server cannot import."
    ]
    assert str(tmp_path) not in lines[0]


def test_no_warning_when_the_archive_is_set_aside_for_a_refused_track_only(db, tmp_path, owner, caplog):
    folder = tmp_path / "import-users" / "sam"
    folder.mkdir(parents=True)
    archive = folder / "album.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("a.mp3", b"x")
    ingestor = Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace" / f"u{owner}",
        organize_function=MagicMock(return_value=ImportOutcome.DUPLICATE),
        archives=ArchiveUnpacker(owner_id=owner, ledger=None, limits=_defaults)))

    with caplog.at_level(logging.INFO):
        ingestor.ingest(archive, imported_dir=folder / ".imported")

    assert (folder / ".imported" / "album.zip").exists()
    assert [r.getMessage() for r in caplog.records if r.name == OPERATOR] == []


# --- the upload settings that no longer reach import folders ------------------------------

UPLOAD_ONLY = ("An upload limit is set that applies to uploaded ZIPs only (%s): archives in import"
               " folders have no size or count limit and are guarded only against bombs"
               " (IMPORT_ARCHIVE_MAX_ENTRIES, UPLOAD_MAX_COMPRESSION_RATIO) and by the free-disk floor.")


def test_a_set_upload_only_setting_is_named_at_startup(caplog):
    settings = Settings.model_construct(upload_max_archive_members=5, upload_max_expanded_member_bytes=9)

    with caplog.at_level(logging.INFO):
        import_archive.upload_only_settings_notice(settings)

    assert [r.getMessage() for r in caplog.records if r.name == OPERATOR] == [
        UPLOAD_ONLY % "UPLOAD_MAX_ARCHIVE_MEMBERS, UPLOAD_MAX_EXPANDED_MEMBER_BYTES"
    ]


def test_no_notice_when_no_upload_only_setting_is_set(caplog):
    with caplog.at_level(logging.INFO):
        import_archive.upload_only_settings_notice(Settings.model_construct(upload_max_receives=3))

    assert [r for r in caplog.records if r.name == OPERATOR] == []


def test_the_server_names_a_set_upload_only_setting_at_startup(configure_app, caplog):
    from fastapi.testclient import TestClient

    with caplog.at_level(logging.INFO):
        with TestClient(configure_app(env={"UPLOAD_MAX_AUDIO_ITEMS_PER_BATCH": "5"}).app):
            pass

    assert UPLOAD_ONLY % "UPLOAD_MAX_AUDIO_ITEMS_PER_BATCH" in [
        r.getMessage() for r in caplog.records if r.name == OPERATOR]


def test_the_server_unpacks_with_the_import_limits(configure_app, tmp_path):
    from fastapi.testclient import TestClient

    with TestClient(configure_app(env={**WATCH, "IMPORT_ARCHIVE_MAX_ENTRIES": "7"}).app) as c:
        _drain_imports(c)
        limits = c.app.state.ingestor._archives._limits()  # the admin's pipeline, as the dispatcher builds it

    assert isinstance(limits, ImportArchiveLimits)
    assert limits.max_archive_members == 7 and limits.max_expanded_bytes_per_batch is None


# --- review round 2 (s7-archive-no-limits-review.md) ----------------------------------------

def _pax_tar(path, names):
    with tarfile.open(path, "w", format=tarfile.PAX_FORMAT) as t:
        for name in names:
            info = tarfile.TarInfo(name)
            t.addfile(info, io.BytesIO(b""))
    return path


def test_r2_2_the_names_of_a_tar_share_the_zip_name_budget(tmp_path, monkeypatch):
    """1 KiB of names per allowed entry, like a ZIP's central directory: 10
    names of 2,000 characters are over the budget of a 10-entry guard."""
    path = _pax_tar(tmp_path / "a.tar", ["d" * 1990 + f"/{i}.mp3" for i in range(10)])
    huge_ratio = ImportArchiveLimits(max_archive_members=10, max_compression_ratio=10**6)

    _fail(path, "upload_archive_too_many_members", huge_ratio)


def test_r2_2_the_names_of_a_rar_share_the_zip_name_budget(tmp_path):
    over = write_rar(tmp_path / "over.rar", [("d" * 1495 + f"/{i}.mp3", b"x") for i in range(3)])
    under = write_rar(tmp_path / "under.rar", [("d" * 895 + f"/{i}.mp3", b"x") for i in range(3)])

    _fail(over, "upload_archive_too_many_members", _guard(3))
    assert len(import_archive.inspect(under, _guard(3)).members) == 3


def test_r2_2_the_listing_stops_when_the_server_stops(tmp_path):
    path = write_rar(tmp_path / "a.rar", [("a.mp3", b"x")])

    with pytest.raises(ArchiveStopped):
        import_archive.inspect(path, _defaults(), should_stop=lambda: True)


def test_r2_1_each_member_is_unpacked_into_a_folder_of_its_own(db, tmp_path, owner):
    """A deep path in the archive does not become a deep tree on disk: the
    reservation counts one folder per member, and that is all there is."""
    deep = "/".join(["d"] * 200)
    path = build_zip(tmp_path / "a.zip", [Entry(f"{deep}/{i}.mp3", b"x") for i in range(3)])
    unpacker = ArchiveUnpacker(owner_id=owner, ledger=None, limits=_defaults)

    with unpacker.unpack(path, tmp_path / "ws", should_stop=lambda: False) as unpacked:
        folders = [p for p in unpacked.folder.rglob("*") if p.is_dir()]
        assert len(folders) == 3
        assert [f.name for f in unpacked.files] == ["0.mp3", "1.mp3", "2.mp3"]


def test_r2_4_at_most_two_archives_are_inspected_and_copied_at_once(db, tmp_path, owner, monkeypatch):
    """The listing of a large archive takes hundreds of MiB; 16 ingest
    threads must not all do it at once. A third unpack waits for a slot (and
    gives up when the server stops)."""
    import threading

    assert import_archive.CONCURRENT_UNPACKS == 2
    monkeypatch.setattr(import_archive, "_unpack_slots", threading.BoundedSemaphore(1))
    first = build_zip(tmp_path / "first.zip", [Entry("a.mp3", b"a" * 100)])
    second = build_zip(tmp_path / "second.zip", [Entry("b.mp3", b"b")])
    unpacker = ArchiveUnpacker(owner_id=owner, ledger=None, limits=_defaults, chunk_size=7)
    inspected, waited = [], []
    real = import_archive.inspect
    monkeypatch.setattr(import_archive, "inspect",
                        lambda source, limits, **kw: inspected.append(source.name) or real(source, limits, **kw))

    def while_the_first_copies():
        if not waited:
            with pytest.raises(ArchiveStopped):
                with unpacker.unpack(second, tmp_path / "ws", should_stop=lambda: True):
                    pytest.fail("a second unpack ran while the only slot was taken")
            waited.append(True)
        return False

    with unpacker.unpack(first, tmp_path / "ws", should_stop=while_the_first_copies) as unpacked:
        assert [f.read_bytes() for f in unpacked.files] == [b"a" * 100]
        # The slot is free again once the copy is done: the import of the members runs outside it.
        with unpacker.unpack(second, tmp_path / "ws", should_stop=lambda: False) as again:
            assert [f.read_bytes() for f in again.files] == [b"b"]

    assert waited == [True]
    assert [Path(n).name for n in inspected] == ["first.zip", "second.zip"]


def test_r2_7_the_disk_cost_uses_the_disks_block_size(db, tmp_path, owner, monkeypatch):
    """A disk with 128 KiB clusters (exFAT) costs a cluster per file and per folder."""
    monkeypatch.setattr(import_archive, "_block_size", lambda path: 128 * 1024)
    path = build_zip(tmp_path / "a.zip", [Entry("a.mp3", b"x")])
    ledger = StorageLedger(db, path=tmp_path, floor_bytes=0, boot_id="boot",
                           disk_usage=lambda p: SimpleNamespace(free=10**12))
    unpacker = ArchiveUnpacker(owner_id=owner, ledger=ledger, limits=_defaults)
    seen = []

    def look():
        if not seen:
            seen.append(sql(db, "SELECT bytes FROM storage_reservations"))
        return False

    with unpacker.unpack(path, tmp_path / "ws", should_stop=look):
        pass

    assert seen == [[{"bytes": 3 * 128 * 1024}]]


def test_r2_7_the_block_size_is_at_least_4_kib():
    assert import_archive._block_size(Path("/")) >= 4096


# --- the whole-archive ratio for a ZIP ------------------------------------------------------

def _overlapped_zip(path, *, entries, data):
    """A ZIP whose central directory lists ``entries`` audio entries that all
    point at one stored copy of ``data``: each passes its own ratio (stored,
    1:1), while together they declare ``entries × len(data)`` bytes from a
    file of little more than ``len(data)`` bytes."""
    crc = zlib.crc32(data)
    local = struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, 0, 0, crc, len(data), len(data), 5, 0)
    local += b"0.mp3" + data
    central = b""
    for i in range(entries):
        name = f"{i:04}.mp3".encode()
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, 20, 20, 0, 0, 0, 0, crc, len(data),
                               len(data), len(name), 0, 0, 0, 0, 0, 0) + name
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, entries, entries, len(central), len(local), 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(local + central + end)
    return path


_OVERLAP_DATA = bytes(range(256)) * 256  # 64 KiB


def test_an_overlapped_zip_is_refused_by_the_whole_archive_ratio(tmp_path):
    path = _overlapped_zip(tmp_path / "overlap.zip", entries=200, data=_OVERLAP_DATA)
    limits = _defaults()
    assert 200 * len(_OVERLAP_DATA) > limits.max_compression_ratio * path.stat().st_size

    _fail(path, "upload_archive_ratio_exceeded", limits)


def test_the_whole_archive_ratio_boundary_for_a_zip(tmp_path):
    """The rule and the numbers of a tar or RAR: the declared sizes against
    the ratio times the archive's size."""
    path = _overlapped_zip(tmp_path / "overlap.zip", entries=20, data=_OVERLAP_DATA)
    declared, size = 20 * len(_OVERLAP_DATA), path.stat().st_size
    at = -(-declared // size)  # the smallest ratio that admits it
    assert at > 1

    assert len(import_archive.inspect(path, ImportArchiveLimits(1000, at)).members) == 20
    _fail(path, "upload_archive_ratio_exceeded", ImportArchiveLimits(1000, at - 1))


def test_an_overlapped_zip_in_an_import_folder_is_refused_once_and_not_inspected_again(
        db, tmp_path, owner, caplog, monkeypatch):
    """Not a lack of space, tried and logged again at every scan and change
    event: a refusal of the archive itself, remembered while it is unchanged."""
    folder = tmp_path / "import-users" / "sam"
    archive = _overlapped_zip(folder / "overlap.zip", entries=200, data=_OVERLAP_DATA)
    floor = 1 * MiB
    ingestor = _ingestor(db, tmp_path, owner, free=floor + archive.stat().st_size, floor=floor)
    inspected = MagicMock(side_effect=import_archive.inspect)
    monkeypatch.setattr(import_archive, "inspect", inspected)

    with caplog.at_level(logging.INFO):
        first = ingestor.ingest(archive, imported_dir=folder / ".imported")
        again = ingestor.ingest(archive, imported_dir=folder / ".imported")

    assert (first, again) == (ImportOutcome.REFUSED, ImportOutcome.REFUSED)
    assert inspected.call_count == 1
    assert archive.exists() and not (folder / ".imported").exists()
    assert sql(db, "SELECT * FROM storage_reservations") == []
    assert [r.getMessage() for r in caplog.records if r.name == OPERATOR] == [
        f"An archive in an import folder of user {owner} was not unpacked (ratio_exceeded);"
        " it stays in the folder."
    ]
