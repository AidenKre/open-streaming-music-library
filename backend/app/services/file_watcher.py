from app.config import settings
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

processed = set()
observer = Observer()

class FileWatcher(FileSystemEventHandler):

    def on_created(self, event):
        if event.is_directory:
            return
        if event.src_path in processed:
            return

        processed.add(event.src_path)
        handle_new_file(event.src_path)

def handle_new_file(path: str):
    print(f"New file detected: {path}")


def start_file_watcher():
    if not observer.is_alive():
        observer.schedule(FileWatcher(), settings.import_dir, recursive=True)
        observer.start()

def stop_file_watcher():
    observer.stop()
    observer.join()
