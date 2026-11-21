import logging
import os
import stat
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from pathlib import Path
from typing import Callable

from app.core.operator_log import operator_logger
from app.services.import_outcome import (
    EntryMemory, entry_key, expected_special_entry, file_signature, open_regular_file,
)
from app.services.ingestion import _in_folder, is_archive, is_macos_companion, is_music_file
from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

logger = logging.getLogger(__name__)


def is_import_candidate(path: Path) -> bool:
    """The name rule for the import folder: only audio files and archives."""
    return is_music_file(path) or is_archive(path)


def under_dot_folder(path: Path, root: Path) -> bool:
    """True when a directory component of ``path`` below ``root`` starts with a dot."""
    try:
        rel = Path(path).relative_to(root)
    except ValueError:
        return False
    return any(part.startswith(".") for part in rel.parts[:-1])


class FileWatcher(FileSystemEventHandler):
    def __init__(
        self,
        import_dir: Path,
        on_file: Callable[[Path], bool],
        *,
        stop_event: threading.Event | None = None,
    ):
        self.import_dir = import_dir
        self.on_file = on_file
        self.observer = None
        self.executor = ThreadPoolExecutor(max_workers=8)
        # Track already-seen paths to avoid double-processing duplicate FS events.
        self.processed: set[Path] = set()
        self._stopping = stop_event or threading.Event()
        self._futures: set = set()
        self._submit_lock = threading.Lock()
        # path -> signature of a file an attempt left in the folder unchanged
        self._left_behind: dict[Path, tuple[int, int]] = {}
        # Entries that are no regular file, handed over once (by their entry_key).
        self._skipped = EntryMemory()

    def on_created(self, event):
        if event.is_directory:
            return

        self._on_event(Path(os.fsdecode(event.src_path)), created=True)

    def on_moved(self, event):
        """A rename into (or inside) the folder, e.g. ``.a.tmp`` -> ``a.flac``,
        is a create at the destination."""
        if event.is_directory:
            return
        dest = Path(os.fsdecode(event.dest_path))
        if dest.is_relative_to(self.import_dir):
            self._on_event(dest)

    def on_modified(self, event):
        """Retry a file whose earlier import failed (e.g. a slow copy that
        passed the stability check early). In-flight paths are ignored by
        ``_submit_new``."""
        if event.is_directory:
            return
        self._on_event(Path(os.fsdecode(event.src_path)))

    def _on_event(self, path: Path, *, created: bool = False) -> None:
        """Event entry point: ignore names that are neither audio nor archives
        (``scan_existing`` shares that name rule) and, for modify/move events,
        a file an earlier attempt left behind that has not changed since
        (the scan does not apply that rule). A create event is a new file at
        the path, so it is always attempted. An entry that is no regular file,
        handed over before and still the same entry, is not attempted again."""
        if not is_import_candidate(path):
            return
        if path in self._skipped:
            if self._skipped.knows(path, entry_key(path)):
                return
            self._skipped.forget(path)
        left = self._left_behind.get(path)
        if left is not None:
            if not created and file_signature(path) == left:
                return
            self._left_behind.pop(path, None)
        self._submit_new(path)

    def _submit_new(self, path: Path) -> None:
        """Mark ``path`` processed and queue it, unless already seen."""
        if under_dot_folder(path, self.import_dir):
            return
        if is_macos_companion(path):
            logger.debug("skipped a macOS companion file")
            return
        with self._submit_lock:
            if self._stopping.is_set() or path in self.processed:
                return
            self.processed.add(path)
            if not self._queue(path):
                self.processed.discard(path)

    def _queue(self, path: Path) -> bool:
        """Queue ``process_file_after_stable``; False if the executor is shut down."""
        try:
            future = self.executor.submit(self.process_file_after_stable, path)
        except RuntimeError:
            return False
        self._futures.add(future)
        future.add_done_callback(self._futures.discard)
        return True

    def scan_existing(self, directory: Path | None = None) -> None:
        """Feed every existing entry but a folder under ``directory`` (default:
        the import dir) through the same path as a newly created file (a FIFO
        or a link too: the ingest says once why it is skipped); names that are
        neither audio nor archives are skipped."""
        root = directory or self.import_dir
        if not root.is_dir():
            return
        for path in sorted(p for p in root.rglob("*") if not p.is_dir()):
            if is_import_candidate(path):
                self._submit_new(path)

    def start_file_watcher(self):
        if self.observer is None or not self.observer.is_alive():
            observer = Observer()
            observer.schedule(self, str(self.import_dir), recursive=True)
            observer.start()
            # Kept only once it runs: stopping never meets an observer that never started.
            self.observer = observer
            operator_logger.info("File watcher started")

    def stop_file_watcher(self, timeout: float = 30.0):
        return stop_watchers([self], timeout)

    def handle_new_file(self, path: Path):
        return self.on_file(path)

    def process_file_after_stable(self, path: Path) -> bool:
        key = entry_key(path)
        if _is_special(key):
            # A FIFO, a link, a socket or a device: handed to the ingest at once,
            # never waited on or opened (a FIFO would hold this worker).
            token = expected_special_entry.set(key)
            try:
                self.handle_new_file(path)
            except Exception as exc:
                self._log_raised(path, exc)
                self.processed.discard(path)
                return False
            finally:
                expected_special_entry.reset(token)
            self.processed.discard(path)
            if entry_key(path) == key:
                self._skipped.remember(path, key)
            elif not self._stopping.is_set():
                self._submit_new(path)  # another entry now (a new file): the normal path, with its wait
            return True
        if not wait_until_ready(path, stop=self._stopping):
            # Not handled: forget it so a later scan feeds it again.
            self.processed.discard(path)
            return False
        if self._stopping.is_set():
            self.processed.discard(path)
            return False
        # Forget the path whatever the result: a new file later dropped at the
        # same path must be handled again.
        stable = file_signature(path)
        try:
            self.handle_new_file(path)
        except Exception as exc:
            self._log_raised(path, exc)
            self.processed.discard(path)
            return False
        # Modify events during the attempt were dropped while the path was in
        # ``processed``; a file still there but changed is tried again.
        after = file_signature(path)
        if after is not None and after == stable:
            self._left_behind[path] = after
        else:
            self._left_behind.pop(path, None)
        if (
            after is not None
            and after != stable
            and not self._stopping.is_set()
            and self._queue(path)
        ):
            return True
        self.processed.discard(path)
        # A modify event between that look and the discard was dropped: look once more.
        if file_signature(path) != after and not self._stopping.is_set():
            self._left_behind.pop(path, None)
            self._submit_new(path)
        return True

    def _log_raised(self, path: Path, exc: Exception) -> None:
        # Relative to the watched folder (it begins with the user's folder);
        # the traceback, whose error text may hold full paths, only at DEBUG.
        name = _in_folder(path, self.import_dir)
        logger.warning("import of %s raised %s", name, type(exc).__name__)
        logger.debug("import of %s raised %s", name, type(exc).__name__, exc_info=True)


