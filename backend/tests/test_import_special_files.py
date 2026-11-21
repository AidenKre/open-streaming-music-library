"""A FIFO, a socket or a device given an audio or archive name in an import
folder is not a file to import. Nothing in the watcher or the ingest opens
it for a blocking read: a plain ``open()`` of a FIFO waits until a writer
appears, so eight such files would hold every one of the watcher's eight
shared workers and stop every user's imports.

Each test runs the code under test in a thread of its own with a time bound,
so a regression fails instead of hanging the suite; the bound is far above
what the code needs (it never waits), and a writer opened without blocking
releases a thread that did block, so nothing outlives the test."""

import os
import threading
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import logging

from app.services import file_watcher, import_outcome, ingestion
from app.services.file_watcher import FileWatcher
from app.services.import_archive import ArchiveUnpacker
from app.services.import_outcome import ImportOutcome
from app.services.ingestion import Ingestor, IngestorContext
from tests.upload_zip_fixtures import tiny_limits

BOUND_S = 5.0

pytestmark = pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="needs FIFOs")


def _fifo(folder: Path, name: str) -> Path:
    path = folder / name
    os.mkfifo(path)
    return path


def _bounded(fifo: Path, call):
    """``call()`` in a daemon thread: (whether it returned within the bound,
    its result). A thread still blocked in ``open()`` is released."""
    result = {}
    thread = threading.Thread(target=lambda: result.setdefault("value", call()), daemon=True)
    thread.start()
    thread.join(BOUND_S)
    returned = not thread.is_alive()
    while thread.is_alive():  # only after a regression: give the blocked open its writer
        try:
            os.close(os.open(fifo, os.O_WRONLY | os.O_NONBLOCK))
        except OSError:  # no reader yet
            pass
        thread.join(0.05)
    return returned, result.get("value")


def test_a_fifo_with_an_audio_name_never_blocks_a_worker(tmp_path, fast_stability_poll):
    fifo = _fifo(tmp_path, "song.flac")
    on_file = MagicMock(return_value=True)
    watcher = FileWatcher(tmp_path, on_file)
    watcher.processed.add(fifo)  # as _submit_new leaves it for the worker
    try:
        returned, handled = _bounded(fifo, lambda: watcher.process_file_after_stable(fifo))
    finally:
        watcher.executor.shutdown(wait=True)

    assert returned, "the worker blocked on the FIFO"
    # Handed on without waiting or opening it: the ingest looks at it only
    # with lstat, says once what it is, and never imports it.
    assert handled is True
    on_file.assert_called_once_with(fifo)
    assert fifo not in watcher.processed


def test_the_readiness_check_refuses_a_fifo_without_waiting(tmp_path):
    fifo = _fifo(tmp_path, "song.mp3")

    returned, readable = _bounded(fifo, lambda: file_watcher.can_open_for_read(fifo))

    assert returned, "the readiness check blocked on the FIFO"
    assert readable is False


def test_the_readiness_check_does_not_read_through_a_link(tmp_path):
    """A link is looked at, never followed: the ingest does not import it either."""
    real = tmp_path / "elsewhere.flac"
    real.write_bytes(b"audio")
    link = tmp_path / "song.flac"
    link.symlink_to(real)

    assert file_watcher.can_open_for_read(link) is False
    assert file_watcher.can_open_for_read(real) is True


@pytest.mark.parametrize("name", ["album.tar", "album.tar.gz", "album.rar"])
def test_the_completeness_check_of_an_archive_never_waits_on_a_fifo(tmp_path, name):
    """Reached only if a FIFO took the archive's place after the ingest looked
    at it: the check does not wait, and leaves the decision to the unpack,
    which opens nothing but the regular file that was looked at first."""
    fifo = _fifo(tmp_path, name)

    returned, complete = _bounded(fifo, lambda: ingestion.archive_is_complete(fifo))

    assert returned, "the completeness check blocked on the FIFO"
    assert complete is True


def test_nothing_but_a_regular_file_is_ever_opened(tmp_path, monkeypatch):
    """The kind of file is looked at before anything is opened: opening a
    device can have effects of its own, whatever the flags."""
    from app.services import import_outcome

    fifo = _fifo(tmp_path, "song.flac")
    opened = []
    real_open = open
    monkeypatch.setattr(import_outcome, "open",
                        lambda path, *a, **kw: opened.append(path) or real_open(path, *a, **kw),
                        raising=False)

    returned, readable = _bounded(fifo, lambda: file_watcher.can_open_for_read(fifo))

    assert returned and readable is False
    assert opened == []


def test_a_fifo_put_at_the_name_after_the_look_does_not_block(tmp_path, monkeypatch):
    """The name showed a regular file when it was looked at; a FIFO took its
    place before the open. The open does not wait for a writer, and the file
    it reaches is checked again."""
    import stat as stat_module
    from types import SimpleNamespace

    from app.services import import_outcome

    fifo = _fifo(tmp_path, "song.flac")
    monkeypatch.setattr(import_outcome.os, "lstat",
                        lambda path, *a, **kw: SimpleNamespace(st_mode=stat_module.S_IFREG | 0o644))

    returned, readable = _bounded(fifo, lambda: file_watcher.can_open_for_read(fifo))

    assert returned, "the open waited for a writer"
    assert readable is False


