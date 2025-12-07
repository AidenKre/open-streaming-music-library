from app.config import settings
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from concurrent.futures import ThreadPoolExecutor
import time, os

processed = set()
observer = None
executor = ThreadPoolExecutor(max_workers=4)

class FileWatcher(FileSystemEventHandler):

    def on_created(self, event):
        if event.is_directory:
            return
        if event.src_path in processed:
            return

        processed.add(event.src_path)
        executor.submit(process_file_after_stable, event.src_path)

def process_file_after_stable(path: str):
    print(f"Processing file {path} after stable")
    if not wait_until_ready(path):
        return False
    handle_new_file(path)

def wait_until_ready(path: str):
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
    

def can_open_for_read(path: str):
    if os.path.isdir(path):
        return False
    if not os.path.exists(path):
        return False
    try:
        with open(path, "rb"):
            return True
    except Exception:
        return False

def handle_new_file(path: str):
    print(f"Handling new file {path}")

def start_file_watcher():
    global observer
    if observer is None or not observer.is_alive():
        observer = Observer()
        observer.schedule(FileWatcher(), settings.import_dir, recursive=True)
        observer.start()
        print(f"File watcher started for {settings.import_dir}")

def stop_file_watcher():
    global observer
    if observer is not None:
        observer.stop()
        observer.join()
        observer = None
        print("File watcher stopped")