"""Sign-off s7-live-findings item 1 (live finding XF-L-01, user decision
"skip those files"): on filesystems without extended attributes (exFAT, FAT,
many network shares) macOS writes an AppleDouble companion ``._<name>`` next
to every file, and a ZIP made by Finder carries them as ``__MACOSX/._<name>``.
ffprobe accepts such a 4 KB file named ``._x.flac`` as "flac, 0 Hz", so each
became an untitled track. An import folder never imports a file whose name
starts with ``._`` (startup scan and watcher), nor an archive entry whose base
name starts with ``._`` or that sits under ``__MACOSX/``. The companion is left
where it is, untouched, and is not logged as a failed import."""

import logging
import zipfile
from pathlib import Path

import pytest
from watchdog.events import FileCreatedEvent, FileModifiedEvent, FileMovedEvent

from app.services import ingestion
from app.services.file_watcher import FileWatcher
from app.services.import_outcome import ImportOutcome
from app.services.ingestion import Ingestor, IngestorContext

pytestmark = pytest.mark.usefixtures("fast_stability_poll")

COMPANION = b"\x00\x05\x16\x07\x00\x02\x00\x00Mac OS X        " + bytes(4096 - 24)


def _write(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def _watcher(root: Path):
    seen = []
    watcher = FileWatcher(import_dir=root, on_file=lambda p: seen.append(p) or True)
    return watcher, seen


def test_the_startup_scan_skips_companions_and_leaves_them_untouched(tmp_path, caplog):
    root = tmp_path / "import"
    real = [_write(root / "a.flac", b"audio"), _write(root / "Album" / "b.mp3", b"audio")]
    companions = [_write(root / "._a.flac", COMPANION), _write(root / "Album" / "._b.mp3", COMPANION),
                  _write(root / "._album.zip", COMPANION), _write(root / "Album" / "._", COMPANION)]
    watcher, seen = _watcher(root)

    with caplog.at_level(logging.DEBUG):
        watcher.scan_existing()
        watcher.executor.shutdown(wait=True)

    assert sorted(seen) == sorted(real)
    assert all(p.read_bytes() == COMPANION for p in companions)  # left where it is, untouched
    assert watcher.processed == set()
    # Not a failed import: nothing above debug, and no path or name in any line.
    assert [r for r in caplog.records if r.levelno > logging.DEBUG and "._" in r.getMessage()] == []
    for record in caplog.records:
        assert str(root) not in record.getMessage() and "._a.flac" not in record.getMessage()


@pytest.mark.parametrize("event_type", ["created", "modified", "moved"])
@pytest.mark.parametrize("name", ["._a.flac", "._b.MP3", "._c.zip"])
def test_the_watcher_skips_companions(tmp_path, event_type, name):
    root = tmp_path / "import"
    root.mkdir()
    watcher, seen = _watcher(root)
    path = _write(root / "Album" / name, COMPANION)
    event = {
        "created": lambda: FileCreatedEvent(str(path)),
        "modified": lambda: FileModifiedEvent(str(path)),
        "moved": lambda: FileMovedEvent(str(root / "x.tmp"), str(path)),
    }[event_type]()

    watcher.dispatch(event)
    watcher.executor.shutdown(wait=True)

    assert seen == []
    assert watcher.processed == set()
    assert path.read_bytes() == COMPANION


def test_a_name_with_a_dot_underscore_inside_is_still_imported(tmp_path):
    """Only a name that starts with ``._`` is a companion."""
    root = tmp_path / "import"
    kept = [_write(root / "a._b.flac", b"audio"), _write(root / "_a.flac", b"audio"),
            _write(root / "x._" / "c.flac", b"audio")]
    watcher, seen = _watcher(root)

    watcher.scan_existing()
    watcher.executor.shutdown(wait=True)

    assert sorted(seen) == sorted(kept)


# ── archives dropped into an import folder (check (a)) ───────────────────────


def _finder_zip(path: Path) -> Path:
    """What Finder's "Compress" makes: the files, and ``__MACOSX/`` holding a
    ``._`` companion for each (checked by hand on a ``ditto`` archive: ffprobe
    accepts that companion of ``a.flac`` as "flac, audio, 0 Hz")."""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("Album/a.flac", b"audio-a")
        z.writestr("Album/b.mp3", b"audio-b")
        z.writestr("__MACOSX/Album/._a.flac", COMPANION)
        z.writestr("__MACOSX/Album/._b.mp3", COMPANION)
    return path


def _tar(path: Path) -> Path:
    """Entries that libarchive hands over on every platform: a ``._`` name
    outside ``__MACOSX/`` and another file under it. (The macOS build takes a
    ``._`` tar entry followed by another entry as that entry's metadata, so
    the companion comes last.)"""
    import io
    import tarfile

    with tarfile.open(path, "w") as t:
        for name, data in [("Album/a.flac", b"audio-a"), ("__MACOSX/Album/stray.flac", b"junk"),
                           ("Album/b.mp3", b"audio-b"), ("Album/._c.flac", b"junk")]:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    return path


def _ingestor(tmp_path, monkeypatch, organized: list) -> Ingestor:
    # The quick check is ffprobe; it accepts companions, so it says yes to all here.
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    workspace = _mk(tmp_path / "workspace")
    return Ingestor(IngestorContext(
        workspace_dir=workspace,
        # the file name (round 2: each member is unpacked into a folder of its own)
        organize_function=lambda p: organized.append(p.name)
        or ImportOutcome.IMPORTED))


@pytest.mark.parametrize("make", [_finder_zip, _tar], ids=["finder-zip", "tar"])
def test_an_archives_companions_and_macosx_folder_are_never_imported(tmp_path, monkeypatch, make):
    """The Finder ZIP case passes before the fix on macOS only because the
    macOS build of libarchive folds ``__MACOSX/._x`` into ``x``'s metadata
    (a Linux build hands it over); the tar case fails before the fix anywhere."""
    organized = []
    ingestor = _ingestor(tmp_path, monkeypatch, organized)
    archive = make(_mk(tmp_path / "import") / f"album{'.zip' if make is _finder_zip else '.tar'}")

    outcome = ingestor.ingest(archive, imported_dir=tmp_path / "import" / ".imported")

    assert outcome is ImportOutcome.IMPORTED
    assert sorted(organized) == ["a.flac", "b.mp3"]
    # Every audio file imported, the companions ignored: deleted (sign-off DEV-M-10).
    assert not archive.exists() and not (tmp_path / "import" / ".imported").exists()


def _mk(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    return path
