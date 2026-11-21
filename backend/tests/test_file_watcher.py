from __future__ import annotations

import logging
import os
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import app.services.file_watcher as file_watcher
from app.services.file_watcher import FileWatcher


class TestFileWatcherLifecycle:
    def test_start_file_watcher__already_running__is_idempotent(self, tmp_path: Path):
        watcher = FileWatcher(tmp_path, lambda path: True)

        observer = MagicMock()
        observer.is_alive.return_value = True

        with patch("app.services.file_watcher.Observer", return_value=observer) as Observer:
            watcher.start_file_watcher()
            watcher.start_file_watcher()

        Observer.assert_called_once()
        observer.schedule.assert_called_once()
        observer.start.assert_called_once()

    def test_start_file_watcher__existing_observer_dead__recreates_observer(self, tmp_path: Path):
        watcher = FileWatcher(tmp_path, lambda path: True)

        dead_observer = MagicMock()
        dead_observer.is_alive.return_value = False
        watcher.observer = dead_observer

        new_observer = MagicMock()
        new_observer.is_alive.return_value = True

        with patch("app.services.file_watcher.Observer", return_value=new_observer):
            watcher.start_file_watcher()

        assert watcher.observer is new_observer
        new_observer.schedule.assert_called_once()
        new_observer.start.assert_called_once()

    def test_stop_file_watcher__not_started__is_noop(self, tmp_path: Path):
        watcher = FileWatcher(tmp_path, lambda path: True)
        watcher.stop_file_watcher()
        assert watcher.observer is None

    def test_stop_file_watcher__started__stops_and_clears_observer(self, tmp_path: Path):
        watcher = FileWatcher(tmp_path, lambda path: True)
        observer = MagicMock()
        watcher.observer = observer

        watcher.stop_file_watcher()

        observer.stop.assert_called_once()
        observer.join.assert_called_once()
        assert watcher.observer is None


class TestCanOpenForRead:
    @pytest.mark.parametrize("content", [b"", b"hello"])
    def test_can_open_for_read__existing_file__returns_true(self, tmp_path: Path, content: bytes):
        path = tmp_path / "file.bin"
        path.write_bytes(content)
        assert file_watcher.can_open_for_read(path) is True

    def test_can_open_for_read__missing_path__returns_false(self, tmp_path: Path):
        assert file_watcher.can_open_for_read(tmp_path / "missing.bin") is False

    def test_can_open_for_read__directory__returns_false(self, tmp_path: Path):
        d = tmp_path / "dir"
        d.mkdir()
        assert file_watcher.can_open_for_read(d) is False

    def test_can_open_for_read__open_raises__returns_false(self, tmp_path: Path):
        path = tmp_path / "file.bin"
        path.write_bytes(b"x")

        with patch("app.services.import_outcome.open", side_effect=PermissionError):
            assert file_watcher.can_open_for_read(path) is False


