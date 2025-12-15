from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import time, os

class FileWatcher(FileSystemEventHandler):

    def __init__(self, import_dir: Path):
        self.import_dir = import_dir
        self.observer = None
        self.executor = ThreadPoolExecutor(max_workers=4)
        self.processed = set()

    def on_created(self, event):
        if event.is_directory:
            return
        if event.src_path in self.processed:
            return

        self.processed.add(event.src_path)
        self.executor.submit(process_file_after_stable, event.src_path)

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

def process_file_after_stable(path: Path):
    print(f"Processing file {path} after stable")
    if not wait_until_ready(path):
        return False
    handle_new_file(path)

def wait_until_ready(path: Path):
    if not wait_until_stable(path):
        return False
    return can_open_for_read(path)

def wait_until_stable(path: str, timeout: int = 60, interval: int = 0.2):
    start_time = time.time()

    print(f"Starting stable check for {path}")

    if  os.path.isdir(path):
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

def handle_new_file(path: Path):
    print(f"Handling new file {path}")