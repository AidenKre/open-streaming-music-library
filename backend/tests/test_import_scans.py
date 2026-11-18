"""Phase M.2a (M-U16, spec §6.3 "Scanning"): ``FileWatcher.scan_existing()``
feeds every existing file through the same ``processed`` set and executor path
as ``on_created``, so a file seen by both is handled once."""

from watchdog.events import FileCreatedEvent

from app.services.file_watcher import FileWatcher


import pytest

pytestmark = pytest.mark.usefixtures("fast_stability_poll")


def _tree(root, *relatives):
    paths = []
    for relative in relatives:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"audio")
        paths.append(path)
    return paths


def _watcher(root):
    seen = []
    watcher = FileWatcher(import_dir=root, on_file=lambda p: seen.append(p) or True)
    return watcher, seen


def test_scan_existing_feeds_every_existing_file_once(tmp_path):
    root = tmp_path / "import"
    files = _tree(root, "a.mp3", "album/b.flac", "album/disc 2/c.zip")
    (root / "empty").mkdir()
    watcher, seen = _watcher(root)

    watcher.scan_existing()
    watcher.executor.shutdown(wait=True)

    assert sorted(seen) == sorted(files)
    # Review r1 m-R1-12: handled paths are forgotten once handled.
    assert watcher.processed == set()


def test_a_file_the_scan_saw_is_not_handled_again_by_on_created(tmp_path):
    root = tmp_path / "import"
    [song] = _tree(root, "song.mp3")
    watcher, seen = _watcher(root)

    watcher.scan_existing()
    watcher.on_created(FileCreatedEvent(str(song)))
    watcher.executor.shutdown(wait=True)

    assert seen == [song]


def test_a_file_on_created_saw_is_not_rescanned(tmp_path):
    root = tmp_path / "import"
    [song] = _tree(root, "song.mp3")
    watcher, seen = _watcher(root)

    watcher.on_created(FileCreatedEvent(str(song)))
    watcher.scan_existing()
    watcher.executor.shutdown(wait=True)

    assert seen == [song]


def test_scan_existing_can_scan_one_subfolder(tmp_path):
    root = tmp_path / "import-users"
    sams = _tree(root, "sam/a.mp3", "sam/x/b.mp3")
    _tree(root, "alex/c.mp3")
    watcher, seen = _watcher(root)

    watcher.scan_existing(root / "sam")
    watcher.executor.shutdown(wait=True)

    assert sorted(seen) == sorted(sams)


def test_scanning_a_missing_folder_does_nothing(tmp_path):
    watcher, seen = _watcher(tmp_path / "missing")

    watcher.scan_existing()
    watcher.executor.shutdown(wait=True)

    assert seen == []


def test_a_file_that_was_not_handled_is_fed_again_by_a_later_scan(tmp_path):
    """A dispatcher-ignored drop (for example under a folder whose user signs
    up later) must not stay marked processed, or the signup scan would skip
    it. A handled file is moved out of the import folder (the organizer moves
    it), so a later scan cannot feed it again. Review r1 m-R1-12: the watcher
    forgets every handled path, so nothing stays marked."""
    from concurrent.futures import ThreadPoolExecutor

    root = tmp_path / "import-users"
    ignored, handled = _tree(root, "later/a.mp3", "sam/b.mp3")
    seen = []

    def on_file(p):
        seen.append(p)
        if p == handled:
            p.unlink()  # what the organizer's move does
            return True
        return False

    watcher = FileWatcher(import_dir=root, on_file=on_file)

    watcher.scan_existing()
    watcher.executor.shutdown(wait=True)
    watcher.executor = ThreadPoolExecutor(max_workers=2)
    watcher.scan_existing()
    watcher.executor.shutdown(wait=True)

    assert sorted(seen) == sorted([ignored, handled, ignored])
    assert watcher.processed == set()


def test_files_under_a_dot_folder_are_never_scanned_or_watched(tmp_path):
    """Review r1 m-R1-02 / DEV-M-10: ``.imported/`` (and any dot-folder) holds
    archives already imported; neither the scan nor ``on_created`` feeds them."""
    root = tmp_path / "import-users"
    kept = _tree(root, "sam/a.mp3", "sam/.hidden.mp3")
    skipped = _tree(
        root, "sam/.imported/album.zip", "sam/x/.cache/b.mp3", ".imported/c.zip"
    )
    watcher, seen = _watcher(root)

    watcher.scan_existing()
    for path in skipped:
        watcher.on_created(FileCreatedEvent(str(path)))
    watcher.executor.shutdown(wait=True)

    assert sorted(seen) == sorted(kept)


def test_a_name_dropped_again_after_its_file_was_handled_is_handled_again(tmp_path):
    """Review r1 m-R1-12: a handled path is forgotten, so a second
    ``01 - Intro.flac`` dropped at the same path later is imported too."""
    from concurrent.futures import ThreadPoolExecutor

    root = tmp_path / "import-users"
    [song] = _tree(root, "sam/01 - Intro.flac")
    watcher, seen = _watcher(root)

    watcher.on_created(FileCreatedEvent(str(song)))
    watcher.executor.shutdown(wait=True)
    watcher.executor = ThreadPoolExecutor(max_workers=2)
    watcher.on_created(FileCreatedEvent(str(song)))
    watcher.executor.shutdown(wait=True)

    assert seen == [song, song]
    assert watcher.processed == set()

