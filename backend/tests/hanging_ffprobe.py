"""A fake ``ffprobe`` that never answers (bug row U05-A-06).

``install`` puts an executable ``ffprobe`` first on PATH that sleeps for
``HANG_S`` seconds without writing anything: far longer than the shortened
bound the tests set, so a probe that returns within ``WITHIN_S`` was ended by
the bound (or by a kill), not by the fake finishing. ``shorten_bound`` lowers
the one probe bound (``audio_identity.PROBE_TIMEOUT_S``) for the test.
"""

import os
import time
from contextlib import contextmanager

from app.services import audio_identity

HANG_S = 5
SHORT_BOUND_S = 0.3
WITHIN_S = 3.0


def install(monkeypatch, tmp_path):
    folder = tmp_path / "hanging-bin"
    folder.mkdir(exist_ok=True)
    fake = folder / "ffprobe"
    fake.write_text(f"#!/bin/sh\nexec sleep {HANG_S}\n")
    fake.chmod(0o755)
    monkeypatch.setenv("PATH", f"{folder}{os.pathsep}{os.environ.get('PATH', '')}")
    return fake


def shorten_bound(monkeypatch):
    monkeypatch.setattr(audio_identity, "PROBE_TIMEOUT_S", SHORT_BOUND_S)


@contextmanager
def timed():
    """``with timed() as t: ...`` then ``t()`` is the elapsed seconds."""
    started = time.monotonic()
    elapsed = {}
    yield lambda: elapsed.get("s", time.monotonic() - started)
    elapsed["s"] = time.monotonic() - started
