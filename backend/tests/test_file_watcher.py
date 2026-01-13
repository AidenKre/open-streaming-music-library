from __future__ import annotations

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

        with patch("app.services.file_watcher.open", side_effect=PermissionError):
            assert file_watcher.can_open_for_read(path) is False


class TestWaitUntilStable:
    def test_wait_until_stable__stable_file__returns_true(self, tmp_path: Path):
        path = tmp_path / "stable.txt"
        path.write_text("stable")
        assert file_watcher.wait_until_stable(path, timeout=0.2, interval=0.01) is True

    def test_wait_until_stable__file_keeps_changing_until_timeout__returns_false(self, tmp_path: Path):
        path = tmp_path / "changing.bin"
        path.write_bytes(b"initial")

        real_sleep = time.sleep

        def mutate_on_sleep(seconds: float):
            with open(path, "ab") as f:
                f.write(b"x")
            real_sleep(min(seconds, 0.001))

        with patch("app.services.file_watcher.time.sleep", side_effect=mutate_on_sleep):
            assert file_watcher.wait_until_stable(path, timeout=0.05, interval=0.01) is False

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

        with patch("app.services.file_watcher.os.path.getsize", side_effect=PermissionError):
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
        event.src_path = "/some/new_file.txt"
        expected_path = Path(event.src_path)

        with patch.object(watcher.executor, "submit") as submit:
            watcher.on_created(event)

        assert expected_path in watcher.processed
        submit.assert_called_once()
        assert submit.call_args[0][0] == watcher.process_file_after_stable
        assert submit.call_args[0][1] == expected_path