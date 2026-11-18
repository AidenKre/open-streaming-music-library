"""Pending-deletion marker for the reader-side tests (piece 8A.3a).

Phase 8's marker is a ``deletion_journal`` row: ``live_tracks`` hides any
track that has one (spec §5 step 2; schema v16, piece 8A.2a). These helpers
plant and remove a real journal row in plain SQL, as the deletion worker
will: an ``operation_receipts`` row, a ``deletion_jobs`` row, a running
``deletion_job_items`` row and the journal row at stage ``intent``. The
journal's insert trigger requires the track row to exist, so mark a track
pending while it is still in ``tracks``.
"""

import sqlite3
import uuid as uuidlib
from pathlib import Path


def _connect(database_path) -> sqlite3.Connection:
    conn = sqlite3.connect(Path(database_path))
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def mark_pending_deletion(database_path, uuid_id: str) -> None:
    """Make ``uuid_id`` pending deletion for its owner (a stage-``intent``
    journal row naming the track's current path)."""
    conn = _connect(database_path)
    try:
        owner, path = conn.execute(
            "SELECT owner_id, file_path FROM tracks WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()
        operation = str(uuidlib.uuid4())
        conn.execute(
            "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, "
            "created_at, result_ref) VALUES (?, ?, 'track_deletion', ?, 1, ?)",
            (owner, operation, "a" * 64, operation),
        )
        conn.execute(
            "INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status) "
            "VALUES (?, ?, 1, 'accepted')",
            (owner, operation),
        )
        conn.execute(
            "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id, position, "
            "base_revision, status, lease_boot_id) VALUES (?, ?, ?, 0, 1, 'running', 'boot')",
            (owner, operation, uuid_id),
        )
        conn.execute(
            "INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id, original_path, "
            "quarantine_path, base_revision, src_dev, src_ino, src_size, src_mtime_ns, "
            "master_missing, stage, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, 1, 1, 2, 3, 4, 0, 'intent', 1, 1)",
            (owner, operation, uuid_id, str(path),
             f"/quarantine/.deleting/{owner}/{operation}/{uuid_id}"),
        )
        conn.commit()
    finally:
        conn.close()


def clear_pending_deletion(database_path, uuid_id: str) -> None:
    """A rolled-back deletion: the journal row goes, the job rows stay."""
    conn = _connect(database_path)
    try:
        conn.execute("DELETE FROM deletion_journal WHERE uuid_id = ?", (uuid_id,))
        conn.commit()
    finally:
        conn.close()
