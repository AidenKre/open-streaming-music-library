"""Live gate m-L-03 and m-L-05: which filesystem events feed an import.

- m-L-03: many copy tools write a temporary name and rename it into place. A
  move or rename whose destination is inside the watched folder is handled
  exactly like a create (same stability wait, ``processed`` set, executor,
  dot-folder rule).
- m-L-05: a slow copy can pass the stability check while incomplete; its
  import fails. A later modify event for a path that is not in flight submits
  it again, so the import is retried when the copy continues.
"""

import logging
import threading
from concurrent.futures import wait
from pathlib import Path

import pytest
from watchdog.events import (
    FileCreatedEvent,
    FileModifiedEvent,
    FileMovedEvent,
)

from app.services.file_watcher import FileWatcher

pytestmark = pytest.mark.usefixtures("fast_stability_poll")


class _Recorder:
    """``on_file`` that records each path and answers from ``results``;
    optionally blocks on ``gate`` so a test can act while a file is in flight."""

    def __init__(self, results=(True,), gate: threading.Event | None = None):
        self.calls: list[Path] = []
        self.results = list(results)
        self.gate = gate
        self.started = threading.Event()

    def __call__(self, path: Path) -> bool:
        self.calls.append(path)
        self.started.set()
        if self.gate is not None:
            assert self.gate.wait(5)
        return self.results.pop(0) if self.results else True


def _settle(watcher: FileWatcher) -> None:
    """Wait for every submitted import to finish."""
    wait(list(watcher._futures), timeout=10)


def _file(path: Path, data: bytes = b"audio") -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


@pytest.fixture
def make_watcher(tmp_path):
    watchers = []

    def make(on_file) -> FileWatcher:
        watcher = FileWatcher(tmp_path / "import", on_file)
        watcher.import_dir.mkdir(exist_ok=True)
        watchers.append(watcher)
        return watcher

    yield make
    for watcher in watchers:
        watcher.stop_file_watcher(timeout=5)


# m-L-03 ---------------------------------------------------------------------


def test_a_rename_inside_the_folder_is_imported_like_a_create(make_watcher):
    on_file = _Recorder()
    watcher = make_watcher(on_file)
    final = _file(watcher.import_dir / "Album" / "a4.flac")

    watcher.dispatch(
        FileMovedEvent(str(watcher.import_dir / "Album" / ".a4.tmp"), str(final))
    )
    _settle(watcher)

    assert on_file.calls == [final]
    assert final not in watcher.processed


def test_a_file_moved_in_from_outside_is_imported(make_watcher, tmp_path):
    on_file = _Recorder()
    watcher = make_watcher(on_file)
    final = _file(watcher.import_dir / "b.flac")

    watcher.dispatch(FileMovedEvent(str(tmp_path / "elsewhere" / "b.flac"), str(final)))
    _settle(watcher)

    assert on_file.calls == [final]


def test_a_rename_into_a_dot_folder_is_ignored(make_watcher):
    on_file = _Recorder()
    watcher = make_watcher(on_file)
    hidden = _file(watcher.import_dir / ".imported" / "c.zip")

    watcher.dispatch(FileMovedEvent(str(watcher.import_dir / "c.zip"), str(hidden)))
    _settle(watcher)

    assert on_file.calls == []


def test_a_move_out_of_the_folder_is_ignored(make_watcher, tmp_path):
    on_file = _Recorder()
    watcher = make_watcher(on_file)
    outside = _file(tmp_path / "music" / "d.flac")

    watcher.dispatch(FileMovedEvent(str(watcher.import_dir / "d.flac"), str(outside)))
    _settle(watcher)

    assert on_file.calls == []


def test_a_rename_to_a_path_in_flight_is_not_submitted_twice(make_watcher):
    gate = threading.Event()
    on_file = _Recorder(gate=gate)
    watcher = make_watcher(on_file)
    final = _file(watcher.import_dir / "e.flac")

    watcher.dispatch(FileCreatedEvent(str(final)))
    assert on_file.started.wait(5)
    watcher.dispatch(FileMovedEvent(str(watcher.import_dir / ".e.tmp"), str(final)))
    gate.set()
    _settle(watcher)

    assert on_file.calls == [final]


# m-L-05 ---------------------------------------------------------------------


def test_a_modify_after_a_failed_import_retries_it(make_watcher):
    on_file = _Recorder(results=(False, True))
    watcher = make_watcher(on_file)
    slow = _file(watcher.import_dir / "slow.flac", b"part")

    watcher.dispatch(FileCreatedEvent(str(slow)))
    _settle(watcher)
    assert on_file.calls == [slow]  # the early attempt failed

    slow.write_bytes(b"part and the rest")
    watcher.dispatch(FileModifiedEvent(str(slow)))
    _settle(watcher)

    assert on_file.calls == [slow, slow]


def test_a_modify_while_the_file_is_in_flight_is_not_submitted_again(make_watcher):
    gate = threading.Event()
    on_file = _Recorder(gate=gate)
    watcher = make_watcher(on_file)
    path = _file(watcher.import_dir / "f.flac")

    watcher.dispatch(FileCreatedEvent(str(path)))
    assert on_file.started.wait(5)
    watcher.dispatch(FileModifiedEvent(str(path)))
    gate.set()
    _settle(watcher)

    assert on_file.calls == [path]


