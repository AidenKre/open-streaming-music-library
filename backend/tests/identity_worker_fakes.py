"""Fakes for the 6.5A.2d identity-worker tests: a manual clock and a stand-in
for ``audio_identity.compute_exact`` whose digest is the SHA-256 of the file
bytes (an independent oracle; no ffmpeg), with an optional hook that runs a
writer "mid-compute" (after the bytes were read, before the result returns).
"""

import hashlib
from pathlib import Path
from typing import Any, Callable, Optional

from app.services.audio_identity import KIND_PCM, ExactAudioHash, ExactUnavailable
from app.services.identity_worker import AudioIdentityWorker
from app.services.identity_wakeup import IdentityWakeup
from app.services.ffmpeg_runner import NO_OPTIONS, FfmpegProcessRegistry
from tests.tool_call_capture import option_fields

T0 = 1_800_000_000
TOOLS = "ffmpeg 9.0.2"


class FakeClock:
    def __init__(self, now: float = T0):
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def bytes_digest(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def hash_of(path: Path) -> ExactAudioHash:
    return ExactAudioHash(KIND_PCM, bytes_digest(path), 44100, 2, 16)


class FakeCompute:
    """``compute_exact`` stand-in. ``results`` (queue) overrides the next
    result(s); ``raises`` makes the next call raise; ``mid`` runs once per
    call after the file was read."""

    def __init__(self):
        self.calls: list[dict[str, Any]] = []
        self.results: list[Any] = []
        self.raises: list[BaseException] = []
        self.mid: Optional[Callable[[], None]] = None

    def __call__(self, path, codec_hint, *, options=NO_OPTIONS):
        self.calls.append({"path": str(path), "codec_hint": codec_hint, **option_fields(options)})
        if self.raises:
            raise self.raises.pop(0)
        path = Path(path)
        try:
            readable = path.is_file()
        except OSError:
            readable = False
        result = hash_of(path) if readable else ExactUnavailable("failed", "master_missing")
        if self.mid is not None:
            mid, self.mid = self.mid, None
            mid()
        if self.results:
            return self.results.pop(0)
        return result

    def paths(self) -> list[str]:
        return [c["path"] for c in self.calls]


def make_worker(db, *, clock=None, compute=None, wakeup=None, registry=None, **kwargs):
    return AudioIdentityWorker(
        db,
        wakeup=wakeup or IdentityWakeup(),
        registry=registry or FfmpegProcessRegistry(),
        clock=clock or FakeClock(),
        compute_exact=compute or FakeCompute(),
        tool_versions=lambda: TOOLS,
        **kwargs,
    )


# --- 6.5B.1b: a scripted fingerprinter (no fpcalc) -----------------------------------------

from app.services.fingerprinter import RawFingerprint  # noqa: E402

# 200 items whose top 14 bits all differ (coarse diversity 1.0): 'current'.
VARIED_ITEMS = tuple(i << 18 for i in range(200))
# 200 identical items (coarse diversity 0.005): 'low_information'.
FLAT_ITEMS = (0x12345678,) * 200


class FakeFingerprinter:
    """``Fingerprinter`` stand-in. ``results`` (queue) overrides the next
    result(s), else a varied 30 s print; ``raises`` makes the next call raise;
    ``mid`` runs once per call before the result returns (a writer racing the
    compute)."""

    name = "fakeprint"
    algorithm = "chromaprint-2"
    tool_version = "1.6.2"

    def __init__(self):
        self.calls: list[dict[str, Any]] = []
        self.results: list[Any] = []
        self.raises: list[BaseException] = []
        self.mid: Optional[Callable[[], None]] = None

    def fingerprint(self, path, *, max_seconds=120, options=NO_OPTIONS):
        self.calls.append({"path": str(path), "max_seconds": max_seconds, **option_fields(options)})
        if self.raises:
            raise self.raises.pop(0)
        if self.mid is not None:
            mid, self.mid = self.mid, None
            mid()
        if self.results:
            return self.results.pop(0)
        return RawFingerprint(VARIED_ITEMS, 30.0)

    def paths(self) -> list[str]:
        return [c["path"] for c in self.calls]
