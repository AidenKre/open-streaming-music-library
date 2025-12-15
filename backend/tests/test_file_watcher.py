import pytest
from app.services.file_watcher import FileWatcher
from app.services import file_watcher
from unittest.mock import patch, MagicMock, call
from pathlib import Path
import time
import os

# ========== Refactored Existing Tests ==========

def test_start_file_watcher_is_idempotent(tmp_path):
    """Test that calling start_file_watcher multiple times is safe"""
    watcher = FileWatcher(tmp_path)
    
    # First call should start the watcher
    watcher.start_file_watcher()
    first_observer = watcher.observer
    
    # Second call should be safe (idempotent)
    watcher.start_file_watcher()
    second_observer = watcher.observer
    
    # Should reuse the same observer if it's still alive
    assert first_observer is second_observer
    
    # Cleanup
    watcher.stop_file_watcher()

def test_stop_file_watcher_is_safe_when_not_started(tmp_path):
    """Test that stop_file_watcher can be called safely even if not started"""
    watcher = FileWatcher(tmp_path)
    # Should not raise an exception
    watcher.stop_file_watcher()
    assert watcher.observer is None

def test_stop_file_watcher_stops_running_watcher(tmp_path):
    """Test that stop_file_watcher properly stops a running watcher"""
    watcher = FileWatcher(tmp_path)
    
    watcher.start_file_watcher()
    assert watcher.observer is not None
    
    watcher.stop_file_watcher()
    # After stop, observer should be None
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

# ========== Refactored wait_until_stable tests - instant and deterministic ==========

def test_wait_until_stable_returns_true_for_stable_file(tmp_path):
    """Test that wait_until_stable returns True for a file that doesn't change"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("stable content")
    
    # File should be stable immediately (no changes)
    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
        assert file_watcher.wait_until_stable(
            str(test_file), timeout=1, interval=0.1
        )

def test_wait_until_stable_returns_false_for_changing_file_size(tmp_path):
    """Test that wait_until_stable returns False when file size keeps changing"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")
    
    # Mock getsize to return different sizes each time (simulating changing file)
    # First call: 7 (initial), second: 10, third: 15, etc.
    with patch("app.services.file_watcher.os.path.getsize", side_effect=[7, 10, 15, 20]):
        with patch("app.services.file_watcher.os.path.getmtime", return_value=100):
            with patch("app.services.file_watcher.os.path.exists", return_value=True):
                with patch("app.services.file_watcher.os.path.isdir", return_value=False):
                    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
                        with patch("app.services.file_watcher.time.time", side_effect=[0, 0.1, 0.2, 0.3, 0.4, 0.5]):
                            # Should timeout because file keeps changing
                            assert not file_watcher.wait_until_stable(
                                str(test_file), timeout=0.5, interval=0.1
                            )

def test_wait_until_stable_returns_false_for_changing_file_mtime(tmp_path):
    """Test that wait_until_stable returns False when file mtime keeps changing"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")
    
    # Mock getmtime to return different times each time (simulating changing file)
    with patch("app.services.file_watcher.os.path.getsize", return_value=7):
        with patch("app.services.file_watcher.os.path.getmtime", side_effect=[100, 101, 102, 103]):
            with patch("app.services.file_watcher.os.path.exists", return_value=True):
                with patch("app.services.file_watcher.os.path.isdir", return_value=False):
                    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
                        with patch("app.services.file_watcher.time.time", side_effect=[0, 0.1, 0.2, 0.3, 0.4, 0.5]):
                            # Should timeout because file keeps changing
                            assert not file_watcher.wait_until_stable(
                                str(test_file), timeout=0.5, interval=0.1
                            )

def test_wait_until_stable_returns_false_for_file_that_does_not_exist(tmp_path):
    """Test that wait_until_stable returns False for non-existent file"""
    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
        assert not file_watcher.wait_until_stable(
            str(tmp_path / "this/file/does/not/exist.txt"), timeout=0.5, interval=0.1
        )

def test_wait_until_stable_returns_false_for_directory(tmp_path):
    """Test that wait_until_stable returns False for directory"""
    test_dir = tmp_path / "test/directory"
    test_dir.mkdir(parents=True)
    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
        assert not file_watcher.wait_until_stable(
            str(test_dir), timeout=0.5, interval=0.1
        )

def test_wait_until_stable_returns_false_when_file_disappears_during_check(tmp_path):
    """Test that wait_until_stable returns False if file disappears during check"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")
    
    # First check succeeds, second check raises FileNotFoundError
    # time.time() is called: once at start (0), once per loop iteration (0.1, 0.2)
    with patch("app.services.file_watcher.os.path.getsize", side_effect=[7, FileNotFoundError()]):
        with patch("app.services.file_watcher.os.path.getmtime", return_value=100):
            with patch("app.services.file_watcher.os.path.exists", return_value=True):
                with patch("app.services.file_watcher.os.path.isdir", return_value=False):
                    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
                        with patch("app.services.file_watcher.time.time", side_effect=[0, 0.1, 0.2]):
                            # Should return False when file disappears
                            assert not file_watcher.wait_until_stable(
                                str(test_file), timeout=1, interval=0.1
                            )

