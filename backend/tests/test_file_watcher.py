import threading
import time
from unittest.mock import MagicMock, patch

from app.services import file_watcher
from app.services.file_watcher import FileWatcher


def _start_appending(path, *, stop_event: threading.Event, interval_s: float = 0.01):
    """
    Background writer used for wait/stability tests.
    Continually appends to the file to ensure size changes between checks.
    """
    while not stop_event.is_set():
        with open(path, "ab") as f:
            f.write(b"x")
        time.sleep(interval_s)


def _delete_after_delay(path, *, delay_s: float = 0.02):
    time.sleep(delay_s)
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def test_start_file_watcher_is_idempotent(tmp_path):
    """Calling start twice should not create/schedule/start multiple observers."""
    watcher = FileWatcher(tmp_path)

    observer = MagicMock()
    observer.is_alive.return_value = True

    with patch("app.services.file_watcher.Observer", return_value=observer) as Observer:
        watcher.start_file_watcher()
        watcher.start_file_watcher()

    Observer.assert_called_once()
    observer.schedule.assert_called_once()
    observer.start.assert_called_once()


def test_start_file_watcher_recreates_observer_if_dead(tmp_path):
    """If an existing observer is not alive, start should create a new one."""
    watcher = FileWatcher(tmp_path)

    dead_observer = MagicMock()
    dead_observer.is_alive.return_value = False
    watcher.observer = dead_observer

    new_observer = MagicMock()
    new_observer.is_alive.return_value = True

    with patch("app.services.file_watcher.Observer", return_value=new_observer):
        watcher.start_file_watcher()

    assert watcher.observer is new_observer

def test_stop_file_watcher_is_safe_when_not_started(tmp_path):
    """Test that stop_file_watcher can be called safely even if not started"""
    watcher = FileWatcher(tmp_path)
    # Should not raise an exception
    watcher.stop_file_watcher()
    assert watcher.observer is None

def test_stop_file_watcher_stops_running_watcher(tmp_path):
    """stop should stop/join and then clear observer reference."""
    watcher = FileWatcher(tmp_path)

    observer = MagicMock()
    watcher.observer = observer

    watcher.stop_file_watcher()

    observer.stop.assert_called_once()
    observer.join.assert_called_once()
    assert watcher.observer is None

def test_can_open_empty_file_for_read(tmp_path):
    test_file = tmp_path / "test.txt"
    test_file.touch()
    assert file_watcher.can_open_for_read(str(test_file))

def test_can_open_nonempty_file_for_read(tmp_path):
    test_file = tmp_path / "test.txt"
    test_file.write_text("test")
    assert file_watcher.can_open_for_read(str(test_file))

def test_cannot_open_deleted_file_for_read(tmp_path):
    test_file = tmp_path / "test.txt"
    test_file.touch()
    test_file.unlink()
    assert not file_watcher.can_open_for_read(str(test_file))

def test_cannot_open_directory_for_read(tmp_path):
    test_dir = tmp_path / "test/directory"
    test_dir.mkdir(parents=True)
    assert not file_watcher.can_open_for_read(str(test_dir))

def test_cannot_open_file_that_does_not_exist_for_read(tmp_path):
    assert not file_watcher.can_open_for_read(str(tmp_path / "this/file/does/not/exist.txt"))

# ========== wait_until_stable (behavior-focused) ==========

def test_wait_until_stable_returns_true_for_stable_file(tmp_path):
    """A file that isn't being written to should become stable quickly."""
    test_file = tmp_path / "test.txt"
    test_file.write_text("stable content")
    assert file_watcher.wait_until_stable(str(test_file), timeout=0.5, interval=0.01)

def test_wait_until_stable_returns_false_while_file_is_still_being_written(tmp_path):
    """If the file keeps changing until the timeout, it should return False."""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")

    # Make the test deterministic: mutate the file between every stability poll.
    real_sleep = time.sleep

    def mutate_on_sleep(seconds):
        with open(test_file, "ab") as f:
            f.write(b"x")
        real_sleep(min(seconds, 0.005))

    with patch("app.services.file_watcher.time.sleep", side_effect=mutate_on_sleep):
        assert not file_watcher.wait_until_stable(str(test_file), timeout=0.05, interval=0.01)

def test_wait_until_stable_returns_false_for_file_that_does_not_exist(tmp_path):
    """Test that wait_until_stable returns False for non-existent file"""
    assert not file_watcher.wait_until_stable(
        str(tmp_path / "this/file/does/not/exist.txt"), timeout=0.1, interval=0.01
    )

def test_wait_until_stable_returns_false_for_directory(tmp_path):
    """Test that wait_until_stable returns False for directory"""
    test_dir = tmp_path / "test/directory"
    test_dir.mkdir(parents=True)
    assert not file_watcher.wait_until_stable(str(test_dir), timeout=0.1, interval=0.01)

