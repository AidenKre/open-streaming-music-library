from fastapi import FastAPI
from app.config import settings
from app.services.file_watcher import FileWatcher

app = FastAPI()

@app.on_event("startup")
def startup_event():
    if settings.enable_file_watcher:
        watcher = FileWatcher(settings.import_dir)
        watcher.start_file_watcher()
        app.state.file_watcher = watcher

@app.on_event("shutdown")
def shutdown_event():
    watcher = getattr(app.state, "file_watcher", None)
    if watcher:
        watcher.stop_file_watcher()
        

@app.get("/")
def read_root():
    return {"message": "Hello, World!"}