class TestWaitUntilStable:
    def test_wait_until_stable__stable_file__returns_true(self, tmp_path: Path):
        path = tmp_path / "stable.txt"
        path.write_text("stable")
        # Review r2 m-R2-02: the quiet window is passed (default 2 s).
        assert file_watcher.wait_until_stable(path, timeout=1, interval=0.01, quiet_window=0.03) is True

    def test_wait_until_stable__file_keeps_changing_until_timeout__returns_false(self, tmp_path: Path):
        """Other-issues row 3: the timeout is longer than the quiet window, so
        only the writes keep the file from counting as stable (an unchanged
        file is stable here after 2 s, TestQuietWindow). The clock is fake."""
        path = tmp_path / "changing.bin"
        path.write_bytes(b"initial")
        clock = _FakeClock()
        writes = []

        def write_then_sleep(seconds: float):
            with open(path, "ab") as f:
                f.write(b"x")
            writes.append(seconds)
            clock.sleep(seconds)

        with patch("app.services.file_watcher.time.sleep", side_effect=write_then_sleep):
            assert file_watcher.wait_until_stable(
                path, timeout=10, interval=0.2, quiet_window=2.0, clock=clock
            ) is False

        assert clock.now >= 10  # it ran to the timeout
        assert len(writes) > 40  # the file changed on every poll
        assert path.stat().st_size == len(b"initial") + len(writes)

    def test_wait_until_stable__missing_file__returns_false(self, tmp_path: Path):
        assert file_watcher.wait_until_stable(tmp_path / "missing.txt", timeout=0.05, interval=0.01) is False

    def test_wait_until_stable__directory__returns_false(self, tmp_path: Path):
        d = tmp_path / "dir"
        d.mkdir()
        assert file_watcher.wait_until_stable(d, timeout=0.05, interval=0.01) is False

    def test_wait_until_stable__file_deleted_during_check__returns_false(self, tmp_path: Path):
        path = tmp_path / "maybe_deleted.txt"
        path.write_text("content")

        real_sleep = time.sleep
        deleted = False

        def delete_on_sleep(seconds: float):
            nonlocal deleted
            if not deleted:
                deleted = True
                path.unlink(missing_ok=True)
            real_sleep(min(seconds, 0.001))

        with patch("app.services.file_watcher.time.sleep", side_effect=delete_on_sleep):
            assert file_watcher.wait_until_stable(path, timeout=0.2, interval=0.01) is False

    def test_wait_until_stable__permission_error_on_stat__returns_false(self, tmp_path: Path):
        path = tmp_path / "file.bin"
        path.write_bytes(b"x")

        real_stat = os.stat

        def denied(target, *args, **kwargs):
            if os.fspath(target) == str(path):
                raise PermissionError(13, "denied")
            return real_stat(target, *args, **kwargs)

        with patch("app.services.file_watcher.os.stat", side_effect=denied):
            assert file_watcher.wait_until_stable(path, timeout=0.2, interval=0.01) is False


class TestWaitUntilReady:
    def test_wait_until_ready__stable_and_readable__returns_true(self, tmp_path: Path):
        path = tmp_path / "file.bin"
        path.write_bytes(b"x")

        with patch("app.services.file_watcher.wait_until_stable", return_value=True), patch(
            "app.services.file_watcher.can_open_for_read", return_value=True
        ):
            assert file_watcher.wait_until_ready(path) is True

    def test_wait_until_ready__not_stable__returns_false(self, tmp_path: Path):
        path = tmp_path / "file.bin"
        path.write_bytes(b"x")

        with patch("app.services.file_watcher.wait_until_stable", return_value=False):
            assert file_watcher.wait_until_ready(path) is False

    def test_wait_until_ready__stable_but_not_readable__returns_false(self, tmp_path: Path):
        path = tmp_path / "file.bin"
        path.write_bytes(b"x")

        with patch("app.services.file_watcher.wait_until_stable", return_value=True), patch(
            "app.services.file_watcher.can_open_for_read", return_value=False
        ):
            assert file_watcher.wait_until_ready(path) is False


class TestProcessFileAfterStable:
    def test_process_file_after_stable__ready__calls_callback_and_returns_true(self, tmp_path: Path):
        path = tmp_path / "ready.bin"
        path.write_bytes(b"x")

        on_file = MagicMock(return_value=True)
        watcher = FileWatcher(tmp_path, on_file)

        with patch("app.services.file_watcher.wait_until_ready", return_value=True):
            assert watcher.process_file_after_stable(path) is True

        on_file.assert_called_once_with(path)

    def test_process_file_after_stable__not_ready__does_not_call_callback_and_returns_false(self, tmp_path: Path):
        path = tmp_path / "not_ready.bin"
        path.write_bytes(b"x")

        on_file = MagicMock(return_value=True)
        watcher = FileWatcher(tmp_path, on_file)

        with patch("app.services.file_watcher.wait_until_ready", return_value=False):
            assert watcher.process_file_after_stable(path) is False

        on_file.assert_not_called()