def _is_special(key) -> bool:
    """Whether an ``entry_key`` is of something neither a regular file nor a
    folder (a link is not followed). A missing path (None) is False."""
    return key is not None and not (stat.S_ISREG(key[2]) or stat.S_ISDIR(key[2]))


# A file is complete only after its size and mtime stay unchanged this long
# (a slow copy can pause between chunks for about a second).
STABILITY_QUIET_WINDOW_S = 2.0


def wait_until_ready(path: Path, *, stop: threading.Event | None = None) -> bool:
    if not wait_until_stable(path, stop=stop):
        return False
    return can_open_for_read(path)


def wait_until_stable(
    path: str | Path,
    timeout: int = 60,
    interval: float = 0.2,
    *,
    quiet_window: float | None = None,
    stop: threading.Event | None = None,
    clock: Callable[[], float] = time.monotonic,
) -> bool:
    if quiet_window is None:
        quiet_window = STABILITY_QUIET_WINDOW_S
    operator_logger.debug("Starting stable check for %s", Path(path).name)

    start_time = clock()
    signature = None
    first_seen = start_time
    while clock() - start_time < timeout:
        if stop is not None and stop.is_set():
            return False
        try:
            st = os.stat(path)
        except OSError:
            # Missing, or permission errors / transient filesystem issues.
            return False
        if stat.S_ISDIR(st.st_mode):
            return False

        now = clock()
        current = (st.st_size, st.st_mtime_ns)
        if current != signature:
            signature = current
            first_seen = now
        elif now - first_seen >= quiet_window:
            operator_logger.debug("File %s is stable", Path(path).name)
            return True

        if stop is not None:
            if stop.wait(interval):
                return False
        else:
            time.sleep(interval)

    return False


def can_open_for_read(path: Path) -> bool:
    """Whether ``path`` is a regular file that opens for reading, found
    without waiting: never a FIFO, a device, a socket, a link or a folder."""
    try:
        with open_regular_file(path):
            return True
    except Exception:
        return False



def stop_watchers(watchers, timeout: float = 30.0) -> set:
    """Stop watchers together: all stop accepting work first, then all running
    ingests are drained against one deadline. Returns the ingests still running."""
    for watcher in watchers:
        watcher._stopping.set()
        if watcher.observer is not None:
            watcher.observer.stop()
            watcher.observer.join()
            watcher.observer = None
            operator_logger.info("File watcher stopped")
        watcher.executor.shutdown(wait=False, cancel_futures=True)
    pending = {f for w in watchers for f in list(w._futures) if not f.done()}
    not_done: set = set()
    if pending:
        logger.info("File watcher waiting for %d running ingest(s)", len(pending))
        _, not_done = wait(pending, timeout=timeout)
        if not_done:
            logger.warning(
                "File watcher stop timed out after %ss: %d ingest(s) still running",
                timeout,
                len(not_done),
            )
            return set(not_done)
    for watcher in watchers:
        watcher.executor.shutdown(wait=True)
    return set()