def test_a_modify_under_a_dot_folder_is_ignored(make_watcher):
    on_file = _Recorder()
    watcher = make_watcher(on_file)
    hidden = _file(watcher.import_dir / ".imported" / "g.zip")

    watcher.dispatch(FileModifiedEvent(str(hidden)))
    _settle(watcher)

    assert on_file.calls == []


# Review r2 m-R2-04 -----------------------------------------------------------


def test_an_import_that_raises_is_logged_and_its_path_forgotten(make_watcher, caplog):
    """A raising ``on_file`` (a set-aside that hits PermissionError, an
    organizer error) used to leave its path in ``processed`` until restart."""
    calls = []

    def on_file(path):
        calls.append(path)
        if len(calls) == 1:
            raise PermissionError("set-aside refused")
        return True

    watcher = make_watcher(on_file)
    path = _file(watcher.import_dir / "h.zip")

    with caplog.at_level(logging.ERROR, logger="app.services.file_watcher"):
        watcher.dispatch(FileCreatedEvent(str(path)))
        _settle(watcher)

    assert path not in watcher.processed
    assert any(str(path) in r.getMessage() for r in caplog.records)
    assert "PermissionError" in caplog.text

    watcher.dispatch(FileCreatedEvent(str(path)))  # dropped again: handled again
    _settle(watcher)
    assert calls == [path, path]


# Review r2 m-R2-05 -----------------------------------------------------------


def test_two_threads_submitting_one_path_queue_it_once(make_watcher, monkeypatch):
    """The observer thread and a scan thread call ``_submit_new`` at once
    (DEV-M-12). The membership check and the add are one atomic step."""
    on_file = _Recorder()
    watcher = make_watcher(on_file)
    path = _file(watcher.import_dir / "i.flac")
    calls: list[int] = []
    first_in, second_in, release = threading.Event(), threading.Event(), threading.Event()
    attempted = threading.Event()

    class _SlowMembership(set):
        def __contains__(self, item):
            found = super().__contains__(item)
            calls.append(1)
            if len(calls) == 1:
                first_in.set()
                release.wait(5)  # hold the first check open until the second had its chance
            else:
                second_in.set()
            return found

    class _SpyLock:
        def __init__(self, real):
            self._real = real

        def __enter__(self):
            if first_in.is_set():
                attempted.set()  # the second submitter is now trying to enter
            self._real.acquire()

        def __exit__(self, *exc):
            self._real.release()

    watcher.processed = _SlowMembership()
    watcher._submit_lock = _SpyLock(watcher._submit_lock)
    t1 = threading.Thread(target=watcher._submit_new, args=(path,))
    t1.start()
    assert first_in.wait(5)
    t2 = threading.Thread(target=watcher._submit_new, args=(path,))
    t2.start()
    attempted.wait(1)  # unset only if the product stopped taking the lock at all
    # Without the lock the second thread reaches the membership check within
    # microseconds of attempting; with it, it stays blocked for this window.
    second_in.wait(0.1)
    release.set()
    for t in (t1, t2):
        t.join(5)
    _settle(watcher)

    assert on_file.calls == [path]


# Review r2 m-R2-07 -----------------------------------------------------------


@pytest.mark.parametrize("event_type", ["created", "modified", "moved"])
@pytest.mark.parametrize("name", [".DS_Store", "cover.jpg", "notes.txt", "._a.flac.part"])
def test_events_for_names_that_are_neither_audio_nor_archives_are_ignored(
    make_watcher, event_type, name
):
    on_file = _Recorder()
    watcher = make_watcher(on_file)
    path = _file(watcher.import_dir / "Album" / name)
    event = {
        "created": lambda: FileCreatedEvent(str(path)),
        "modified": lambda: FileModifiedEvent(str(path)),
        "moved": lambda: FileMovedEvent(str(watcher.import_dir / "x.tmp"), str(path)),
    }[event_type]()

    watcher.dispatch(event)
    _settle(watcher)

    assert on_file.calls == []


def test_a_modify_of_a_file_left_behind_unchanged_is_not_retried(make_watcher):
    """A refused duplicate (or a non-importable audio file) stays in the
    folder. A modify event that did not change its size or mtime (Finder,
    Spotlight, the organizer's own late event) is not a new attempt."""
    on_file = _Recorder(results=(False, True))
    watcher = make_watcher(on_file)
    dup = _file(watcher.import_dir / "dup.flac", b"same bytes")

    watcher.dispatch(FileCreatedEvent(str(dup)))
    _settle(watcher)
    watcher.dispatch(FileModifiedEvent(str(dup)))
    watcher.dispatch(FileMovedEvent(str(watcher.import_dir / ".dup.tmp"), str(dup)))
    _settle(watcher)

    assert on_file.calls == [dup]

    dup.write_bytes(b"different bytes")  # a real change is retried
    watcher.dispatch(FileModifiedEvent(str(dup)))
    _settle(watcher)

    assert on_file.calls == [dup, dup]


def test_a_scan_still_retries_a_file_left_behind(make_watcher):
    """Spec §6.3: files that previously failed are retried at the next scan."""
    on_file = _Recorder(results=(False, False))
    watcher = make_watcher(on_file)
    bad = _file(watcher.import_dir / "bad.flac", b"broken")

    watcher.dispatch(FileCreatedEvent(str(bad)))
    _settle(watcher)
    watcher.scan_existing()
    _settle(watcher)

    assert on_file.calls == [bad, bad]