class TestOnCreated:
    def test_on_created__directory_event__ignored(self, tmp_path: Path):
        watcher = FileWatcher(tmp_path, lambda path: True)
        event = MagicMock()
        event.is_directory = True
        event.src_path = "/some/directory"

        with patch.object(watcher.executor, "submit") as submit:
            watcher.on_created(event)

        submit.assert_not_called()
        assert watcher.processed == set()

    def test_on_created__already_processed_path__ignored(self, tmp_path: Path):
        watcher = FileWatcher(tmp_path, lambda path: True)
        already = Path("/some/file.txt")
        watcher.processed.add(already)

        event = MagicMock()
        event.is_directory = False
        event.src_path = str(already)

        with patch.object(watcher.executor, "submit") as submit:
            watcher.on_created(event)

        submit.assert_not_called()
        assert watcher.processed == {already}

    def test_on_created__new_file__scheduled_and_marked_processed(self, tmp_path: Path):
        watcher = FileWatcher(tmp_path, lambda path: True)

        event = MagicMock()
        event.is_directory = False
        event.src_path = "/some/new_file.mp3"
        expected_path = Path(event.src_path)

        with patch.object(watcher.executor, "submit") as submit:
            watcher.on_created(event)

        assert expected_path in watcher.processed
        submit.assert_called_once()
        assert submit.call_args[0][0] == watcher.process_file_after_stable
        assert submit.call_args[0][1] == expected_path

class TestStopDrainsTheExecutor:
    """Review r1 m-R1-03: stopping the watcher also stops its ingest work.

    Queued work is cancelled, a running ingest is waited for (bounded and
    logged), and a file still waiting to become stable is never handled once
    the watcher is stopping. ``shutdown_event`` releases the instance lock
    only after this returns, so no ingest outlives the lock."""

    @staticmethod
    def _alive(watcher):
        return [t for t in watcher.executor._threads if t.is_alive()]

    def test_stop_waits_for_a_running_ingest_and_leaves_no_thread(self, tmp_path: Path):
        import threading

        started, proceed, handled = threading.Event(), threading.Event(), []

        def on_file(path):
            started.set()
            assert proceed.wait(5)
            handled.append(path)
            return True

        watcher = FileWatcher(tmp_path, on_file)
        path = tmp_path / "song.mp3"
        with patch("app.services.file_watcher.wait_until_ready", return_value=True):
            watcher._submit_new(path)
            assert started.wait(5)
            stopper = threading.Thread(target=watcher.stop_file_watcher)
            stopper.start()
            stopper.join(0.2)  # negative probe: stop must still be waiting
            assert stopper.is_alive()
            proceed.set()
            stopper.join(5)

        assert not stopper.is_alive()
        assert handled == [path]
        assert self._alive(watcher) == []

    def test_stop_cancels_work_that_has_not_started(self, tmp_path: Path):
        import threading

        running, proceed, handled = threading.Semaphore(0), threading.Event(), []

        def on_file(path):
            running.release()
            assert proceed.wait(5)
            handled.append(path)
            return True

        watcher = FileWatcher(tmp_path, on_file)
        paths = [tmp_path / f"{i:02d}.mp3" for i in range(12)]
        with patch("app.services.file_watcher.wait_until_ready", return_value=True) as ready:
            for path in paths:
                watcher._submit_new(path)
            futures = list(watcher._futures)
            # The pool runs exactly max_workers at once; each blocks on `proceed`,
            # so wait for precisely that many starts (no negative-window wait).
            started = watcher.executor._max_workers
            for _ in range(started):
                assert running.acquire(timeout=5)
            assert 0 < started < len(paths)
            stopper = threading.Thread(target=watcher.stop_file_watcher)
            stopper.start()
            # Stop cancels every queued item while the running ones still work
            # (the stopping flag alone would also keep them from importing, so
            # the cancellation itself is what is checked).
            deadline = time.monotonic() + 5
            while sum(f.cancelled() for f in futures) < len(paths) - started:
                assert time.monotonic() < deadline, "stop left queued work in the pool"
                time.sleep(0.001)
            proceed.set()
            stopper.join(5)

        assert not stopper.is_alive()
        assert len(handled) == started
        assert ready.call_count == started  # queued items never began their wait
        assert self._alive(watcher) == []

    def test_a_file_that_becomes_ready_after_stop_is_not_handled(self, tmp_path: Path, caplog):
        import logging
        import threading

        waiting, ready = threading.Event(), threading.Event()
        on_file = MagicMock(return_value=True)

        def slow_ready(path, *, stop=None):
            waiting.set()
            assert ready.wait(5)
            return True

        watcher = FileWatcher(tmp_path, on_file)
        with patch("app.services.file_watcher.wait_until_ready", side_effect=slow_ready):
            watcher._submit_new(tmp_path / "song.mp3")
            assert waiting.wait(5)
            with caplog.at_level(logging.WARNING):
                watcher.stop_file_watcher(timeout=0.1)  # bounded: returns while it waits
            assert "still running" in caplog.text
            ready.set()
            watcher.executor.shutdown(wait=True)

        on_file.assert_not_called()


