"""Shared setup for the import tests that start a server with its file
watchers, moved out of ``tests/test_import_startup.py``: the watcher switch,
a real tagged MP3 made by ffmpeg, and a drain of the watchers' imports."""

import subprocess
from concurrent.futures import ThreadPoolExecutor

import pytest

# Registered marker (plan D16): tests/conftest.py skips without ffmpeg/ffprobe.
requires_ffmpeg = pytest.mark.requires_ffmpeg

WATCH = {"ENABLE_FILE_WATCHER": "true"}


def _tone(path, title):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
         "-metadata", f"title={title}", "-metadata", "artist=Radiohead",
         "-c:a", "libmp3lame", str(path)],
        check=True,
    )


def _drain_imports(client):
    """Wait for every import the startup (or a signup) submitted, then give
    each watcher a fresh executor so later submissions still run."""
    for name in ("file_watcher", "user_file_watcher"):
        watcher = getattr(client.app.state, name)
        watcher.executor.shutdown(wait=True)
        watcher.executor = ThreadPoolExecutor(max_workers=2)