def test_wait_until_stable_returns_false_on_timeout(tmp_path):
    """Test that wait_until_stable returns False when file never stabilizes within timeout"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")
    
    # Mock to keep returning different sizes (file never stabilizes)
    with patch("app.services.file_watcher.os.path.getsize", side_effect=[7, 8, 9, 10, 11]):
        with patch("app.services.file_watcher.os.path.getmtime", return_value=100):
            with patch("app.services.file_watcher.os.path.exists", return_value=True):
                with patch("app.services.file_watcher.os.path.isdir", return_value=False):
                    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
                        # Time progresses: 0, 0.1, 0.2, 0.3, 0.4, 0.5 (timeout)
                        with patch("app.services.file_watcher.time.time", side_effect=[0, 0.1, 0.2, 0.3, 0.4, 0.5]):
                            # Should timeout
                            assert not file_watcher.wait_until_stable(
                                str(test_file), timeout=0.3, interval=0.1
                            )

def test_wait_until_stable_returns_true_after_multiple_checks(tmp_path):
    """Test that wait_until_stable returns True when file stabilizes after multiple checks"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")
    
    # File changes: 7 -> 10 -> 10 (stabilizes)
    with patch("app.services.file_watcher.os.path.getsize", side_effect=[7, 10, 10]):
        with patch("app.services.file_watcher.os.path.getmtime", side_effect=[100, 101, 101]):
            with patch("app.services.file_watcher.os.path.exists", return_value=True):
                with patch("app.services.file_watcher.os.path.isdir", return_value=False):
                    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
                        with patch("app.services.file_watcher.time.time", side_effect=[0, 0.1, 0.2, 0.3]):
                            # Should eventually return True when file stabilizes
                            assert file_watcher.wait_until_stable(
                                str(test_file), timeout=2, interval=0.1
                            )

# ========== New Tests for wait_until_ready ==========

def test_wait_until_ready_returns_true_for_ready_file(tmp_path):
    """Test that wait_until_ready returns True for a stable, readable file"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("ready content")
    
    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
        assert file_watcher.wait_until_ready(str(test_file))

def test_wait_until_ready_returns_false_when_file_not_stable(tmp_path):
    """Test that wait_until_ready returns False when file doesn't stabilize"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")
    
    # Mock wait_until_stable to return False
    with patch("app.services.file_watcher.wait_until_stable", return_value=False):
        assert not file_watcher.wait_until_ready(str(test_file))

def test_wait_until_ready_returns_false_when_file_cannot_be_opened(tmp_path):
    """Test that wait_until_ready returns False when file can't be opened for read"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")
    
    # Mock can_open_for_read to return False
    with patch("app.services.file_watcher.can_open_for_read", return_value=False):
        with patch("app.services.file_watcher.time.sleep"):  # Speed up test
            assert not file_watcher.wait_until_ready(str(test_file))

def test_wait_until_ready_returns_false_for_nonexistent_file(tmp_path):
    """Test that wait_until_ready returns False for non-existent file"""
    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
        assert not file_watcher.wait_until_ready(
            str(tmp_path / "nonexistent.txt")
        )

# ========== New Tests for process_file_after_stable ==========

def test_process_file_after_stable_calls_handle_new_file_when_ready(tmp_path):
    """Test that process_file_after_stable calls handle_new_file when file is ready"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("ready content")
    
    with patch("app.services.file_watcher.handle_new_file") as mock_handle:
        with patch("app.services.file_watcher.time.sleep"):  # Speed up test
            result = file_watcher.process_file_after_stable(str(test_file))
            
            # Should call handle_new_file
            mock_handle.assert_called_once_with(str(test_file))
            # Should return True (implicitly, since it doesn't return False)

def test_process_file_after_stable_does_not_call_handle_new_file_when_not_ready(tmp_path):
    """Test that process_file_after_stable doesn't call handle_new_file when file isn't ready"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("initial")
    
    # Mock wait_until_ready to return False
    with patch("app.services.file_watcher.wait_until_ready", return_value=False):
        with patch("app.services.file_watcher.handle_new_file") as mock_handle:
            result = file_watcher.process_file_after_stable(str(test_file))
            
            # Should not call handle_new_file
            mock_handle.assert_not_called()
            # Should return False
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
        
        # Should submit processing
        mock_submit.assert_called_once()
        # Check that it was called with process_file_after_stable and the path
        call_args = mock_submit.call_args
        assert call_args[0][0] == file_watcher.process_file_after_stable
        assert call_args[0][1] == "/some/new_file.txt"

# ========== New Tests for handle_new_file ==========

def test_handle_new_file_is_callable(tmp_path, capsys):
    """Test that handle_new_file can be called and executes without error"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")
    
    # Should not raise an exception
    file_watcher.handle_new_file(str(test_file))
    
    # Should print message (check output)
    captured = capsys.readouterr()
    assert "Handling new file" in captured.out
    assert str(test_file) in captured.out

# ========== Edge Case Tests ==========

def test_can_open_for_read_with_locked_file(tmp_path):
    """Test can_open_for_read behavior with a file that might be locked"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")
    
    # On most systems, we can't easily create a truly locked file in tests
    # But we can test that the function handles exceptions gracefully
    # by mocking open to raise an exception
    with patch("builtins.open", side_effect=PermissionError("Permission denied")):
        assert not file_watcher.can_open_for_read(str(test_file))

def test_wait_until_stable_handles_file_not_found_during_check(tmp_path):
    """Test that wait_until_stable handles FileNotFoundError during check loop"""
    test_file = tmp_path / "test.txt"
    test_file.write_text("content")
    
    # First check succeeds, second check raises FileNotFoundError
    # time.time() is called: once at start (0), once per loop iteration (0.1, 0.2)
    with patch("app.services.file_watcher.os.path.getsize", side_effect=[7, FileNotFoundError()]):
        with patch("app.services.file_watcher.os.path.getmtime", return_value=100):
            with patch("app.services.file_watcher.os.path.exists", return_value=True):
                with patch("app.services.file_watcher.os.path.isdir", return_value=False):
                    with patch("app.services.file_watcher.time.sleep"):  # Speed up test
                        with patch("app.services.file_watcher.time.time", side_effect=[0, 0.1, 0.2]):
                            assert not file_watcher.wait_until_stable(
                                str(test_file), timeout=1, interval=0.1
                            )