class _FakeClock:
    """A monotonic clock that only moves when the code under test sleeps.
    ``events`` maps a time to a callback run once the clock reaches it (a
    writer appending, a touch)."""

    def __init__(self, events=None):
        self.now = 0.0
        self.events = sorted((events or {}).items())

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now = round(self.now + seconds, 6)
        while self.events and self.events[0][0] <= self.now:
            _, action = self.events.pop(0)
            action()


class TestQuietWindow:
    """Review r2 m-R2-02 / live m-L-07 (decision DEV-M-14): a file counts as
    complete only after about 2 s with its size and modification time
    unchanged, so a copy that pauses for longer than one poll is not taken
    mid-copy. The clock and the interval are injected; nothing really sleeps."""

    @staticmethod
    def _wait(path, clock, **kwargs):
        with patch("app.services.file_watcher.time.sleep", side_effect=clock.sleep):
            return file_watcher.wait_until_stable(path, clock=clock, **kwargs)

    def test_the_window_is_two_seconds(self):
        assert file_watcher.STABILITY_QUIET_WINDOW_S == 2.0

    def test_an_unchanged_file_is_stable_only_after_the_whole_window(self, tmp_path: Path):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x" * 10)
        clock = _FakeClock()

        assert self._wait(path, clock, timeout=60, interval=0.2) is True

        assert 2.0 <= clock.now <= 2.2 + 1e-9

    def test_a_copy_that_pauses_longer_than_a_poll_is_not_taken_mid_copy(self, tmp_path: Path):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x" * 10)

        def append():
            with open(path, "ab") as f:
                f.write(b"y" * 10)

        # The live repro: chunks with 1 s pauses (the old check passed at 0.2 s).
        clock = _FakeClock({1.0: append, 2.0: append, 3.0: append})

        assert self._wait(path, clock, timeout=60, interval=0.2) is True

        assert path.stat().st_size == 40
        assert clock.now >= 3.0 + 2.0

    def test_a_modification_time_change_alone_restarts_the_window(self, tmp_path: Path):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x" * 10)
        start_ns = path.stat().st_mtime_ns

        def touch():
            os.utime(path, ns=(start_ns + 5_000_000, start_ns + 5_000_000))

        clock = _FakeClock({1.5: touch})

        assert self._wait(path, clock, timeout=60, interval=0.2) is True

        assert path.stat().st_size == 10
        assert clock.now >= 1.5 + 2.0

    def test_a_file_that_never_goes_quiet_times_out(self, tmp_path: Path):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x")

        def append():
            with open(path, "ab") as f:
                f.write(b"y")

        clock = _FakeClock({t / 10: append for t in range(1, 200, 5)})

        assert self._wait(path, clock, timeout=10, interval=0.2) is False

    def test_the_window_is_injectable(self, tmp_path: Path):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x")
        clock = _FakeClock()

        assert self._wait(path, clock, timeout=60, interval=0.1, quiet_window=0.5) is True

        assert 0.5 <= clock.now <= 0.6 + 1e-9

    def test_the_stop_flag_ends_the_wait_at_once(self, tmp_path: Path):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x")
        stop = threading.Event()
        stop.set()
        clock = _FakeClock()

        assert file_watcher.wait_until_stable(path, interval=0.2, stop=stop, clock=clock) is False

        assert clock.now == 0.0

    def test_a_stop_during_the_wait_ends_it(self, tmp_path: Path):
        """The watcher's stop flag interrupts a file still in its quiet
        window (m-R2-03): the wait does not run to the end of the window."""
        path = tmp_path / "a.flac"
        path.write_bytes(b"x")
        stop = threading.Event()
        clock = _FakeClock()
        waits = []

        class _Stop:
            def is_set(self):
                return stop.is_set()

            def wait(self, seconds):
                waits.append(seconds)
                clock.sleep(seconds)
                if clock.now >= 1.0:
                    stop.set()
                return stop.is_set()

        assert file_watcher.wait_until_stable(path, interval=0.2, stop=_Stop(), clock=clock) is False

        assert waits and all(w == 0.2 for w in waits)
        assert clock.now < 2.0

    def test_the_watcher_passes_its_stop_flag_to_the_wait(self, tmp_path: Path):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x")
        watcher = file_watcher.FileWatcher(import_dir=tmp_path, on_file=MagicMock())
        seen = {}

        def ready(p, *, stop=None):
            seen["stop"] = stop
            return False

        with patch("app.services.file_watcher.wait_until_ready", side_effect=ready):
            watcher.process_file_after_stable(path)

        assert seen["stop"] is watcher._stopping


