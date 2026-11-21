"""Deletion jobs, their items and the deletion journal.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

import json
import uuid

from app.core import job_runtime
from app.core.deletion_states import (
    DELETION_ITEM_TERMINAL_STATES,
    ITEM_DETAIL_CODES,
    ITEM_ERROR_CODES,
)
from app.core.owner import _require_owner
from app.database.core import DatabaseCore
from app.database.operation_receipts import Replay as OpReplay


class DeletionRecheckFailed(Exception):
    """The owner's track no longer matches what the deletion worker journaled
    (gone, another revision or another path); nothing was changed."""


class TrackPendingDeletion(Exception):
    """A mutator met the pending-deletion marker (a ``deletion_journal`` row)
    under the track lock. Retryable: a rolled-back deletion leaves a healthy
    track."""

    def __init__(self, uuid_id: str):
        self.uuid_id = uuid_id
        super().__init__(f"track {uuid_id} is pending deletion")


class DeletionPart(DatabaseCore):
    """The ``deletion_jobs``, ``deletion_job_items`` and ``deletion_journal`` rows:
    the preview facts, the worker's claim and its one deleting transaction,
    start-up recovery, the job reads."""

    @staticmethod
    def _is_pending_deletion_in(conn, uuid_id: str, owner: int) -> bool:
        row = conn.execute(
            "SELECT EXISTS(SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?)"
            " AND NOT EXISTS(SELECT 1 FROM live_tracks WHERE uuid_id = ? AND owner_id = ?)",
            (uuid_id, owner, uuid_id, owner),
        ).fetchone()
        return bool(row[0])

    def is_pending_deletion(self, uuid_id: str, *, owner_id: int) -> bool:
        """True when the owner's track exists but is missing from ``live_tracks``.

        The marker is a ``deletion_journal`` row, which ``live_tracks`` excludes.
        A tombstoned, unknown or foreign track is not pending (it answers like
        unknown)."""
        owner_id = _require_owner(owner_id)
        with self._connection() as conn:
            return self._is_pending_deletion_in(conn, uuid_id, owner_id)

    @staticmethod
    def _deletion_busy_in(conn, uuid_id: str, owner: int) -> bool:
        """True when the owner's track is mid-operation and must not be deleted
        now: an active conversion, an edit journal row, a non-terminal upload
        commit journal row naming it, or a pending deletion. Owner-scoped."""
        if conn.execute(
            "SELECT 1 FROM conversion_jobs WHERE uuid_id = ? AND owner_id = ?"
            " AND status IN ('queued','running') LIMIT 1",
            (uuid_id, owner),
        ).fetchone():
            return True
        if conn.execute(
            "SELECT 1 FROM edit_journal WHERE uuid_id = ? AND owner_id = ? LIMIT 1",
            (uuid_id, owner),
        ).fetchone():
            return True
        if conn.execute(
            "SELECT 1 FROM upload_commit_journal WHERE reserved_track_uuid = ?"
            " AND owner_id = ? AND state IN ('committing','prepared','moved') LIMIT 1",
            (uuid_id, owner),
        ).fetchone():
            return True
        return DeletionPart._is_pending_deletion_in(conn, uuid_id, owner)

    def get_deletion_preview_facts(
        self, uuid_ids: list[str], *, owner_id: int
    ) -> dict[str, dict]:
        """What the deletion preview needs per requested UUID, for the owner only:
        a live track (state, revision, title, artist, album, file_path, busy), an
        own tombstone (state, revision), else absent. Writes nothing."""
        owner = _require_owner(owner_id)
        facts: dict[str, dict] = {}
        with self._connection() as conn:
            for start in range(0, len(uuid_ids), 500):
                chunk = uuid_ids[start : start + 500]
                marks = ",".join("?" * len(chunk))
                for r in conn.execute(
                    "SELECT t.uuid_id, t.revision, t.file_path, m.title, m.artist, m.album"
                    " FROM tracks t LEFT JOIN trackmetadata m ON m.uuid_id = t.uuid_id"
                    f" WHERE t.owner_id = ? AND t.uuid_id IN ({marks})",
                    (owner, *chunk),
                ):
                    facts[r["uuid_id"]] = {
                        "state": "live",
                        "revision": r["revision"],
                        "title": r["title"],
                        "artist": r["artist"],
                        "album": r["album"],
                        "file_path": str(r["file_path"]),
                        "busy": self._deletion_busy_in(conn, r["uuid_id"], owner),
                    }
                for r in conn.execute(
                    "SELECT uuid_id, revision FROM track_tombstones"
                    f" WHERE owner_id = ? AND uuid_id IN ({marks})",
                    (owner, *chunk),
                ):
                    facts.setdefault(
                        r["uuid_id"], {"state": "tombstone", "revision": r["revision"]}
                    )
        return facts

    def read_deletion_target(self, uuid_id: str, *, owner_id: int) -> dict:
        """What the deletion worker revalidates under the track lock, for the
        owner only: a live track (state, revision, file_path, cover_art_id, busy),
        an own tombstone (state, revision), else absent. Writes nothing."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT t.revision, t.file_path, m.cover_art_id FROM tracks t"
                " LEFT JOIN trackmetadata m ON m.uuid_id = t.uuid_id"
                " WHERE t.uuid_id = ? AND t.owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if row is not None:
                return {
                    "state": "live",
                    "revision": row["revision"],
                    "file_path": str(row["file_path"]),
                    "cover_art_id": row["cover_art_id"],
                    "busy": self._deletion_busy_in(conn, uuid_id, owner),
                }
            tomb = conn.execute(
                "SELECT revision FROM track_tombstones WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if tomb is not None:
                return {"state": "tombstone", "revision": tomb["revision"]}
        return {"state": "absent"}

    def create_deletion_job(self, request, *, owner_id: int, now: int) -> bool:
        """True for a new job, False for an exact replay. The operation hash is
        order-normalised (plan D6); the job keeps the request order. Targets are
        stored as given: nothing is looked up."""
        owner = _require_owner(owner_id)
        op = str(request.operation_uuid)
        targets = [(str(t.uuid_id), t.base_revision) for t in request.targets]
        with self._connection(commit=True, immediate=True) as conn:
            outcome = self._with_operation_in(
                conn,
                owner_id=owner,
                operation_uuid=op,
                kind="track_deletion",
                request_model=request.receipt_model(),
                now=now,
            )
            if isinstance(outcome, OpReplay):
                return False
            conn.execute(
                "INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status)"
                " VALUES (?, ?, ?, 'accepted')",
                (owner, op, now),
            )
            conn.executemany(
                "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id,"
                " position, base_revision, status) VALUES (?, ?, ?, ?, ?, 'pending')",
                [
                    (owner, op, uuid_id, index, revision)
                    for index, (uuid_id, revision) in enumerate(targets)
                ],
            )
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=op, result_ref=op
            )
        return True

    def claim_next_deletion_item(self, *, boot_id: str) -> dict | None:
        """Claim the first pending deletion item of any owner (job created_at,
        operation_uuid, item position) by a pending -> running CAS stamping
        ``boot_id`` (SC-16d). None when nothing is pending."""
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT i.owner_id, i.operation_uuid, i.uuid_id, i.base_revision"
                " FROM deletion_job_items i JOIN deletion_jobs j"
                " ON j.owner_id = i.owner_id AND j.operation_uuid = i.operation_uuid"
                " JOIN users u ON u.id = i.owner_id"
                " WHERE i.status = 'pending' AND u.deleting_at IS NULL"
                " ORDER BY j.created_at, i.operation_uuid, i.position LIMIT 1"
            ).fetchone()
            if row is None:
                return None
            key = {
                "owner_id": row["owner_id"],
                "operation_uuid": row["operation_uuid"],
                "uuid_id": row["uuid_id"],
            }
            if not job_runtime.claim(conn, "deletion_job_items", key, boot_id=boot_id):
                return None
            return {**key, "base_revision": row["base_revision"]}

    def finish_deletion_item(
        self,
        *,
        owner_id: int,
        operation_uuid: str,
        uuid_id: str,
        boot_id: str,
        status: str,
        error_code: str | None = None,
        tombstone_revision: int | None = None,
        details=(),
    ) -> bool:
        """Terminalize a running item this boot leased; True iff the row changed.
        The job completes once none of its items is non-terminal."""
        details = list(details)
        if status not in DELETION_ITEM_TERMINAL_STATES:
            raise ValueError("status must be a terminal item state")
        if error_code is not None and error_code not in ITEM_ERROR_CODES:
            raise ValueError("unknown item error code")
        if any(d not in ITEM_DETAIL_CODES for d in details):
            raise ValueError("unknown item detail code")
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = ?, error_code = ?,"
                " tombstone_revision = ?, detail_json = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running' AND lease_boot_id = ?",
                (
                    status, error_code, tombstone_revision, json.dumps(details),
                    owner_id, operation_uuid, uuid_id, boot_id,
                ),
            )
            if cursor.rowcount != 1:
                return False
            self._complete_deletion_job_if_done_in(conn, owner_id, operation_uuid)
            return True

    @staticmethod
    def _complete_deletion_job_if_done_in(conn, owner: int, operation_uuid: str) -> None:
        open_items = conn.execute(
            "SELECT 1 FROM deletion_job_items WHERE owner_id = ?"
            " AND operation_uuid = ? AND status IN ('pending','running') LIMIT 1",
            (owner, operation_uuid),
        ).fetchone()
        if open_items is None:
            conn.execute(
                "UPDATE deletion_jobs SET status = 'completed'"
                " WHERE owner_id = ? AND operation_uuid = ?",
                (owner, operation_uuid),
            )

    def begin_track_deletion(
        self,
        *,
        owner_id: int,
        operation_uuid: str,
        uuid_id: str,
        boot_id: str,
        base_revision: int,
        original_path: str,
        quarantine_path: str | None,
        identity,
        cover_art_id: int | None,
        master_missing: bool,
        now: int,
    ) -> str:
        """Write the deletion journal row (stage 'intent') before any move.
        "ok", or "gone" (the item is not ours and running), "conflict" (the
        track changed) or "busy". Nothing is written unless "ok"."""
        owner = _require_owner(owner_id)
        src = tuple(identity) if identity is not None else (None, None, None)
        with self._connection(commit=True, immediate=True) as conn:
            leased = conn.execute(
                "SELECT 1 FROM deletion_job_items WHERE owner_id = ? AND operation_uuid = ?"
                " AND uuid_id = ? AND status = 'running' AND lease_boot_id = ?",
                (owner, operation_uuid, uuid_id, boot_id),
            ).fetchone()
            if leased is None:
                return "gone"
            track = conn.execute(
                "SELECT revision, file_path FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if (
                track is None
                or track["revision"] != base_revision
                or str(track["file_path"]) != str(original_path)
            ):
                return "conflict"
            if self._deletion_busy_in(conn, uuid_id, owner):
                return "busy"
            conn.execute(
                "INSERT INTO deletion_journal (owner_id, operation_uuid, uuid_id,"
                " original_path, quarantine_path, base_revision, src_dev, src_ino,"
                " src_size, cover_art_id, master_missing,"
                " stage, created_at, updated_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'intent', ?, ?)",
                (
                    owner, operation_uuid, uuid_id, str(original_path), quarantine_path,
                    base_revision, *src, cover_art_id, 1 if master_missing else 0, now, now,
                ),
            )
        return "ok"

    def mark_deletion_moved(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, now: int
    ) -> None:
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "UPDATE deletion_journal SET stage = 'moved', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND stage = 'intent'",
                (now, owner, operation_uuid, uuid_id),
            )

    def commit_track_deletion(
        self,
        *,
        owner_id: int,
        operation_uuid: str,
        uuid_id: str,
        boot_id: str,
        base_revision: int,
        original_path: str,
        details,
        now: int,
    ) -> int:
        """The one transaction of a deletion: recheck, tombstone and delete the
        catalog rows, mark the item deleted, complete the job, journal
        'committed'. Returns the tombstone revision."""
        owner = _require_owner(owner_id)
        details = list(details)
        if any(d not in ITEM_DETAIL_CODES for d in details):
            raise ValueError("unknown item detail code")
        with self._connection(commit=True, immediate=True) as conn:
            track = conn.execute(
                "SELECT revision, file_path FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
            if (
                track is None
                or track["revision"] != base_revision
                or str(track["file_path"]) != str(original_path)
            ):
                raise DeletionRecheckFailed(uuid_id)
            revision = self._delete_track_in(conn, uuid_id, owner_id=owner)
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'deleted', tombstone_revision = ?,"
                " detail_json = ? WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running' AND lease_boot_id = ?",
                (revision, json.dumps(details), owner, operation_uuid, uuid_id, boot_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("deletion item is not running under this boot")
            self._complete_deletion_job_if_done_in(conn, owner, operation_uuid)
            cursor = conn.execute(
                "UPDATE deletion_journal SET stage = 'committed', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?",
                (now, owner, operation_uuid, uuid_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("deletion journal row is missing")
        return revision

    def clear_deletion_journal(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str
    ) -> bool:
        """Drop an uncommitted journal row (never a committed one); True iff
        one row went."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "DELETE FROM deletion_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND uuid_id = ? AND stage IN ('intent','moved')",
                (owner, operation_uuid, uuid_id),
            )
            return cursor.rowcount == 1

    def get_deletion_journal(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str
    ) -> dict | None:
        """The owner's journal row for one item, or None. Writes nothing."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM deletion_journal WHERE owner_id = ?"
                " AND operation_uuid = ? AND uuid_id = ?",
                (owner, operation_uuid, uuid_id),
            ).fetchone()
        return None if row is None else dict(row)

    def release_deletion_item(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, boot_id: str
    ) -> bool:
        """Put a running item this boot holds back to pending, only while it has
        no journal row. True iff the item changed."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'pending', lease_boot_id = NULL"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running' AND lease_boot_id = ?"
                " AND NOT EXISTS (SELECT 1 FROM deletion_journal d"
                " WHERE d.owner_id = deletion_job_items.owner_id"
                " AND d.operation_uuid = deletion_job_items.operation_uuid"
                " AND d.uuid_id = deletion_job_items.uuid_id)",
                (owner, operation_uuid, uuid_id, boot_id),
            )
            return cursor.rowcount == 1

    def finish_deletion_cleanup(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, details
    ) -> None:
        """After storage cleanup: drop the committed journal row and set the
        item's final details."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "DELETE FROM deletion_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND uuid_id = ? AND stage = 'committed'",
                (owner, operation_uuid, uuid_id),
            )
            conn.execute(
                "UPDATE deletion_job_items SET detail_json = ? WHERE owner_id = ?"
                " AND operation_uuid = ? AND uuid_id = ? AND status = 'deleted'",
                (json.dumps(list(details)), owner, operation_uuid, uuid_id),
            )

    def deletion_job_has_pending_items(self, *, owner_id: int, operation_uuid: str) -> bool:
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT 1 FROM deletion_job_items WHERE owner_id = ? AND operation_uuid = ?"
                " AND status = 'pending' LIMIT 1",
                (owner, operation_uuid),
            ).fetchone()
        return row is not None

    def reclaim_deletion_items(self, *, boot_id: str) -> int:
        """Startup reclaim, server-wide: requeue running items left by another
        boot (or with no lease) that have no deletion journal row, since a
        journal-backed item waits for journal recovery. Then complete accepted
        jobs that have no open item left. Returns the number of items requeued.
        Idempotent: a second call with nothing left to do changes nothing."""
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'pending', lease_boot_id = NULL"
                " WHERE status = 'running'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)"
                " AND NOT EXISTS (SELECT 1 FROM deletion_journal d"
                " WHERE d.owner_id = deletion_job_items.owner_id"
                " AND d.operation_uuid = deletion_job_items.operation_uuid"
                " AND d.uuid_id = deletion_job_items.uuid_id)",
                (boot_id,),
            )
            requeued = cursor.rowcount
            conn.execute(
                "UPDATE deletion_jobs SET status = 'completed' WHERE status = 'accepted'"
                " AND NOT EXISTS (SELECT 1 FROM deletion_job_items i"
                " WHERE i.owner_id = deletion_jobs.owner_id"
                " AND i.operation_uuid = deletion_jobs.operation_uuid"
                " AND i.status IN ('pending','running'))"
            )
            return requeued

    def list_deletion_journals(self, *, stages) -> list[dict]:
        """Every deletion journal row (all owners) whose stage is in ``stages``,
        ordered by owner, operation and track. Writes nothing."""
        stages = tuple(stages)
        if any(st not in ("intent", "moved", "committed") for st in stages):
            raise ValueError("unknown deletion journal stage")
        if not stages:
            return []
        marks = ",".join("?" for _ in stages)
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT * FROM deletion_journal WHERE stage IN (" + marks + ")"
                " ORDER BY owner_id, operation_uuid, uuid_id",
                stages,
            ).fetchall()
        return [dict(r) for r in rows]

    def mark_deletion_recovery_required(
        self, *, owner_id: int, operation_uuid: str, uuid_id: str, boot_id: str
    ) -> bool:
        """Startup recovery could not resolve a journal: fail the item left
        running by another boot with ``recovery_required`` (the journal stays)
        and complete its job when nothing is open. A terminal item is never
        rewritten. True iff the item changed."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE deletion_job_items SET status = 'failed',"
                " error_code = 'recovery_required'"
                " WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?"
                " AND status = 'running'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (owner, operation_uuid, uuid_id, boot_id),
            )
            if cursor.rowcount != 1:
                return False
            self._complete_deletion_job_if_done_in(conn, owner, operation_uuid)
            return True

    def get_deletion_job(self, operation_uuid, *, owner_id: int) -> dict | None:
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT operation_uuid, created_at FROM deletion_jobs"
                " WHERE owner_id = ? AND operation_uuid = ?",
                (owner, key),
            ).fetchone()
            if row is None:
                return None
            items = conn.execute(
                "SELECT uuid_id, position, base_revision, status, error_code,"
                " tombstone_revision, detail_json FROM deletion_job_items"
                " WHERE owner_id = ? AND operation_uuid = ? ORDER BY position",
                (owner, key),
            ).fetchall()
        return {
            "operation_uuid": row["operation_uuid"],
            "created_at": row["created_at"],
            "items": [dict(i) for i in items],
        }

    def list_deletion_jobs(
        self, *, owner_id: int, after: tuple[int, str] | None, limit: int
    ) -> list[dict]:
        """Keyset page ascending by (created_at, operation_uuid), each job with
        its non-zero per-status item counts. Jobs are kept until `users delete`
        removes the user's rows."""
        owner = _require_owner(owner_id)
        sql = "SELECT operation_uuid, created_at FROM deletion_jobs WHERE owner_id = ?"
        params: list = [owner]
        if after is not None:
            sql += " AND (created_at, operation_uuid) > (?, ?)"
            params += [after[0], after[1]]
        sql += " ORDER BY created_at, operation_uuid LIMIT ?"
        params.append(limit)
        with self._connection() as conn:
            jobs = [dict(row) for row in conn.execute(sql, params)]
            counts: dict[str, dict[str, int]] = {}
            if jobs:
                marks = ",".join("?" for _ in jobs)
                for row in conn.execute(
                    "SELECT operation_uuid, status, count(*) FROM deletion_job_items"
                    f" WHERE owner_id = ? AND operation_uuid IN ({marks})"
                    " GROUP BY operation_uuid, status",
                    (owner, *[j["operation_uuid"] for j in jobs]),
                ):
                    counts.setdefault(row[0], {})[row[1]] = row[2]
        return [{**j, "state_counts": counts.get(j["operation_uuid"], {})} for j in jobs]