# --- the operator is told once what lies there -----------------------------------------

OPERATOR = "uvicorn.error"
OWNER = 7


def _skipped(name, what):
    return f"An entry in an import folder of user {OWNER} is skipped: {name} is {what}, not a file."


def _lines(caplog):
    return [r.getMessage() for r in caplog.records if r.name == OPERATOR]


def _import_folder(tmp_path):
    """User 7's import folder, with the ingest and the watcher the server
    builds for it; the organizer imports whatever reaches it."""
    folder = tmp_path / "import-users" / "sam"
    (folder / "Album").mkdir(parents=True)
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)
    ingestor = Ingestor(IngestorContext(
        workspace_dir=tmp_path / "workspace" / f"u{OWNER}", organize_function=organize,
        archives=ArchiveUnpacker(owner_id=OWNER, ledger=None, limits=lambda: tiny_limits())))
    watcher = FileWatcher(folder, lambda p: ingestor.ingest_file(p, imported_dir=folder / ".imported"))
    return folder, ingestor, watcher, organize


def _drain(watcher):
    for future in list(watcher._futures):
        future.result()


def test_a_fifo_is_named_once_over_three_scans_and_a_file_beside_it_imports(
        tmp_path, caplog, monkeypatch, fast_stability_poll):
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    folder, _, watcher, organize = _import_folder(tmp_path)
    fifo = _fifo(folder / "Album", "x.flac")
    song = folder / "Album" / "song.flac"
    song.write_bytes(b"audio")

    def three_scans():
        for _ in range(3):
            watcher.scan_existing()
            _drain(watcher)

    try:
        with caplog.at_level(logging.INFO):
            returned, _ = _bounded(fifo, three_scans)
    finally:
        watcher.executor.shutdown(wait=True)

    assert returned, "a scan blocked on the FIFO"
    assert _lines(caplog) == [_skipped("Album/x.flac", "a named pipe")]
    assert song in [c.args[0] for c in organize.call_args_list]
    assert fifo not in [c.args[0] for c in organize.call_args_list]
    assert str(tmp_path) not in _lines(caplog)[0]


def test_a_fifo_announced_by_events_is_named_once(tmp_path, caplog, fast_stability_poll):
    folder, _, watcher, organize = _import_folder(tmp_path)
    fifo = _fifo(folder / "Album", "x.flac")

    def three_events():
        for _ in range(3):
            watcher.on_created(MagicMock(is_directory=False, src_path=str(fifo)))
            _drain(watcher)

    try:
        with caplog.at_level(logging.INFO):
            returned, _ = _bounded(fifo, three_events)
    finally:
        watcher.executor.shutdown(wait=True)

    assert returned, "a worker blocked on the FIFO"
    assert _lines(caplog) == [_skipped("Album/x.flac", "a named pipe")]
    organize.assert_not_called()


def test_a_new_fifo_at_the_same_name_is_named_again(tmp_path, caplog):
    folder, ingestor, _, _ = _import_folder(tmp_path)
    fifo = _fifo(folder, "x.mp3")

    with caplog.at_level(logging.INFO):
        ingestor.ingest(fifo, imported_dir=folder / ".imported")
        ingestor.ingest(fifo, imported_dir=folder / ".imported")
        # Made beside it and renamed over it: another inode, whatever the filesystem reuses.
        os.mkfifo(folder / "new")
        os.rename(folder / "new", fifo)
        outcome = ingestor.ingest(fifo, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.NOT_AUDIO
    assert _lines(caplog) == [_skipped("x.mp3", "a named pipe")] * 2


def test_a_link_with_an_audio_name_is_named_once(tmp_path, caplog):
    folder, ingestor, _, organize = _import_folder(tmp_path)
    real = tmp_path / "elsewhere.flac"
    real.write_bytes(b"audio")
    link = folder / "Album" / "song.flac"
    link.symlink_to(real)

    with caplog.at_level(logging.INFO):
        for _ in range(2):
            assert ingestor.ingest(link, imported_dir=folder / ".imported") is ImportOutcome.NOT_AUDIO

    assert _lines(caplog) == [_skipped("Album/song.flac", "a symbolic link")]
    organize.assert_not_called()


INGEST_LOG = "app.services.ingestion"


def _import_failed_lines(caplog):
    return [r.getMessage() for r in caplog.records
            if r.name == INGEST_LOG and r.getMessage().startswith("import failed")]


def _touch(path, i):
    """Moves the entry's times, as each write to a FIFO does on Linux."""
    st = os.lstat(path)
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + (i + 1) * 1_000_000_000), follow_symlinks=False)