class TestAFileThatChangedDuringItsAttemptIsTriedAgain:
    """Review r2 m-R2-02: a modify event for a path in flight is dropped, so
    the watcher itself re-stats the file after an attempt. Changed since the
    stability wait → submitted again; unchanged or gone → not."""

    @staticmethod
    def _run(tmp_path, on_file):
        path = tmp_path / "a.flac"
        path.write_bytes(b"x")
        watcher = FileWatcher(import_dir=tmp_path, on_file=on_file)
        watcher.processed.add(path)
        with (
            patch("app.services.file_watcher.wait_until_ready", return_value=True),
            patch.object(watcher.executor, "submit") as submit,
        ):
            watcher.process_file_after_stable(path)
        watcher.executor.shutdown(wait=True)
        return path, watcher, submit

    def test_a_file_that_grew_during_the_attempt_is_submitted_again(self, tmp_path: Path):
        def attempt_while_the_copy_goes_on(path):
            with open(path, "ab") as f:
                f.write(b"more")
            return False

        path, watcher, submit = self._run(tmp_path, attempt_while_the_copy_goes_on)

        submit.assert_called_once_with(watcher.process_file_after_stable, path)
        assert path in watcher.processed

    def test_an_unchanged_file_left_behind_is_not_submitted_again(self, tmp_path: Path):
        path, watcher, submit = self._run(tmp_path, MagicMock(return_value=False))

        submit.assert_not_called()
        assert path not in watcher.processed

    def test_a_file_that_was_imported_away_is_not_submitted_again(self, tmp_path: Path):
        path, watcher, submit = self._run(tmp_path, lambda p: p.unlink() or True)

        submit.assert_not_called()
        assert path not in watcher.processed

    def test_a_change_announced_while_the_attempt_ends_is_not_lost(self, tmp_path: Path):
        """The copy resumes after the attempt's last look at the file and
        before the path is released: its modify event meets the path still in
        flight and is dropped. The watcher looks once more after releasing it."""
        path = tmp_path / "a.flac"
        path.write_bytes(b"x")
        watcher = FileWatcher(import_dir=tmp_path, on_file=MagicMock(return_value=False))
        watcher.processed.add(path)
        real_signature = file_watcher.file_signature
        looks = []

        def signature_then_the_copy_resumes(p):
            looks.append(p)
            seen = real_signature(p)
            if len(looks) == 2:  # the look after the attempt
                with open(p, "ab") as f:
                    f.write(b"more")
                watcher.on_modified(MagicMock(is_directory=False, src_path=str(p)))
            return seen

        with (
            patch("app.services.file_watcher.wait_until_ready", return_value=True),
            patch("app.services.file_watcher.file_signature", signature_then_the_copy_resumes),
            patch.object(watcher.executor, "submit") as submit,
        ):
            watcher.process_file_after_stable(path)
        watcher.executor.shutdown(wait=True)

        submit.assert_called_once_with(watcher.process_file_after_stable, path)
        assert path in watcher.processed


