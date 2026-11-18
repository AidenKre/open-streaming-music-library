"""Shared setup for the 7A.3a commit-worker tests.

An accepted commit is written with plain SQL the way the commit route leaves
it (receipt, item ``committing`` with its reserved track uuid, journal
``committing``), so the worker tests never depend on the acceptance code.
Process steps are fakes: the probe returns a detected-metadata dict, the exact
hash follows the file's bytes, and the tag writer copies the source and records
the tags it was asked to write.
"""

import hashlib
import json
import uuid as uuid_mod
from pathlib import Path
from typing import Any, Optional

from app.services.cover_art_manager import CoverArtAddResult
from app.services.storage_ledger import StagedQuota, StorageLedger
from app.services.upload_commit import UploadCommitWorker
from app.services.upload_validation import staged_identity_columns
from app.services.audio_identity import AudioIdentity
from tests.identity_worker_fixtures import sql
from tests.upload_validation_fixtures import BOOT, FakeProbe, FakeRegistry, detected, exact_for, stage_item  # noqa: F401  (re-exported)

NOW = 1_700_000_000
NO_ACKS = '{"library_tracks":[],"staged_items":[]}'
QUOTA = StagedQuota(user_bytes=10**9, total_bytes=10**10)


class FreeSpace:
    def __init__(self, free=10**12):
        self.free = free

    def __call__(self, path):
        class Usage:
            pass

        usage = Usage()
        if isinstance(self.free, BaseException):
            raise self.free
        usage.free = self.free
        return usage


def make_ledger(db, music: Path, *, free=10**12, boot_id=BOOT) -> StorageLedger:
    return StorageLedger(db, path=music, floor_bytes=0, boot_id=boot_id, disk_usage=FreeSpace(free))


class FakeExact:
    """``compute_exact`` stand-in: the exact hash of the file's bytes, unless
    ``result`` (a value or an exception) is set."""

    def __init__(self):
        self.calls: list[dict] = []
        self.result: Any = None

    def __call__(self, path, codec_hint, **kwargs):
        self.calls.append({"path": Path(path), "codec_hint": codec_hint, **kwargs})
        if isinstance(self.result, BaseException):
            raise self.result
        if self.result is not None:
            return self.result
        return exact_for(Path(path).read_bytes())


class FakeTagWriter:
    """``write_metadata_tags`` stand-in: dest = source bytes (+ ``extra``), tags recorded."""

    def __init__(self, extra: bytes = b""):
        self.calls: list[dict] = []
        self.extra = extra
        self.raises: Optional[BaseException] = None

    def __call__(self, source, dest, tags, registry=None, job_id=None, **kwargs):
        self.calls.append({"source": Path(source), "dest": Path(dest), "tags": dict(tags)})
        if self.raises is not None:
            raise self.raises
        Path(dest).write_bytes(Path(source).read_bytes() + self.extra)


class FakeArt:
    """``extract_cover_art_bytes`` stand-in."""

    def __init__(self, data: Optional[bytes] = b"PNG-bytes"):
        self.data = data
        self.calls: list[Path] = []
        self.kwargs: list[dict] = []  # review r2 7-R2-13: the forced demuxer is visible

    def __call__(self, path, **kwargs):
        self.calls.append(Path(path))
        self.kwargs.append(kwargs)
        return self.data


class FakeCoverArt:
    """``CoverArtManager`` stand-in: one art id per distinct image."""

    def __init__(self, first_id=500):
        self.ids: dict[bytes, int] = {}
        self.next_id = first_id
        self.calls: list[bytes] = []
        self.raises: Optional[BaseException] = None
        self.released: list[int] = []

    def release_if_unreferenced(self, cover_art_id: int) -> bool:
        self.released.append(cover_art_id)
        return True

    def add_album_art_with_status(self, image: bytes) -> CoverArtAddResult:
        self.calls.append(image)
        if self.raises is not None:
            raise self.raises
        if image in self.ids:
            return CoverArtAddResult(cover_art_id=self.ids[image], was_created=False)
        self.ids[image] = self.next_id
        self.next_id += 1
        return CoverArtAddResult(cover_art_id=self.ids[image], was_created=True)


