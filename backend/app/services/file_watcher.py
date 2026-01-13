from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import time, os
from typing import Callable

class FileWatcher(FileSystemEventHandler):

    def __init__(self, import_dir: Path, on_file: Callable[[Path], bool]):
        self.import_dir = import_dir
        self.on_file = on_file
        self.observer = None
        self.executor = ThreadPoolExecutor(max_workers=4)
        # Track already-seen paths to avoid double-processing duplicate FS events.
        self.processed: set[Path] = set()

    def on_created(self, event):
        if event.is_directory:
            return

        path = Path(event.src_path)
        if path in self.processed:
            return

        self.processed.add(path)
        self.executor.submit(self.process_file_after_stable, path)

    def start_file_watcher(self):
        if self.observer is None or not self.observer.is_alive():
            self.observer = Observer()
            self.observer.schedule(self, self.import_dir, recursive=True)
            self.observer.start()
            print(f"File watcher started for {self.import_dir}")

    def stop_file_watcher(self):
        if self.observer is not None:
            self.observer.stop()
            self.observer.join()
            self.observer = None
            print("File watcher stopped")

    def handle_new_file(self, path: Path):
        print(f"Handling new file {path}")
        self.on_file(path)

    def process_file_after_stable(self, path: Path) -> bool:
        print(f"Processing file {path} after stable")
        if not wait_until_ready(path):
            return False
        self.handle_new_file(path)
        return True

def wait_until_ready(path: Path) -> bool:
    if not wait_until_stable(path):
        return False
    return can_open_for_read(path)

def wait_until_stable(path: str | Path, timeout: int = 60, interval: float = 0.2) -> bool:
    start_time = time.time()

    print(f"Starting stable check for {path}")

    if os.path.isdir(path):
        return False

    last_size = -1
    last_mtime = -1
    while time.time() - start_time < timeout:
        if not os.path.exists(path):
            return False
        try:
            current_size = os.path.getsize(path)
            current_mtime = os.path.getmtime(path)
        except FileNotFoundError:
            return False
        except OSError:
            # Permission errors / transient filesystem issues should be treated as "not stable yet".
            return False
    
        if current_size == last_size and current_mtime == last_mtime:
            print(f"File {path} is stable")
            return True
        
        last_size = current_size
        last_mtime = current_mtime
        time.sleep(interval)
    
    return False
    

def can_open_for_read(path: Path):
    if os.path.isdir(path):
        return False
    if not os.path.exists(path):
        return False
    try:
        with open(path, "rb"):
            return True
    except Exception:
        return False