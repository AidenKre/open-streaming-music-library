"""Shared setup for the 7A.2c validation-worker tests.

Rows are written and read with plain SQL (``identity_worker_fixtures.sql``) so
expected state never comes from the code under test. Items are staged the way
7A.2b's PUT leaves them: ``validating``, no lease, a ``source`` file under
``<uploads root>/<owner_id>/<batch>/<item>/`` and one durable ``upload_source`` quota row.
"""

import hashlib
import itertools
import json
import uuid as uuid_mod
from pathlib import Path
from typing import Any, Optional

from app.services.audio_identity import AudioIdentity, ExactAudioHash, FingerprintIdentity, compute_identity
from app.services.job_runtime import CancelTokens
from app.services.storage_ledger import UPLOAD_SOURCE
from app.services.upload_validation import UploadValidationWorker, probe_upload
from tests.identity_worker_fixtures import sql
from tests.tool_call_capture import option_fields, tool_call

BOOT = "boot-current"
DEAD_BOOT = "boot-dead"
_counter = itertools.count(1)


def new_uuid() -> str:
    return str(uuid_mod.uuid4())


def stage_item(db, uploads_root: Path, *, owner_id: Optional[int] = None, content: bytes = b"audio-A",
               batch_uuid: Optional[str] = None, item_uuid: Optional[str] = None, filename: str = "a.flac",
               state: str = "validating", lease: Optional[str] = None, progress_at: Optional[int] = None,
               batch_created_at: int = 100) -> dict:
    """One staged item (and its batch, if new) as 7A.2b's PUT leaves it."""
    owner = owner_id if owner_id is not None else db.owner_id
    batch = batch_uuid or new_uuid()
    item = item_uuid or new_uuid()
    n = next(_counter)
    folder = uploads_root / str(owner) / batch / item  # review r1 R1: per-owner staging
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / "source"
    source.write_bytes(content)
    sql(db, "INSERT OR IGNORE INTO upload_batches (owner_id, batch_uuid, created_at, updated_at) "
            "VALUES (?, ?, ?, ?)", (owner, batch, batch_created_at, batch_created_at))
    sql(db, "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, selection_index, "
            "expected_bytes, expected_sha256, received_bytes, received_sha256, source_path, state, "
            "lease_boot_id, created_at, updated_at, progress_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (owner, item, batch, filename, n, len(content), hashlib.sha256(content).hexdigest(), len(content),
         hashlib.sha256(content).hexdigest(), str(source), state, lease, 100, 100,
         progress_at if progress_at is not None else 1000 + n))
    sql(db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at) "
            "VALUES (?, ?, ?, ?, NULL, 0)", (owner, UPLOAD_SOURCE, item, len(content)))
    return {"owner_id": owner, "item_uuid": item, "batch_uuid": batch, "source": source}


def item_row(db, staged: dict) -> dict:
    [row] = sql(db, "SELECT * FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                (staged["owner_id"], staged["item_uuid"]))
    return row


def identity_row(db, staged: dict) -> Optional[dict]:
    rows = sql(db, "SELECT * FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
               (staged["owner_id"], staged["item_uuid"]))
    return rows[0] if rows else None


def report_of(db, staged: dict) -> Optional[dict]:
    text = item_row(db, staged)["duplicate_report"]
    return None if text is None else json.loads(text)


def source_rows(db, staged: dict) -> list[dict]:
    return sql(db, "SELECT purpose, bytes FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?",
               (staged["owner_id"], staged["item_uuid"]))


def detected(codec="flac", *, duration_s: Optional[float] = 12.5, mime="audio/flac", container="flac",
             title="Airbag") -> dict:
    return {
        "v": 1, "container": container, "codec": codec, "mime": mime, "duration_s": duration_s,
        "bitrate_kbps": 900.0, "sample_rate_hz": 44100, "channels": 2, "has_album_art": False,
        "tags": {"title": title, "artist": "Radiohead", "album": "OK Computer", "album_artist": None,
                 "date": None, "year": None, "genre": None, "track_number": None, "disc_number": None},
    }


class FakeProbe:
    """``probe_upload`` stand-in: returns ``result`` (a dict, or an exception to raise)."""

    def __init__(self, result: Any = None):
        self.result = detected() if result is None else result
        self.calls: list[dict] = []
        self.mid = None  # runs once inside the probe (a racing request)

    def __call__(self, path, **kwargs):
        options = tool_call(probe_upload, path, **kwargs)["options"]
        self.calls.append({"path": Path(path), **option_fields(options)})
        if self.mid is not None:
            mid, self.mid = self.mid, None
            mid()
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result


def exact_for(content: bytes) -> ExactAudioHash:
    """An exact hash that follows the file's bytes (what the fake decodes)."""
    return ExactAudioHash("pcm_sha256", hashlib.sha256(content).hexdigest(), 44100, 2, 16)


VARIED = tuple(i << 18 for i in range(200))


def print_of(items=VARIED, duration_s=200.0) -> FingerprintIdentity:
    return FingerprintIdentity("current", "fakeprint", "chromaprint-2", duration_s, tuple(items))


class FakeCompute:
    """``compute_identity`` stand-in: exact from the file's bytes; the print from
    ``prints[content]`` (default: none when no fingerprinter is passed, else a varied print)."""

    def __init__(self):
        self.calls: list[dict] = []
        self.prints: dict[bytes, Any] = {}
        self.exact: dict[bytes, Any] = {}
        self.raises: Optional[BaseException] = None
        self.mid = None

    def __call__(self, path, codec_hint, **kwargs):
        call = tool_call(compute_identity, path, codec_hint, **kwargs)
        self.calls.append({**call, "path": Path(path)})
        if self.mid is not None:
            mid, self.mid = self.mid, None
            mid()
        if self.raises is not None:
            raise self.raises
        content = Path(path).read_bytes()
        fingerprint = None
        if call["fingerprinter"] is not None:
            fingerprint = self.prints.get(content, print_of())
        return AudioIdentity(
            exact=self.exact.get(content, exact_for(content)), tool_versions="ffmpeg 8.1",
            computed_at=1700, fingerprint=fingerprint,
        )


class FakeRegistry:
    def __init__(self):
        self.killed: list[Any] = []

    def kill(self, job_id) -> bool:
        self.killed.append(job_id)
        return True

    def close(self) -> None:
        pass


FINGERPRINTER = object()  # a "tool present" marker; the fake compute never calls it


def make_worker(db, uploads_root: Path, *, probe=None, compute=None, fingerprinter=None, boot_id=BOOT,
                tokens=None, registry=None, **kwargs) -> UploadValidationWorker:
    return UploadValidationWorker(
        db, uploads_root=uploads_root, boot_id=boot_id, tokens=tokens or CancelTokens(),
        registry=registry or FakeRegistry(), fingerprinter=fingerprinter,
        probe=probe or FakeProbe(), compute_identity=compute or FakeCompute(), **kwargs,
    )