def ready_item(db, uploads_root: Path, *, meta=None, identity: Optional[AudioIdentity] = None,
               identity_columns: Optional[dict] = None, **kwargs) -> dict:
    """A review_ready item with its detected metadata and staged identity (plain SQL)."""
    staged = stage_item(db, uploads_root, state="review_ready", **kwargs)
    content = staged["source"].read_bytes()
    meta = meta or detected()
    sql(db, "UPDATE upload_items SET detected_metadata = ?, kind = 'audio', duplicate_report = ?"
            " WHERE owner_id = ? AND item_uuid = ?",
        (json.dumps(meta), '{"v":1,"status":"failed","exact":null,"fingerprint":null,"matches":[]}',
         staged["owner_id"], staged["item_uuid"]))
    if identity_columns is None:
        identity = identity or AudioIdentity(exact=exact_for(content), tool_versions="ffmpeg 8.1",
                                             computed_at=1700)
        identity_columns = staged_identity_columns(identity, fingerprinter_present=False)
    names = list(identity_columns)
    sql(db, f"INSERT INTO upload_item_audio_identity (owner_id, item_uuid, {', '.join(names)})"
            f" VALUES (?, ?, {', '.join('?' * len(names))})",
        (staged["owner_id"], staged["item_uuid"], *identity_columns.values()))
    return {**staged, "meta": meta, "content": content}


def accept(db, staged: dict, *, edits: Optional[dict] = None, write_tags: bool = False,
           acks: str = NO_ACKS, op: Optional[str] = None, track: Optional[str] = None,
           ext: str = ".flac", created_at: int = NOW, lease: Optional[str] = None) -> dict:
    """What an accepted commit leaves: receipt, item committing, journal committing."""
    op = op or str(uuid_mod.uuid4())
    track = track or str(uuid_mod.uuid4())
    owner, item = staged["owner_id"], staged["item_uuid"]
    work = staged["source"].parent / f"work-{op}{ext}"
    sql(db, "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at,"
            " result_ref) VALUES (?, ?, 'upload_commit', ?, ?, ?)",
        (owner, op, hashlib.sha256(op.encode()).hexdigest(), created_at, item))
    sql(db, "UPDATE upload_items SET state = 'committing', reserved_track_uuid = ?, lease_boot_id = ?"
            " WHERE owner_id = ? AND item_uuid = ?", (track, lease, owner, item))
    sql(db, "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state,"
            " base_review_version, reserved_track_uuid, edits, write_tags, acknowledged_duplicates,"
            " source_path, work_path, lease_boot_id, created_at, updated_at)"
            " VALUES (?, ?, ?, 'committing', 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (owner, op, item, track, json.dumps(edits or {}), int(write_tags), acks,
         str(staged["source"]), str(work), lease, created_at, created_at))
    return {**staged, "op": op, "track": track, "work": work}


def journal(db, commit: dict) -> dict:
    [row] = sql(db, "SELECT * FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?",
                (commit["owner_id"], commit["op"]))
    return row


def reservations(db, owner_id: int) -> list[dict]:
    return sql(db, "SELECT purpose, subject_ref, bytes, lease_boot_id FROM storage_reservations"
                   " WHERE owner_id = ? ORDER BY id", (owner_id,))


def library_root(db, music: Path, owner_id: int) -> Path:
    [user] = sql(db, "SELECT library_folder FROM users WHERE id = ?", (owner_id,))
    return music / user["library_folder"]


def make_commit_worker(db, music: Path, *, probe=None, exact=None, tag_writer=None, art=None,
                       cover_art=None, ledger=None, boot_id=BOOT, registry=None, clock=None,
                       **kwargs) -> UploadCommitWorker:
    return UploadCommitWorker(
        db,
        uploads_root=music / ".uploads",
        music_library_dir=music,
        boot_id=boot_id,
        ledger=ledger or make_ledger(db, music, boot_id=boot_id),
        quota=QUOTA,
        cover_art=cover_art or FakeCoverArt(),
        registry=registry or FakeRegistry(),
        clock=clock or (lambda: NOW + 5),
        probe=probe or FakeProbe(),
        compute_exact=exact or FakeExact(),
        write_tags=tag_writer or FakeTagWriter(),
        extract_art=art or FakeArt(None),
        **kwargs,
    )


def sha(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def copy_tree_hashes(root: Path) -> dict:
    return {str(p.relative_to(root)): sha(p) for p in sorted(root.rglob("*")) if p.is_file()}

