from fastapi import FastAPI
from app.config import settings
from app.services.file_watcher import start_file_watcher, stop_file_watcher

app = FastAPI()

@app.on_event("startup")
def startup_event():
    if settings.enable_file_watcher:
        start_file_watcher()

@app.on_event("shutdown")
def shutdown_event():
    if settings.enable_file_watcher:
        stop_file_watcher()

@app.get("/")
def read_root():
    return {"message": "Hello, World!"}