@pytest.mark.usefixtures("fast_stability_poll")
class TestTheStartupScanUsesTheNameRuleOfNewFiles:
    """Owner's decision 9 (b), 2026-11-17: a file already in an import folder
    at start that is neither audio nor an archive is skipped quietly, by the
    same name rule a newly created file gets (``_on_event``). Audio files and
    archives already there are still imported; dot folders and macOS ``._``
    companions are skipped as before."""

    @staticmethod
    def _tree(root: Path, *names: str) -> list[Path]:
        paths = []
        for name in names:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"bytes of " + name.encode())
            paths.append(path)
        return paths

    def test_files_that_are_neither_audio_nor_archives_are_not_attempted(
        self, tmp_path: Path, capsys, caplog
    ):
        root = tmp_path / "import"
        imported = self._tree(root, "01.flac", "Album/02.MP3", "box.zip", "Album/set.tar.gz")
        other = self._tree(root, "cover.jpg", "album.cue", "notes.txt", ".DS_Store",
                           "Album/folder.png", "Album/rip.log", "Album/no-extension")
        skipped = self._tree(root, "._01.flac", ".imported/old.zip", ".hidden/03.flac")
        seen: list[Path] = []
        watcher = FileWatcher(import_dir=root, on_file=lambda p: seen.append(p) or True)

        with caplog.at_level(logging.DEBUG):
            watcher.scan_existing()
            watcher.executor.shutdown(wait=True)

        assert sorted(seen) == sorted(imported)
        assert watcher.processed == set()
        # Quiet: no stability wait was started for them and no line names them.
        printed = capsys.readouterr().out
        logged = "\n".join(r.getMessage() for r in caplog.records)
        for path in other + skipped:
            assert path.name not in printed
            assert path.name not in logged  # the stability wait logs a file's name
        assert all(p.read_bytes() == b"bytes of " + p.relative_to(root).as_posix().encode()
                   for p in other + skipped)

    def test_a_scan_of_one_folder_uses_the_same_rule(self, tmp_path: Path):
        """The signup scan of one user's folder (``scan_existing(folder)``)."""
        root = tmp_path / "import-users"
        sams = self._tree(root, "sam/a.flac", "sam/x/b.zip")
        self._tree(root, "sam/cover.jpg", "sam/x/album.cue", "alex/c.flac")
        seen: list[Path] = []
        watcher = FileWatcher(import_dir=root, on_file=lambda p: seen.append(p) or True)

        watcher.scan_existing(root / "sam")
        watcher.executor.shutdown(wait=True)

        assert sorted(seen) == sorted(sams)

    def test_at_start_the_operator_log_names_only_what_was_imported(
        self, tmp_path: Path, monkeypatch, caplog
    ):
        """Through a real ``Ingestor``: before decision 9 (b) every start logged
        ``import failed: <path> (not_audio)`` for ``cover.jpg`` and
        ``album.cue``; now neither is attempted, while the audio file and the
        archive are imported as before."""
        import zipfile

        from app.services import ingestion
        from app.services.import_outcome import ImportOutcome
        from app.services.ingestion import Ingestor, IngestorContext

        monkeypatch.setattr(ingestion, "does_music_pass_quick_check", lambda path: True)
        organized: list[str] = []
        workspace = tmp_path / "workspace"
        workspace.mkdir()
        ingestor = Ingestor(IngestorContext(
            workspace_dir=workspace,
            organize_function=lambda p: organized.append(p.name) or ImportOutcome.IMPORTED))
        root = tmp_path / "import"
        cover, cue, _flac = self._tree(root, "cover.jpg", "album.cue", "01.flac")
        with zipfile.ZipFile(root / "box.zip", "w") as z:
            z.writestr("Box/a.flac", b"audio-a")
        watcher = FileWatcher(
            import_dir=root,
            on_file=lambda p: ingestor.ingest_file(p, imported_dir=root / ".imported"),
        )

        with caplog.at_level(logging.DEBUG):
            watcher.scan_existing()
            watcher.executor.shutdown(wait=True)

        assert sorted(organized) == ["01.flac", "a.flac"]
        assert not (root / "box.zip").exists()  # every audio file imported: deleted (DEV-M-10)
        assert cover.exists() and cue.exists()  # left where they are
        assert [r.getMessage() for r in caplog.records
                if "not_audio" in r.getMessage() or "import failed" in r.getMessage()] == []