def test_a_fifo_written_to_is_named_once_and_never_as_a_failed_import(tmp_path, caplog):
    folder, ingestor, _, organize = _import_folder(tmp_path)
    fifo = _fifo(folder / "Album", "x.flac")

    with caplog.at_level(logging.INFO):
        for i in range(5):
            assert ingestor.ingest(fifo, imported_dir=folder / ".imported") is ImportOutcome.NOT_AUDIO
            _touch(fifo, i)

    assert _lines(caplog) == [_skipped("Album/x.flac", "a named pipe")]
    assert _import_failed_lines(caplog) == []
    organize.assert_not_called()


def test_a_burst_of_events_for_a_remembered_fifo_does_no_import_work(tmp_path, caplog, fast_stability_poll):
    folder, ingestor, _, organize = _import_folder(tmp_path)
    fifo = _fifo(folder / "Album", "x.flac")
    on_file = MagicMock(side_effect=lambda p: ingestor.ingest_file(p, imported_dir=folder / ".imported"))
    watcher = FileWatcher(folder, on_file)

    def first_then_a_burst():
        watcher.on_created(MagicMock(is_directory=False, src_path=str(fifo)))
        _drain(watcher)
        with patch.object(watcher.executor, "submit") as submit:
            for i in range(20):
                _touch(fifo, i)
                watcher.on_modified(MagicMock(is_directory=False, src_path=str(fifo)))
        return submit.call_count

    try:
        with caplog.at_level(logging.INFO):
            returned, queued = _bounded(fifo, first_then_a_burst)
    finally:
        watcher.executor.shutdown(wait=True)

    assert returned, "a worker blocked on the FIFO"
    assert queued == 0
    on_file.assert_called_once_with(fifo)
    assert _lines(caplog) == [_skipped("Album/x.flac", "a named pipe")]
    assert _import_failed_lines(caplog) == []
    organize.assert_not_called()


def test_a_file_later_put_at_a_skipped_name_is_imported(tmp_path, caplog, monkeypatch, fast_stability_poll):
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    folder, _, watcher, organize = _import_folder(tmp_path)
    fifo = _fifo(folder / "Album", "x.flac")

    def fifo_then_a_file():
        watcher.on_created(MagicMock(is_directory=False, src_path=str(fifo)))
        _drain(watcher)
        fifo.unlink()
        fifo.write_bytes(b"audio")
        watcher.on_created(MagicMock(is_directory=False, src_path=str(fifo)))
        _drain(watcher)

    try:
        with caplog.at_level(logging.INFO):
            returned, _ = _bounded(fifo, fifo_then_a_file)
    finally:
        watcher.executor.shutdown(wait=True)

    assert returned
    organize.assert_called_once_with(fifo)
    assert _lines(caplog) == [_skipped("Album/x.flac", "a named pipe")]  # the FIFO's, before the file


def test_the_memory_of_skipped_entries_is_bounded(tmp_path, caplog, monkeypatch, fast_stability_poll):
    """A user who keeps making FIFOs under new names gets each named once; the
    memory keeps only the latest ones (an older one may be named again)."""
    monkeypatch.setattr(import_outcome, "SKIPPED_ENTRIES_REMEMBERED", 3)
    folder, ingestor, watcher, _ = _import_folder(tmp_path)
    fifos = [_fifo(folder / "Album", f"{i}.flac") for i in range(8)]

    def one_event_each():
        for fifo in fifos:
            watcher.on_created(MagicMock(is_directory=False, src_path=str(fifo)))
            _drain(watcher)

    try:
        with caplog.at_level(logging.INFO):
            returned, _ = _bounded(fifos[0], one_event_each)
    finally:
        watcher.executor.shutdown(wait=True)

    assert returned
    assert len(_lines(caplog)) == 8
    assert len(ingestor._skipped) <= 3 and len(watcher._skipped) <= 3


def test_an_entry_that_becomes_a_file_before_the_ingest_waits_for_stability(
        tmp_path, caplog, monkeypatch, fast_stability_poll):
    """A FIFO is swapped for a regular file between the watcher's look and the
    ingest's: that file is new, and goes through the quiet-window wait like
    any other before it is imported."""
    monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
    folder, ingestor, _, organize = _import_folder(tmp_path)
    fifo = _fifo(folder / "Album", "x.flac")
    order = []
    organize.side_effect = lambda p: order.append("import") or ImportOutcome.IMPORTED
    real_wait = file_watcher.wait_until_ready
    monkeypatch.setattr(file_watcher, "wait_until_ready",
                        lambda path, **kw: order.append("wait") or real_wait(path, **kw))
    swapped = []

    def swap_then_ingest(path):
        if not swapped:
            swapped.append(path)
            fifo.unlink()
            fifo.write_bytes(b"audio")
        return ingestor.ingest_file(path, imported_dir=folder / ".imported")

    watcher = FileWatcher(folder, swap_then_ingest)

    def one_event():
        watcher.on_created(MagicMock(is_directory=False, src_path=str(fifo)))
        _drain(watcher)
        _drain(watcher)  # the new file, queued again by the first attempt

    try:
        returned, _ = _bounded(fifo, one_event)
    finally:
        watcher.executor.shutdown(wait=True)

    assert returned and swapped
    assert order == ["wait", "import"]