def test_wait_until_stable_returns_false_when_file_disappears_during_check(tmp_path):
    """Test that wait_until_stable returns False if file disappears during check"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")

    real_sleep = time.sleep
    deleted = False

    def delete_on_sleep(seconds):
        nonlocal deleted
        if not deleted:
            deleted = True
            test_file.unlink()
        real_sleep(min(seconds, 0.005))

    with patch("app.services.file_watcher.time.sleep", side_effect=delete_on_sleep):
        assert not file_watcher.wait_until_stable(str(test_file), timeout=0.2, interval=0.01)

# ========== New Tests for wait_until_ready ==========

def test_wait_until_ready_returns_true_for_ready_file(tmp_path):
    """Test that wait_until_ready returns True for a stable, readable file"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("ready content")

    # Speed up the stability check without changing the underlying behavior.
    real_wait_until_stable = file_watcher.wait_until_stable

    def fast_wait_until_stable(path):
        return real_wait_until_stable(path, timeout=0.2, interval=0.01)

    with patch("app.services.file_watcher.wait_until_stable", side_effect=fast_wait_until_stable):
        assert file_watcher.wait_until_ready(str(test_file))

def test_wait_until_ready_returns_false_when_file_not_stable(tmp_path):
    """Test that wait_until_ready returns False when file doesn't stabilize"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")

    # Composition test: if stability check says "not stable", readiness should be False.
    with patch("app.services.file_watcher.wait_until_stable", return_value=False):
        assert not file_watcher.wait_until_ready(str(test_file))

def test_wait_until_ready_returns_false_when_file_cannot_be_opened(tmp_path):
    """Test that wait_until_ready returns False when file can't be opened for read"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")
    
    # Mock can_open_for_read to return False
    with patch("app.services.file_watcher.can_open_for_read", return_value=False):
        real_wait_until_stable = file_watcher.wait_until_stable

        def fast_wait_until_stable(path):
            return real_wait_until_stable(path, timeout=0.2, interval=0.01)

        with patch("app.services.file_watcher.wait_until_stable", side_effect=fast_wait_until_stable):
            assert not file_watcher.wait_until_ready(str(test_file))

def test_wait_until_ready_returns_false_for_nonexistent_file(tmp_path):
    """Test that wait_until_ready returns False for non-existent file"""
    real_wait_until_stable = file_watcher.wait_until_stable

    def fast_wait_until_stable(path):
        return real_wait_until_stable(path, timeout=0.2, interval=0.01)

    with patch("app.services.file_watcher.wait_until_stable", side_effect=fast_wait_until_stable):
        assert not file_watcher.wait_until_ready(str(tmp_path / "nonexistent.txt"))

def test_process_file_after_stable_calls_handle_new_file_when_ready(tmp_path):
    """Test that process_file_after_stable calls handle_new_file when file is ready"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("ready content")

    # Exercise the real wait_until_ready (but make it fast).
    real_wait_until_stable = file_watcher.wait_until_stable

    def fast_wait_until_stable(path):
        return real_wait_until_stable(path, timeout=0.2, interval=0.01)

    with patch("app.services.file_watcher.wait_until_stable", side_effect=fast_wait_until_stable):
        with patch("app.services.file_watcher.handle_new_file") as mock_handle:
            result = file_watcher.process_file_after_stable(str(test_file))

    mock_handle.assert_called_once_with(str(test_file))
    assert result is True

def test_process_file_after_stable_does_not_call_handle_new_file_when_not_ready(tmp_path):
    """Test that process_file_after_stable doesn't call handle_new_file when file isn't ready"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")
    
    # Exercise the real wait_until_ready, but force the stability check to fail.
    with patch("app.services.file_watcher.wait_until_stable", return_value=False):
        with patch("app.services.file_watcher.handle_new_file") as mock_handle:
            result = file_watcher.process_file_after_stable(str(test_file))

    mock_handle.assert_not_called()
    assert result is False

# ========== New Tests for FileWatcher.on_created ==========

def test_file_watcher_on_created_ignores_directories(tmp_path):
    """Test that FileWatcher.on_created ignores directory events"""
    watcher = FileWatcher(tmp_path)
    event = MagicMock()
    event.is_directory = True
    event.src_path = "/some/directory"
    
    initial_processed_count = len(watcher.processed)
    
    watcher.on_created(event)
    
    # Should not add to processed set
    assert len(watcher.processed) == initial_processed_count
    assert "/some/directory" not in watcher.processed

def test_file_watcher_on_created_ignores_already_processed_files(tmp_path):
    """Test that FileWatcher.on_created ignores files already in processed set"""
    watcher = FileWatcher(tmp_path)
    event = MagicMock()
    event.is_directory = False
    event.src_path = "/some/file.txt"
    
    # Add to processed set first
    watcher.processed.add("/some/file.txt")
    initial_processed_count = len(watcher.processed)
    
    watcher.on_created(event)
    
    # Should not add again
    assert len(watcher.processed) == initial_processed_count

def test_file_watcher_on_created_submits_processing_for_new_file(tmp_path):
    """Test that FileWatcher.on_created submits processing for new files"""
    watcher = FileWatcher(tmp_path)
    event = MagicMock()
    event.is_directory = False
    event.src_path = "/some/new_file.txt"
    
    with patch.object(watcher.executor, "submit") as mock_submit:
        watcher.on_created(event)
        
        # Should add to processed set
        assert "/some/new_file.txt" in watcher.processed
        
        # Should submit processing (we don't care which callable, only that it's scheduled for this path)
        mock_submit.assert_called_once()
        assert mock_submit.call_args[0][1] == "/some/new_file.txt"