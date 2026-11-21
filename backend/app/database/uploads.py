"""Uploads: batches, items, receipts, validation, commits, retention.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

import dataclasses
import json
import uuid

from app.core import job_runtime
from app.core.owner import _require_owner
from app.core.storage_purposes import UPLOAD_SOURCE, UPLOAD_WORK
from app.core.upload_states import ENDED_STATES, SOURCE_RELEASE_STATES
from app.database.core import DatabaseCore
from app.database.operation_receipts import Replay as OpReplay

# Item columns the API may read; server-internal ones (part_path, source_path,
# final_path, lease_boot_id) are deliberately absent so a path cannot leak.
_UPLOAD_ITEM_API_COLUMNS = (
    "item_uuid", "batch_uuid", "parent_item_uuid", "filename", "selection_index",
    "member_order_key", "state", "expected_bytes", "expected_sha256",
    "received_bytes", "review_version", "error_code", "error_message",
    "error_retryable", "created_at", "updated_at", "detected_metadata", "duplicate_report",
    "kind", "skipped_members",
    "result_track_uuid", "result_revision", "duplicate_kind", "conflict_track_uuids",
)


# Columns a state transition may set besides state/updated_at. Never
# interpolate a name that is not listed here.
_UPLOAD_TRANSITION_FIELDS = frozenset(
    {"error_code", "error_message", "error_retryable", "cancel_requested", "reserved_track_uuid",
     "result_track_uuid", "result_revision", "final_path", "lease_boot_id",
     "conflict_track_uuids", "duplicate_kind", "progress_at"}
)


# Item states a worker holds (a transfer or a validation): cancelling one sets
# the durable flag.
_LEASED_STATES = frozenset({"receiving", "validating"})
# One bound placeholder per ended state (``app.core.upload_states``), for ``state [NOT] IN (…)``.
_ENDED_MARKS = ", ".join("?" * len(ENDED_STATES))


class UploadItemsInUse(Exception):
    def __init__(self, item_uuids: list[str]):
        self.item_uuids = item_uuids
        super().__init__("Upload item IDs already in use")


class UploadsPart(DatabaseCore):
    """The ``upload_batches``, ``upload_items`` and ``upload_commit_journal`` rows
    with their identity and acknowledgement rows: allocation, the streamed
    receipt, validation and ZIP expansion, review, the commit steps, start-up
    reconcile, expiry and retention."""

    # ── upload receipt reconcile (startup; server-wide, owner taken from each row) ──

    def list_upload_receipts_to_reconcile(self, *, boot_id: str) -> list[dict]:
        """Receiving rows whose lease is not ``boot_id``, and non-receiving rows
        that still name a part file."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid, state, expected_bytes, expected_sha256,"
                " part_path, source_path FROM upload_items"
                " WHERE (state = 'receiving' AND (lease_boot_id IS NULL OR lease_boot_id <> ?))"
                " OR (state <> 'receiving' AND part_path IS NOT NULL)"
                " ORDER BY owner_id, item_uuid",
                (boot_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    # ── upload validation (background worker; server-wide, owner taken from each row) ──

    def claim_upload_validation(self, *, boot_id: str) -> dict | None:
        """Claim the next ``validating`` item whose lease is not ``boot_id``
        (oldest ``progress_at``, then ``item_uuid``), stamping ``boot_id``.
        None when there is none or a cancel is already requested."""
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid, parent_item_uuid, source_path, review_version,"
                " detected_metadata FROM upload_items"
                " WHERE state = 'validating' AND cancel_requested = 0"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)"
                " AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = upload_items.owner_id"
                " AND u.deleting_at IS NOT NULL)"  # a user being deleted gets no more work
                " AND (parent_item_uuid IS NULL OR EXISTS (SELECT 1 FROM upload_items p"
                " WHERE p.owner_id = upload_items.owner_id AND p.item_uuid = upload_items.parent_item_uuid"
                " AND p.state = 'expanded'))"
                " ORDER BY progress_at, item_uuid LIMIT 1",
                (boot_id,),
            ).fetchone()
            if row is None:
                return None
            item_key = {"owner_id": row["owner_id"], "item_uuid": row["item_uuid"]}
            if not job_runtime.claim(
                conn, "upload_items", item_key,
                boot_id=boot_id, from_state="validating", to_state="validating",
            ):
                return None
            if job_runtime.cancel_requested(conn, "upload_items", item_key):
                conn.rollback()
                return None
            has_identity = conn.execute(
                "SELECT 1 FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                (row["owner_id"], row["item_uuid"]),
            ).fetchone() is not None
            return {**dict(row), "has_identity": has_identity}

    def finish_upload_validation(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        detected_metadata: str, identity_columns: dict | None, check, now: int,
    ) -> bool:
        """validating -> review_ready in one transaction, guarded by this boot's
        lease and the claimed review_version (False, nothing written, when it no
        longer holds). Stores the identity (when given), runs
        ``check(conn, own_identity_row, extra_subject_rows) -> report_json``
        and stores the report and detected metadata."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND item_uuid = ?"
                " AND state = 'validating' AND lease_boot_id = ? AND review_version = ?",
                (owner, key, boot_id, review_version),
            ).fetchone()
            if held is None:
                return False
            if identity_columns is not None:
                names = list(identity_columns)
                from app.services.audio_identity import FINGERPRINT_COLUMNS, IDENTITY_COLUMNS

                allowed = {*IDENTITY_COLUMNS, *FINGERPRINT_COLUMNS, "fp_failure_reason"}
                if not set(names) <= allowed:
                    raise ValueError("unknown upload identity column")
                conn.execute(
                    f"INSERT OR REPLACE INTO upload_item_audio_identity"
                    f" (owner_id, item_uuid, {', '.join(names)})"
                    f" VALUES (?, ?, {', '.join('?' * len(names))})",
                    (owner, key, *(identity_columns[n] for n in names)),
                )
            own = conn.execute(
                "SELECT * FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                (owner, key),
            ).fetchone()
            extra = conn.execute(
                "SELECT i.* FROM upload_item_audio_identity i JOIN upload_items u"
                " ON u.owner_id = i.owner_id AND u.item_uuid = i.item_uuid"
                " WHERE i.owner_id = ? AND i.item_uuid <> ?"
                " AND u.state IN ('review_ready', 'committing', 'duplicate_conflict')"
                " ORDER BY i.item_uuid",
                (owner, key),
            ).fetchall()
            report_json = check(conn, own, extra)
            conn.execute(
                "UPDATE upload_items SET state = 'review_ready', kind = 'audio',"
                " detected_metadata = ?, duplicate_report = ?, lease_boot_id = NULL,"
                " error_code = NULL, error_message = NULL, error_retryable = NULL,"
                " updated_at = ?, progress_at = ? WHERE owner_id = ? AND item_uuid = ?",  # reviewable is progress
                (detected_metadata, report_json, now, now, owner, key),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return True

    def fail_upload_validation(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        error_code: str, error_message: str, error_retryable: bool, now: int
    ) -> list[dict] | None:
        """validating -> failed, guarded by this boot's lease and the claimed
        review_version (None, nothing written, when it no longer holds). The
        source path and its quota row are kept; giving them back is a separate
        guarded step once the file is gone. The item's archive children (a failed
        archive was never expanded, so they hold no source or quota rows) are
        deleted and its skipped count cleared in the same transaction; the deleted
        children (item_uuid, batch_uuid) are returned, or None when the guard failed."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'failed', error_code = ?, error_message = ?,"
                " error_retryable = ?, lease_boot_id = NULL, updated_at = ?,"
                " progress_at = ?"  # validation ending is progress: the retry window starts now
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'validating'"
                " AND lease_boot_id = ? AND review_version = ?",
                (error_code, error_message, int(bool(error_retryable)), now, now,
                 owner, key, boot_id, review_version),
            )
            if cur.rowcount != 1:
                return None
            # Children share the parent's batch (composite FK): naming it lets the
            # lookup use the whole of idx_upload_items_parent.
            (batch,) = conn.execute(
                "SELECT batch_uuid FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                (owner, key)).fetchone()
            children = [dict(r) for r in conn.execute(
                "SELECT item_uuid, batch_uuid FROM upload_items WHERE owner_id = ? AND batch_uuid = ?"
                " AND parent_item_uuid = ?",
                (owner, batch, key))]
            conn.execute(
                "DELETE FROM upload_items WHERE owner_id = ? AND batch_uuid = ? AND parent_item_uuid = ?",
                (owner, batch, key))
            conn.execute(
                "UPDATE upload_items SET skipped_members = NULL WHERE owner_id = ? AND item_uuid = ?",
                (owner, key))
            self._touch_upload_batch_in(conn, owner, key, now)
            return children

    def advance_dead_upload_receipt(
        self, *, owner_id: int, item_uuid: str, boot_id: str, source_path: str,
        received_bytes: int, received_sha256: str, receive_purpose: str,
        settled_purpose: str, now: int, keep_part: bool = False,
    ) -> bool:
        """A dead transfer's complete source: receiving -> validating, and its
        quota row becomes a durable on-disk row (restored if it was lost).
        ``keep_part`` keeps a part path recorded that could not be removed."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'validating', source_path = ?, received_bytes = ?,"
                " received_sha256 = ?, part_path = CASE WHEN ? THEN part_path ELSE NULL END,"
                " lease_boot_id = NULL, error_code = NULL,"
                " error_message = NULL, error_retryable = NULL, progress_at = ?, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (source_path, received_bytes, received_sha256, int(keep_part), now, now,
                 owner, item_uuid, boot_id),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, item_uuid, now)
            self._settle_upload_quota_in(
                conn, owner, item_uuid, settled_purpose=settled_purpose,
                nbytes=received_bytes, receive_purpose=receive_purpose,
            )
            return True

    def return_dead_upload_receipt(
        self, *, owner_id: int, item_uuid: str, boot_id: str, receive_purpose: str,
        error_code: str, error_message: str, now: int,
    ) -> bool:
        """A dead transfer without a complete source: receiving -> allocated with a
        retryable error, and its in-flight quota rows released."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'allocated', error_code = ?, error_message = ?,"
                " error_retryable = 1, received_bytes = 0, received_sha256 = NULL, part_path = NULL,"
                " source_path = NULL, lease_boot_id = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (error_code, error_message, now, owner, item_uuid, boot_id),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, item_uuid, now)
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                " AND purpose = ?",
                (owner, item_uuid, receive_purpose),
            )
            return True

    def fail_dead_upload_receipt(
        self, *, owner_id: int, item_uuid: str, boot_id: str, error_code: str,
        error_message: str, now: int,
    ) -> bool:
        """A dead transfer whose partial could not be removed: receiving -> failed,
        part path kept so the next start retries the removal."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'failed', error_code = ?, error_message = ?,"
                " error_retryable = 0, received_bytes = 0, lease_boot_id = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND (lease_boot_id IS NULL OR lease_boot_id <> ?)",
                (error_code, error_message, now, owner, item_uuid, boot_id),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, item_uuid, now)
            return True

    def clear_upload_part(self, *, owner_id: int, item_uuid: str) -> None:
        """Forget the part path and lease of a row that is no longer receiving."""
        owner = _require_owner(owner_id)
        with self._connection(commit=True) as conn:
            conn.execute(
                "UPDATE upload_items SET part_path = NULL, lease_boot_id = NULL"
                " WHERE owner_id = ? AND item_uuid = ? AND state <> 'receiving'",
                (owner, item_uuid),
            )

    def list_upload_source_reservations(self, *, purpose: str) -> list[dict]:
        """Each reservation of ``purpose`` with its owner and its item's state and
        source path (None when the item does not exist)."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT r.id AS id, r.owner_id AS owner_id, i.state AS state, i.source_path AS source_path"
                " FROM storage_reservations r"
                " LEFT JOIN upload_items i ON i.owner_id = r.owner_id AND i.item_uuid = r.subject_ref"
                " WHERE r.purpose = ? ORDER BY r.id",
                (purpose,),
            ).fetchall()
        return [dict(row) for row in rows]

    # ── uploads (7A.1d) ────────────────────────────────────────────────────

    def allocate_upload_batch(self, request, *, owner_id: int, now: int) -> bool:
        """True for a new allocation, False for an exact replay."""
        owner = _require_owner(owner_id)
        batch_uuid = str(request.batch_uuid)
        with self._connection(commit=True, immediate=True) as conn:
            outcome = self._with_operation_in(
                conn,
                owner_id=owner,
                operation_uuid=batch_uuid,
                kind="upload_allocation",
                request_model=request,
                now=now,
            )
            if isinstance(outcome, OpReplay):
                return False
            item_uuids = [str(item.item_uuid) for item in request.items]
            taken = set()
            for start in range(0, len(item_uuids), 500):
                chunk = item_uuids[start : start + 500]
                marks = ",".join("?" for _ in chunk)
                taken.update(
                    row[0]
                    for row in conn.execute(
                        "SELECT item_uuid FROM upload_items "
                        f"WHERE owner_id = ? AND item_uuid IN ({marks})",
                        (owner, *chunk),
                    )
                )
            if taken:
                raise UploadItemsInUse(sorted(taken))
            conn.execute(
                "INSERT INTO upload_batches (owner_id, batch_uuid, label, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?)",
                (owner, batch_uuid, request.label, now, now),
            )
            conn.executemany(
                "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, "
                "selection_index, member_order_key, expected_bytes, expected_sha256, "
                "state, created_at, updated_at, progress_at) "
                "VALUES (?, ?, ?, ?, ?, '', ?, ?, 'allocated', ?, ?, ?)",
                [
                    (owner, str(item.item_uuid), batch_uuid, item.filename, index,
                     item.byte_length, item.sha256, now, now, now)
                    for index, item in enumerate(request.items)
                ],
            )
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=batch_uuid, result_ref=batch_uuid
            )
        return True

    def get_upload_batch(self, batch_uuid, *, owner_id: int) -> dict | None:
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(batch_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT batch_uuid, label, created_at, updated_at FROM upload_batches "
                "WHERE owner_id = ? AND batch_uuid = ?",
                (owner, key),
            ).fetchone()
            if row is None:
                return None
            counts = self._upload_state_counts_in(conn, owner, [key])
        return self._with_counts(dict(row), counts.get(key, {}))

    @staticmethod
    def _upload_state_counts_in(conn, owner: int, batch_uuids: list[str]) -> dict:
        """{batch_uuid: {state: count}} for the caller's batches (non-zero only)."""
        marks = ",".join("?" for _ in batch_uuids)
        counts: dict[str, dict[str, int]] = {}
        for batch_uuid, state, count in conn.execute(
            "SELECT batch_uuid, state, count(*) FROM upload_items "
            f"WHERE owner_id = ? AND batch_uuid IN ({marks}) "
            "GROUP BY batch_uuid, state",
            (owner, *batch_uuids),
        ):
            counts.setdefault(batch_uuid, {})[state] = count
        return counts

    @staticmethod
    def _with_counts(batch: dict, counts: dict) -> dict:
        batch["item_count"] = sum(counts.values())
        batch["state_counts"] = counts
        return batch

    def list_upload_batches(
        self, *, owner_id: int, after: tuple[int, str] | None, limit: int
    ) -> list[dict]:
        """Keyset page ascending by (created_at, batch_uuid)."""
        owner = _require_owner(owner_id)
        sql = (
            "SELECT batch_uuid, label, created_at, updated_at FROM upload_batches "
            "WHERE owner_id = ?"
        )
        params: list = [owner]
        if after is not None:
            sql += " AND (created_at, batch_uuid) > (?, ?)"
            params += [after[0], after[1]]
        sql += " ORDER BY created_at, batch_uuid LIMIT ?"
        params.append(limit)
        with self._connection() as conn:
            batches = [dict(row) for row in conn.execute(sql, params)]
            counts = (
                self._upload_state_counts_in(
                    conn, owner, [b["batch_uuid"] for b in batches]
                )
                if batches
                else {}
            )
        return [self._with_counts(b, counts.get(b["batch_uuid"], {})) for b in batches]

    def list_upload_items(
        self,
        batch_uuid,
        *,
        owner_id: int,
        top_level_only: bool = False,
        after: tuple[int, str, str] | None = None,
        limit: int | None = None,
    ) -> list[dict]:
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(batch_uuid)))
        sql = (
            f"SELECT {', '.join(_UPLOAD_ITEM_API_COLUMNS)} FROM upload_items "
            "WHERE owner_id = ? AND batch_uuid = ?"
        )
        params: list = [owner, key]
        if top_level_only:
            sql += " AND parent_item_uuid IS NULL"
        if after is not None:
            sql += " AND (selection_index, member_order_key, item_uuid) > (?, ?, ?)"
            params += list(after)
        sql += " ORDER BY selection_index, member_order_key, item_uuid"
        if limit is not None:
            sql += " LIMIT ?"
            params.append(limit)
        with self._connection() as conn:
            rows = conn.execute(sql, params).fetchall()
        return [self._upload_item_dict(row) for row in rows]

    def get_upload_item(self, item_uuid, *, owner_id: int) -> dict | None:
        with self._connection() as conn:
            return self._upload_item_in(conn, owner_id=owner_id, item_uuid=item_uuid)

    @staticmethod
    def _upload_item_in(conn, *, owner_id: int, item_uuid) -> dict | None:
        """THE owner-scoped upload item lookup; reuse inside transactions."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        row = conn.execute(
            f"SELECT {', '.join(_UPLOAD_ITEM_API_COLUMNS)} FROM upload_items "
            "WHERE owner_id = ? AND item_uuid = ?",
            (owner, key),
        ).fetchone()
        return None if row is None else UploadsPart._upload_item_dict(row)

    @staticmethod
    def _transition_upload_item_in(
        conn, *, owner_id: int, item_uuid, from_states, to_state: str, now: int,
        fields: dict | None = None, progress_at_most: int | None = None,
    ) -> bool:
        """THE item compare-and-swap: move an owned item between states only if
        it is still in one of from_states. The caller holds the write
        transaction. Does not touch progress_at; ``progress_at_most`` also requires the
        item's progress to be no newer than that."""
        owner = _require_owner(owner_id)
        fields = fields or {}
        unknown = set(fields) - _UPLOAD_TRANSITION_FIELDS
        if unknown:
            raise ValueError(f"unsupported transition fields: {sorted(unknown)}")
        states = tuple(from_states)
        if not states:
            return False
        key = str(uuid.UUID(str(item_uuid)))
        names = sorted(fields)
        assignments = "".join(f", {name} = ?" for name in names)
        marks = ",".join("?" for _ in states)
        bound = "" if progress_at_most is None else " AND progress_at <= ?"
        cur = conn.execute(
            f"UPDATE upload_items SET state = ?, updated_at = ?{assignments} "
            f"WHERE owner_id = ? AND item_uuid = ? AND state IN ({marks}){bound}",
            (to_state, now, *(fields[n] for n in names), owner, key, *states,
             *(() if progress_at_most is None else (progress_at_most,))),
        )
        if cur.rowcount != 1:
            return False
        UploadsPart._touch_upload_batch_in(conn, owner, key, now)
        return True

    @staticmethod
    def _touch_upload_batch_in(conn, owner: int, item_uuid: str, now: int) -> None:
        """Bump ``updated_at`` of the batch holding an item; the caller holds the transaction."""
        conn.execute(
            "UPDATE upload_batches SET updated_at = ? WHERE owner_id = ? AND batch_uuid = "
            "(SELECT batch_uuid FROM upload_items WHERE owner_id = ? AND item_uuid = ?)",
            (now, owner, owner, item_uuid),
        )

    def cancel_upload_item(
        self, item_uuid, *, owner_id: int, from_states, now: int
    ) -> tuple[bool, dict | None, list[str]]:
        """Cancel an owned item in one write transaction. An item that a worker
        holds (``receiving`` or ``validating``, with any lease) also gets the durable
        ``cancel_requested`` flag; an ``allocated`` one does not. An archive that
        is then ``cancelled`` or ``expanded`` also cancels its children that are
        in ``from_states``; their uuids are the third value."""

        def cancel_one(conn, uuid_):
            for state in from_states:
                flag = {"cancel_requested": 1} if state in _LEASED_STATES else None
                if self._transition_upload_item_in(
                    conn, owner_id=owner_id, item_uuid=uuid_, from_states=(state,),
                    to_state="cancelled", now=now, fields=flag,
                ):
                    return True
            return False

        cancelled_children: list[str] = []
        with self._connection(commit=True, immediate=True) as conn:
            changed = cancel_one(conn, item_uuid)
            row = self._upload_item_in(conn, owner_id=owner_id, item_uuid=item_uuid)
            if row is not None and row["state"] in ("cancelled", "expanded"):
                # Sorted here, not in SQL: an ORDER BY would make the planner walk
                # the whole batch in item order instead of seeking the parent index.
                children = sorted(r["item_uuid"] for r in conn.execute(
                    "SELECT item_uuid FROM upload_items WHERE owner_id = ? AND batch_uuid = ?"
                    " AND parent_item_uuid = ?",
                    (_require_owner(owner_id), row["batch_uuid"], row["item_uuid"]),
                ))
                cancelled_children = [c for c in children if cancel_one(conn, c)]
        return changed, row, cancelled_children

    def retry_upload_item(
        self, item_uuid, *, owner_id: int, expected_review_version: int, source_present, now: int
    ) -> tuple[str, dict | None]:
        """Retry a ``duplicate_conflict`` or retryable ``failed`` item in one
        transaction, by compare-and-swap on ``review_version``. Outcomes:
        ``not_found``, ``version_conflict``, ``not_retryable`` (nothing written),
        ``validating`` or ``allocated`` (``review_version`` + 1). ``source_present``
        is called with the recorded source path."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = self._upload_item_in(conn, owner_id=owner, item_uuid=key)
            if row is None:
                return "not_found", None
            if row["review_version"] != expected_review_version:
                return "version_conflict", row
            state = row["state"]
            if state == "duplicate_conflict":
                target = "validating"
            elif state == "failed" and row["error_retryable"] == 1:
                recorded = conn.execute(
                    "SELECT source_path FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                    (owner, key),
                ).fetchone()["source_path"]
                present = recorded is not None and bool(source_present(recorded))
                if not present and row["parent_item_uuid"] is not None:
                    return "not_retryable", row  # a child cannot be re-sent
                target = "validating" if present else "allocated"
            else:
                return "not_retryable", row
            common = (
                "state = ?, review_version = review_version + 1, error_code = NULL,"
                " error_message = NULL, error_retryable = NULL, lease_boot_id = NULL,"
                " cancel_requested = 0, updated_at = ?, progress_at = ?"  # a retry is progress
            )
            if state == "duplicate_conflict":
                conn.execute(
                    f"UPDATE upload_items SET {common}, duplicate_report = NULL"
                    " WHERE owner_id = ? AND item_uuid = ?",
                    (target, now, now, owner, key),
                )
            elif target == "validating":
                conn.execute(
                    "DELETE FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                    (owner, key),
                )
                conn.execute(
                    f"UPDATE upload_items SET {common}, detected_metadata = NULL,"
                    " duplicate_report = NULL, kind = NULL WHERE owner_id = ? AND item_uuid = ?",
                    (target, now, now, owner, key),
                )
            else:
                conn.execute(
                    "DELETE FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                    (owner, key),
                )
                conn.execute(
                    f"UPDATE upload_items SET {common}, detected_metadata = NULL,"
                    " duplicate_report = NULL, kind = NULL, source_path = NULL,"
                    " received_sha256 = NULL, received_bytes = 0"
                    " WHERE owner_id = ? AND item_uuid = ?",
                    (target, now, now, owner, key),
                )
                conn.execute(
                    "DELETE FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                    " AND purpose = ?",
                    (owner, key, UPLOAD_SOURCE),
                )
            self._touch_upload_batch_in(conn, owner, key, now)
            return target, self._upload_item_in(conn, owner_id=owner, item_uuid=key)

    def accept_upload_commit(
        self, item_uuid, *, owner_id: int, request_model, decide, now: int
    ) -> tuple[str, dict | None]:
        """Accept a commit in one write transaction (spec section 6 step 1).

        ``request_model`` carries the path item uuid and the request; its
        receipt is keyed by the operation uuid. Outcomes: ``not_found``;
        ``replay`` (row is the item plus ``journal_state``); ``accepted``
        (the item, now ``committing``). ``decide(row)`` either raises to refuse
        (rolling everything back) or returns the journal fields to freeze.
        ``OperationConflict`` propagates."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        operation = str(request_model.request.operation_uuid)
        with self._connection(commit=True, immediate=True) as conn:
            item = self._upload_item_in(conn, owner_id=owner, item_uuid=key)
            if item is None:
                return "not_found", None
            outcome = self._with_operation_in(
                conn, owner_id=owner, operation_uuid=operation, kind="upload_commit",
                request_model=request_model, now=now,
            )
            if isinstance(outcome, OpReplay):
                journal = conn.execute(
                    "SELECT state FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?",
                    (owner, operation),
                ).fetchone()
                return "replay", {**item, "journal_state": None if journal is None else journal["state"]}
            private = conn.execute(
                "SELECT source_path, detected_metadata FROM upload_items "
                "WHERE owner_id = ? AND item_uuid = ?",
                (owner, key),
            ).fetchone()
            fields = decide({**item, "source_path": private["source_path"],
                             "detected_metadata": private["detected_metadata"]})
            if not self._transition_upload_item_in(
                conn, owner_id=owner, item_uuid=key, from_states=("review_ready",),
                to_state="committing", now=now,
                fields={"reserved_track_uuid": fields["reserved_track_uuid"], "error_code": None,
                        "error_message": None, "error_retryable": None,
                        "progress_at": now},  # an accepted commit is progress
            ):
                raise RuntimeError("upload item left review_ready under the write lock")
            conn.execute(
                "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state, "
                "base_review_version, reserved_track_uuid, edits, write_tags, acknowledged_duplicates, "
                "source_path, work_path, created_at, updated_at) "
                "VALUES (?, ?, ?, 'committing', ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (owner, operation, key, fields["base_review_version"], fields["reserved_track_uuid"],
                 fields["edits"], fields["write_tags"], fields["acknowledged_duplicates"],
                 fields["source_path"], fields["work_path"], now, now),
            )
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=operation, result_ref=key)
            return "accepted", self._upload_item_in(conn, owner_id=owner, item_uuid=key)

    def resolve_upload_duplicate(
        self, item_uuid, *, owner_id: int, request_model, decide, now: int
    ) -> tuple[str, dict | None]:
        """Close an item as a terminal ``duplicate`` in one write transaction.

        Outcomes: ``not_found``; ``replay`` (the current item); ``resolved``
        (the item, now ``duplicate``). ``decide(row, is_live)`` either raises to
        refuse (rolling everything back, so no receipt is written) or returns
        ``(existing_track_uuid, duplicate_kind)``; ``is_live(uuid)`` is true for
        one of the owner's live tracks. Tracks, metadata, identity and the commit
        journal are never touched. ``OperationConflict`` propagates."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        operation = str(request_model.request.operation_uuid)
        with self._connection(commit=True, immediate=True) as conn:
            item = self._upload_item_in(conn, owner_id=owner, item_uuid=key)
            if item is None:
                return "not_found", None
            outcome = self._with_operation_in(
                conn, owner_id=owner, operation_uuid=operation, kind="upload_resolve_duplicate",
                request_model=request_model, now=now,
            )
            if isinstance(outcome, OpReplay):
                return "replay", item

            def is_live(track_uuid: str) -> bool:
                return conn.execute(
                    "SELECT 1 FROM live_tracks WHERE owner_id = ? AND uuid_id = ?",
                    (owner, track_uuid),
                ).fetchone() is not None

            track_uuid, kind = decide(item, is_live)
            if not self._transition_upload_item_in(
                conn, owner_id=owner, item_uuid=key,
                from_states=("review_ready", "duplicate_conflict"), to_state="duplicate", now=now,
                fields={"result_track_uuid": track_uuid, "duplicate_kind": kind,
                        "error_code": None, "error_message": None, "error_retryable": None,
                        "lease_boot_id": None},
            ):
                raise RuntimeError("upload item left a resolvable state under the write lock")
            self._set_operation_result_in(
                conn, owner_id=owner, operation_uuid=operation, result_ref=key)
            return "resolved", self._upload_item_in(conn, owner_id=owner, item_uuid=key)

    def claim_upload_commit(self, *, boot_id: str) -> dict | None:
        """Claim the oldest ``committing`` journal row (any owner, server-wide
        like the validation worker) whose item is ``committing`` and whose lease
        is not ``boot_id``; stamp ``boot_id`` on the journal and the item. Returns
        the journal row plus the item's batch_uuid, filename, detected_metadata
        and the staged identity row (or None)."""
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT j.*, i.batch_uuid AS batch_uuid, i.filename AS filename,"
                " i.detected_metadata AS detected_metadata"
                " FROM upload_commit_journal j JOIN upload_items i"
                " ON i.owner_id = j.owner_id AND i.item_uuid = j.item_uuid"
                " WHERE j.state = 'committing' AND i.state = 'committing'"
                " AND (j.lease_boot_id IS NULL OR j.lease_boot_id <> ?)"
                " AND NOT EXISTS (SELECT 1 FROM users u WHERE u.id = j.owner_id"
                " AND u.deleting_at IS NOT NULL)"  # a user being deleted gets no more work
                " ORDER BY j.created_at, j.operation_uuid LIMIT 1",
                (boot_id,),
            ).fetchone()
            if row is None:
                return None
            owner, item = row["owner_id"], row["item_uuid"]
            if not job_runtime.claim(
                conn, "upload_items", {"owner_id": owner, "item_uuid": item},
                boot_id=boot_id, from_state="committing", to_state="committing",
            ):
                return None
            conn.execute(
                "UPDATE upload_commit_journal SET lease_boot_id = ? "
                "WHERE owner_id = ? AND operation_uuid = ?",
                (boot_id, owner, row["operation_uuid"]),
            )
            identity = conn.execute(
                "SELECT * FROM upload_item_audio_identity WHERE owner_id = ? AND item_uuid = ?",
                (owner, item),
            ).fetchone()
            return {**dict(row), "lease_boot_id": boot_id,
                    "identity": None if identity is None else dict(identity)}

    def release_upload_commit_lease(self, *, owner_id: int, operation_uuid: str, boot_id: str) -> None:
        """Give a claimed, unfinished commit back (journal and item leases of
        ``boot_id``), so the next claim can take it again."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE owner_id = ? AND lease_boot_id = ?"
                " AND item_uuid = (SELECT item_uuid FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'committing')",
                (owner, boot_id, owner, key),
            )
            conn.execute(
                "UPDATE upload_commit_journal SET lease_boot_id = NULL WHERE owner_id = ?"
                " AND operation_uuid = ? AND state = 'committing' AND lease_boot_id = ?",
                (owner, key, boot_id),
            )

    def fail_upload_commit(
        self, *, owner_id: int, operation_uuid: str, boot_id: str, error_code: str,
        error_message: str, item_state: str, reservation_id: int | None, now: int,
        keep_reservation: bool = False,
    ) -> bool:
        """End a commit that failed before ``prepared`` in one transaction,
        guarded by journal state ``committing`` and this boot's lease (False,
        nothing written, otherwise). The journal becomes ``failed``; the item
        goes to ``item_state`` (``review_ready`` or ``failed``) with a new
        review version and a retryable error; the work reservation row is
        deleted, or, with ``keep_reservation`` (the work copy could not be removed),
        settled into the durable ``upload_work`` row so it stays counted. The staged source and its quota row are never touched."""
        if item_state not in ("review_ready", "failed"):
            raise ValueError("item_state must be review_ready or failed")
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT item_uuid FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND lease_boot_id = ?",
                (owner, key, boot_id),
            ).fetchone()
            if held is None:
                return False
            item = held["item_uuid"]
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'failed', error_code = ?,"
                " lease_boot_id = NULL, updated_at = ? WHERE owner_id = ? AND operation_uuid = ?",
                (error_code, now, owner, key),
            )
            cursor = conn.execute(
                "UPDATE upload_items SET state = ?, review_version = review_version + 1,"
                " error_code = ?, error_message = ?, error_retryable = 1, lease_boot_id = NULL,"
                " updated_at = ? WHERE owner_id = ? AND item_uuid = ? AND state = 'committing'",
                (item_state, error_code, error_message, now, owner, item),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("commit item left committing under the write lock")
            if reservation_id is not None and keep_reservation:
                self._settle_storage_in(conn, reservation_id, purpose=UPLOAD_WORK)
            elif reservation_id is not None:
                conn.execute(
                    "DELETE FROM storage_reservations WHERE id = ? AND owner_id = ?",
                    (reservation_id, owner),
                )
            self._touch_upload_batch_in(conn, owner, item, now)
            return True

    def record_upload_commit_art(
        self, *, owner_id: int, operation_uuid: str, boot_id: str, cover_art_id: int,
        cover_art_created: bool, now: int,
    ) -> bool:
        """Journal the registered cover art and whether this operation created
        it, guarded by state ``committing`` and this boot's lease."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET cover_art_id = ?, cover_art_created = ?,"
                " updated_at = ? WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND lease_boot_id = ?",
                (cover_art_id, 1 if cover_art_created else 0, now, owner, key, boot_id),
            )
            return cursor.rowcount == 1

    def adopt_upload_commit_art(
        self, *, owner_id: int, operation_uuid: str, cover_art_id: int, now: int
    ) -> bool:
        """Startup: journal ``cover_art_id`` as created by this operation when its
        journal is still ``committing`` with no art recorded and no track and no
        other commit journal references that art (checked in this transaction).
        False: nothing written; shared art is never adopted."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET cover_art_id = ?, cover_art_created = 1,"
                " updated_at = ? WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND cover_art_id IS NULL"
                " AND NOT EXISTS (SELECT 1 FROM trackmetadata WHERE cover_art_id = ?)"
                " AND NOT EXISTS (SELECT 1 FROM upload_commit_journal o WHERE o.cover_art_id = ?"
                "                 AND NOT (o.owner_id = ? AND o.operation_uuid = ?))",
                (cover_art_id, now, owner, key, cover_art_id, cover_art_id, owner, key),
            )
            return cursor.rowcount == 1

    @staticmethod
    def _exact_library_matches_in(
        conn, *, owner_id: int, item_uuid: str, identity, acknowledged: dict,
        exclude=frozenset(),
    ) -> tuple[list[str], list[str]]:
        """SC-16a helper (never opens, commits or closes a connection): the
        owner's live library tracks with ``identity``'s exact audio identity
        (``find_duplicates`` exact layer only, uncapped, finder order), split
        into (acknowledged, unacknowledged) for the committing ``item_uuid``.
        Acknowledged: listed in ``acknowledged['library_tracks']``; published
        by an imported item listed in ``['staged_items']``; or published by an
        imported item whose persisted acknowledgements list ``item_uuid``."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services.duplicate_detection import TrackRef, find_duplicates

        report = find_duplicates(
            conn, dataclasses.replace(identity, fingerprint=None),
            owner_id=owner_id, exclude=frozenset(exclude),
        )
        matches = [
            m.subject.uuid_id for m in report.matches
            if isinstance(m.subject, TrackRef) and m.kind == "exact"
        ]
        listed = set(acknowledged.get("library_tracks", ()))
        staged = set(acknowledged.get("staged_items", ()))
        published: set[str] = set()
        rest = [t for t in matches if t not in listed]
        if rest:
            marks = ", ".join("?" * len(rest))
            rows = conn.execute(
                "SELECT i.result_track_uuid, i.item_uuid, EXISTS ("
                " SELECT 1 FROM upload_item_acknowledgements a"
                " WHERE a.owner_id = i.owner_id AND a.item_uuid = i.item_uuid"
                " AND a.subject_kind = 'staged_item' AND a.subject_ref = ?) AS acks_us"
                " FROM upload_items i WHERE i.owner_id = ? AND i.state = 'imported'"
                f" AND i.result_track_uuid IN ({marks})",
                (item_uuid, owner_id, *rest),
            ).fetchall()
            published = {r[0] for r in rows if r[1] in staged or r[2]}
        yes = [t for t in matches if t in listed or t in published]
        no = [t for t in matches if t not in listed and t not in published]
        return yes, no

    def upload_commit_preflight(self, *, owner_id: int, operation_uuid: str) -> list[str] | None:
        """Uuids of the owner's live library tracks that exactly match a
        ``prepared`` commit's journaled identity and are not acknowledged
        (finder order); None when there is no prepared journal row. Writes
        nothing."""
        from app.services.audio_identity import identity_from_columns

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT * FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'prepared'",
                (owner, key),
            ).fetchone()
            if row is None:
                return None
            _, unacknowledged = self._exact_library_matches_in(
                conn, owner_id=owner, item_uuid=row["item_uuid"],
                identity=identity_from_columns(dict(row)),
                acknowledged=json.loads(row["acknowledged_duplicates"]),
                exclude=frozenset({row["reserved_track_uuid"]}),
            )
        return unacknowledged

    @staticmethod
    def _record_upload_conflict_in(
        conn, *, owner_id: int, operation_uuid: str, item_uuid: str, track_uuids, now: int,
        clear_final_path: bool, drop_work_reservation: bool,
    ) -> bool:
        """The one recording of a ``duplicate_conflict`` (never opens or commits):
        journal and item (``committing`` only) end there listing ``track_uuids``;
        source, review version and review data are untouched. ``clear_final_path``
        NULLs the journal's final path (no file was placed); the work reservation
        row is dropped when ``drop_work_reservation``."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        if not UploadsPart._transition_upload_item_in(
            conn, owner_id=owner, item_uuid=item_uuid, from_states=("committing",),
            to_state="duplicate_conflict", now=now,
            fields={"conflict_track_uuids": json.dumps(list(track_uuids)), "lease_boot_id": None,
                    "error_code": None, "error_message": None, "error_retryable": None},
        ):
            return False
        conn.execute(
            "UPDATE upload_commit_journal SET state = 'duplicate_conflict', updated_at = ?"
            + (", final_path = NULL" if clear_final_path else "")
            + " WHERE owner_id = ? AND operation_uuid = ?",
            (now, owner, key),
        )
        if drop_work_reservation:
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND purpose = ? AND subject_ref = ?",
                (owner, UPLOAD_WORK, key),
            )
        return True

    def record_upload_commit_conflict(
        self, *, owner_id: int, operation_uuid: str, track_uuids, now: int,
        placed: bool = False,
    ) -> bool:
        """Step 3: a ``prepared`` (or ``moved``) commit with unacknowledged exact
        matches ends ``duplicate_conflict`` in one transaction. False when the
        journal is in neither state. ``final_path`` is kept when ``moved`` or when
        ``placed`` (a prepared journal whose final name is the work file's own link). The work reservation stays until
        ``release_upload_work``."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT item_uuid, state FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state IN ('prepared', 'moved')",
                (owner, key),
            ).fetchone()
            if row is None:
                return False
            return self._record_upload_conflict_in(
                conn, owner_id=owner, operation_uuid=key, item_uuid=row["item_uuid"],
                track_uuids=track_uuids, now=now, clear_final_path=row["state"] == "prepared" and not placed,
                drop_work_reservation=False)

    def release_upload_work(self, *, owner_id: int, operation_uuid: str) -> None:
        """Drop the operation's durable ``upload_work`` reservation row."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND purpose = ? AND subject_ref = ?",
                (owner, UPLOAD_WORK, key),
            )

    def fail_upload_publish(
        self, *, owner_id: int, operation_uuid: str, error_code: str, error_message: str, now: int,
        placed: bool = False, retryable: bool = True,
    ) -> bool:
        """A commit that failed in steps 3-5 (not a duplicate conflict) ends in
        one transaction guarded on journal state ``prepared`` or ``moved`` (False,
        nothing written, otherwise): journal ``failed`` (``final_path`` NULL unless this
        operation placed a file there: ``placed``, or a ``moved`` journal), item back to ``review_ready``
        with a new review version and a retryable error. Reservations, the
        source and its quota row are untouched."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT item_uuid, state FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state IN ('prepared', 'moved')",
                (owner, key),
            ).fetchone()
            if row is None:
                return False
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'failed', error_code = ?, updated_at = ?"
                + (", final_path = NULL" if row["state"] == "prepared" and not placed else "")
                + " WHERE owner_id = ? AND operation_uuid = ?",
                (error_code, now, owner, key),
            )
            cursor = conn.execute(
                "UPDATE upload_items SET state = 'review_ready', review_version = review_version + 1,"
                " error_code = ?, error_message = ?, error_retryable = ?, lease_boot_id = NULL,"
                " updated_at = ? WHERE owner_id = ? AND item_uuid = ? AND state = 'committing'",
                (error_code, error_message, int(retryable), now, owner, row["item_uuid"]),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("commit item left committing under the write lock")
            self._touch_upload_batch_in(conn, owner, row["item_uuid"], now)
            return True

    def record_upload_publish_art(
        self, *, owner_id: int, operation_uuid: str, cover_art_id: int, cover_art_created: bool, now: int
    ) -> bool:
        """Journal re-registered cover art, guarded on journal state ``moved``."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET cover_art_id = ?, cover_art_created = ?,"
                " updated_at = ? WHERE owner_id = ? AND operation_uuid = ? AND state = 'moved'",
                (cover_art_id, 1 if cover_art_created else 0, now, owner, key),
            )
            return cursor.rowcount == 1

    def mark_upload_commit_moved(self, *, owner_id: int, operation_uuid: str, now: int) -> bool:
        """journal prepared -> moved in one transaction; False when it was not prepared."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cursor = conn.execute(
                "UPDATE upload_commit_journal SET state = 'moved', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'prepared'",
                (now, owner, key),
            )
            return cursor.rowcount == 1

    def publish_upload_commit(
        self, *, owner_id: int, operation_uuid: str, track, stat, fingerprinter_present: bool,
        work_removed: bool, now: int,
    ) -> tuple[str, object]:
        """Step 5, one BEGIN IMMEDIATE transaction guarded on journal state
        ``moved``: repeat the exact-match rule, then insert the track, mark the
        item and journal ``imported`` and, when the work link is gone, drop the
        work reservation. Returns ("imported", revision), ("duplicate_conflict",
        uuids) with nothing written, or ("not_moved", None)."""
        from app.services.audio_identity import identity_from_columns

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT * FROM upload_commit_journal"
                " WHERE owner_id = ? AND operation_uuid = ? AND state = 'moved'",
                (owner, key),
            ).fetchone()
            if row is None:
                return "not_moved", None
            frozen = json.loads(row["acknowledged_duplicates"])
            acknowledged, unacknowledged = self._exact_library_matches_in(
                conn, owner_id=owner, item_uuid=row["item_uuid"],
                identity=identity_from_columns(dict(row)),
                acknowledged=frozen,
                exclude=frozenset({row["reserved_track_uuid"]}),
            )
            if unacknowledged:
                if not self._record_upload_conflict_in(
                    conn, owner_id=owner, operation_uuid=key, item_uuid=row["item_uuid"],
                    track_uuids=unacknowledged, now=now, clear_final_path=False,
                    drop_work_reservation=work_removed,
                ):
                    raise RuntimeError("upload item is not committing")
                return "duplicate_conflict", unacknowledged
            revision = self._insert_track_in(
                conn, track, owner_id=owner, fingerprinter_present=fingerprinter_present, stat=stat)
            self._seed_dismissed_candidates_in(conn, track.uuid_id, acknowledged)
            for kind, table, column, refs in (
                ("library_track", "tracks", "uuid_id", frozen.get("library_tracks", ())),
                ("staged_item", "upload_items", "item_uuid", frozen.get("staged_items", ())),
            ):
                if refs:
                    conn.execute(
                        "INSERT OR IGNORE INTO upload_item_acknowledgements"
                        " (owner_id, item_uuid, subject_kind, subject_ref)"
                        f" SELECT ?, ?, ?, {column} FROM {table}"
                        f" WHERE owner_id = ? AND {column} IN ({', '.join('?' * len(refs))})",
                        (owner, row["item_uuid"], kind, owner, *refs),
                    )
            if row["digest_check"] == "unverified":
                self._mark_audio_identity_stale_in(conn, track.uuid_id, "tag_write")
            if not self._transition_upload_item_in(
                conn, owner_id=owner, item_uuid=row["item_uuid"], from_states=("committing",),
                to_state="imported", now=now,
                fields={"result_track_uuid": track.uuid_id, "result_revision": revision,
                        "final_path": row["final_path"], "lease_boot_id": None,
                        "error_code": None, "error_message": None, "error_retryable": None},
            ):
                raise RuntimeError("upload item is not committing")
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'imported', updated_at = ?"
                " WHERE owner_id = ? AND operation_uuid = ?",
                (now, owner, key),
            )
            if work_removed:
                conn.execute(
                    "DELETE FROM storage_reservations"
                    " WHERE owner_id = ? AND purpose = ? AND subject_ref = ?",
                    (owner, UPLOAD_WORK, key),
                )
            return "imported", revision

    def prepare_upload_commit(
        self, *, owner_id: int, operation_uuid: str, boot_id: str, final_path: str,
        final_metadata: str, identity_columns: dict, digest_check: str,
        reservation_id: int, now: int,
    ) -> dict | None:
        """committing -> prepared in one transaction, guarded by this boot's
        lease (None, nothing written, when it no longer holds). Settles the
        work-copy reservation into the durable ``upload_work`` row and clears
        the item's lease. Returns the prepared journal row."""
        from app.services.audio_identity import FINGERPRINT_COLUMNS, IDENTITY_COLUMNS

        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        if not set(identity_columns) <= {*IDENTITY_COLUMNS, *FINGERPRINT_COLUMNS}:
            raise ValueError("unknown commit identity column")
        # A fingerprint column the identity does not carry is NULL = recompute.
        values = {**dict.fromkeys(FINGERPRINT_COLUMNS), **identity_columns}
        names = sorted(values)
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT item_uuid FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = 'committing' AND lease_boot_id = ?",
                (owner, key, boot_id),
            ).fetchone()
            if held is None:
                return None
            assignments = "".join(f", {n} = ?" for n in names)
            conn.execute(
                "UPDATE upload_commit_journal SET state = 'prepared', final_path = ?,"
                " final_metadata = ?, digest_check = ?, lease_boot_id = NULL, updated_at = ?"
                f"{assignments} WHERE owner_id = ? AND operation_uuid = ?",
                (final_path, final_metadata, digest_check, now,
                 *(values[n] for n in names), owner, key),
            )
            self._settle_storage_in(conn, reservation_id, purpose=UPLOAD_WORK)
            conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE owner_id = ? AND item_uuid = ?"
                " AND lease_boot_id = ?",
                (owner, held["item_uuid"], boot_id),
            )
            return dict(conn.execute(
                "SELECT * FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?",
                (owner, key),
            ).fetchone())

    def get_upload_preview(self, item_uuid, *, owner_id: int) -> dict | None:
        """``source_path`` and ``detected_metadata`` of the owner's ``review_ready``
        item; None for anything else (unknown, foreign, other state)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT source_path, detected_metadata FROM upload_items"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'review_ready'",
                (owner, key),
            ).fetchone()
        return None if row is None else dict(row)

    def get_upload_item_source_path(self, item_uuid, *, owner_id: int) -> str | None:
        """The recorded source path of an owned item (server-internal, never an API field)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection() as conn:
            row = conn.execute(
                "SELECT source_path FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                (owner, key),
            ).fetchone()
        return None if row is None else row["source_path"]

    def release_removed_upload_source(
        self, item_uuid, *, owner_id: int, source_path: str, now: int,
        from_states=("cancelled",),
    ) -> bool:
        """After an ended item's source file is gone: clear ``source_path`` and
        delete its ``upload_source`` quota row in one transaction, guarded on the
        item being in one of ``from_states`` (``cancelled``, ``failed``, ``expanded``,
        ``imported``, ``duplicate`` or ``expired``) and on that path."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        states = tuple(from_states)
        allowed = set(SOURCE_RELEASE_STATES)
        if not states or not set(states) <= allowed:
            raise ValueError("from_states must be among " + ", ".join(sorted(allowed)))
        marks = ",".join("?" for _ in states)
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET source_path = NULL, updated_at = ?"
                f" WHERE owner_id = ? AND item_uuid = ? AND state IN ({marks}) AND source_path = ?",
                (now, owner, key, *states, source_path),
            )
            if cur.rowcount != 1:
                return False
            conn.execute(
                "DELETE FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                " AND purpose = ?",
                (owner, key, UPLOAD_SOURCE),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return True

    def upload_child_usage(self, *, owner_id: int, batch_uuid: str, parent_item_uuid: str) -> tuple[int, int]:
        """Count and declared bytes of the batch's archive children of other archives."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT COUNT(*) AS n, COALESCE(SUM(expected_bytes), 0) AS b FROM upload_items"
                " WHERE owner_id = ? AND batch_uuid = ? AND parent_item_uuid IS NOT NULL"
                " AND parent_item_uuid <> ?",
                (owner, batch_uuid, parent_item_uuid),
            ).fetchone()
        return row["n"], row["b"]

    def ensure_upload_manifest(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        members: list, skipped: int, now: int,
    ) -> list[dict] | None:
        """Create the archive's ordered child rows once (fresh item uuids) and
        return them; an archive that already has children gets those back.
        None, nothing written, when the parent is no longer ``validating`` under
        this boot's lease and review_version."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            parent = conn.execute(
                "SELECT batch_uuid, selection_index FROM upload_items WHERE owner_id = ? AND item_uuid = ?"
                " AND state = 'validating' AND lease_boot_id = ? AND review_version = ?",
                (owner, key, boot_id, review_version),
            ).fetchone()
            if parent is None:
                return None
            existing = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND batch_uuid = ?"
                " AND parent_item_uuid = ? LIMIT 1",
                (owner, parent["batch_uuid"], key),
            ).fetchone()
            if existing is None:
                for name, declared in members:
                    conn.execute(
                        "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, parent_item_uuid,"
                        " filename, selection_index, member_order_key, expected_bytes, state,"
                        " created_at, updated_at, progress_at)"
                        " VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'validating', ?, ?, ?)",
                        (owner, str(uuid.uuid4()), parent["batch_uuid"], key, name,
                         parent["selection_index"], name, declared, now, now, now),
                    )
                conn.execute(
                    "UPDATE upload_items SET kind = 'zip', skipped_members = ?, updated_at = ?"
                    " WHERE owner_id = ? AND item_uuid = ?",
                    (skipped, now, owner, key),
                )
            rows = conn.execute(
                "SELECT item_uuid, batch_uuid, member_order_key, state FROM upload_items"
                " WHERE owner_id = ? AND batch_uuid = ? AND parent_item_uuid = ?"
                " ORDER BY member_order_key",
                (owner, parent["batch_uuid"], key),
            ).fetchall()
            return [dict(row) for row in rows]

    def finish_upload_expansion(
        self, *, owner_id: int, item_uuid: str, boot_id: str, review_version: int,
        staged: list, reservation_id: int, source_purpose: str, now: int,
    ) -> set | bool:
        """Publish the staged children and end the archive as ``expanded`` in
        one transaction, guarded as ``ensure_upload_manifest`` the set of child uuids
        it published, or False, nothing written, when the guard fails)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            held = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND item_uuid = ?"
                " AND state = 'validating' AND lease_boot_id = ? AND review_version = ?",
                (owner, key, boot_id, review_version),
            ).fetchone()
            if held is None:
                return False
            published = set()
            for child, source_path, nbytes, sha256 in staged:
                cur = conn.execute(
                    "UPDATE upload_items SET source_path = ?, received_bytes = ?, received_sha256 = ?,"
                    " progress_at = ?, updated_at = ? WHERE owner_id = ? AND item_uuid = ?"
                    " AND parent_item_uuid = ? AND state = 'validating'",
                    (source_path, nbytes, sha256, now, now, owner, child, key),
                )
                if cur.rowcount == 1:
                    published.add(child)
                    conn.execute(
                        "INSERT INTO storage_reservations"
                        " (owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at)"
                        " VALUES (?, ?, ?, ?, NULL, unixepoch())",
                        (owner, source_purpose, child, nbytes),
                    )
            conn.execute("DELETE FROM storage_reservations WHERE id = ?", (reservation_id,))
            conn.execute(
                "UPDATE upload_items SET state = 'expanded', lease_boot_id = NULL, error_code = NULL,"
                " error_message = NULL, error_retryable = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ?",
                (now, owner, key),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return published

    def list_upload_children(self, *, owner_id: int, item_uuid: str) -> list[dict]:
        """An archive's child rows (ids and state only)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection() as conn:
            # The parent's batch (a missing parent has no children: NULL matches nothing).
            rows = conn.execute(
                "SELECT item_uuid, batch_uuid, state FROM upload_items"
                " WHERE owner_id = ? AND batch_uuid = (SELECT batch_uuid FROM upload_items"
                " WHERE owner_id = ? AND item_uuid = ?) AND parent_item_uuid = ?"
                " ORDER BY member_order_key",
                (owner, owner, key, key),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_upload_commit_journals_to_resume(
        self, states: tuple = ("prepared", "moved")
    ) -> list[dict]:
        """Startup: every owner's commit journal in ``states`` (default still
        ``prepared`` or ``moved``)."""
        allowed = {"committing", "prepared", "moved"}
        if not states or not set(states) <= allowed:
            raise ValueError("states must be among " + ", ".join(sorted(allowed)))
        marks = ",".join("?" for _ in states)
        with self._connection() as conn:
            rows = conn.execute(
                f"SELECT * FROM upload_commit_journal WHERE state IN ({marks})"
                " ORDER BY created_at, operation_uuid",
                tuple(states),
            ).fetchall()
        return [dict(row) for row in rows]

    def list_finished_upload_commit_journals(self, *, updated_before: int | None = None) -> list[dict]:
        """Startup and janitor: every owner's commit journal that ended (``imported``,
        ``duplicate_conflict`` or ``failed``) and still waits for its clean-up;
        with ``updated_before``, only those last updated at or before it."""
        bound = "" if updated_before is None else " AND updated_at <= ?"
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT * FROM upload_commit_journal"
                " WHERE state IN ('imported', 'duplicate_conflict', 'failed')" + bound
                + " ORDER BY created_at, operation_uuid",
                () if updated_before is None else (updated_before,),
            ).fetchall()
        return [dict(row) for row in rows]

    def delete_finished_upload_commit_journal(
        self, *, owner_id: int, operation_uuid: str, state: str
    ) -> bool:
        """Delete a cleaned-up journal row, guarded on its finished ``state`` and on
        the operation holding no ``upload_work`` reservation. The receipt stays."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(operation_uuid)))
        if state not in ("imported", "duplicate_conflict", "failed"):
            raise ValueError("state must be a finished journal state")
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "DELETE FROM upload_commit_journal WHERE owner_id = ? AND operation_uuid = ?"
                " AND state = ? AND NOT EXISTS (SELECT 1 FROM storage_reservations"
                " WHERE owner_id = ? AND purpose = ? AND subject_ref = ?)",
                (owner, key, state, owner, UPLOAD_WORK, key),
            )
            return cur.rowcount == 1

    def list_expirable_upload_items(self, *, progress_before: int) -> list[dict]:
        """Janitor: every owner's unconfirmed item (``allocated``, ``review_ready``,
        ``duplicate_conflict``, ``failed``) whose last progress is at or before
        ``progress_before``."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, state FROM upload_items WHERE state IN"
                " ('allocated', 'review_ready', 'duplicate_conflict', 'failed')"
                " AND progress_at <= ? ORDER BY owner_id, item_uuid",
                (progress_before,),
            ).fetchall()
        return [dict(row) for row in rows]

    def expire_upload_item(
        self, item_uuid, *, owner_id: int, from_state: str, progress_before: int, now: int
    ) -> bool:
        """Janitor: an owned unconfirmed item becomes ``expired`` only if it is
        still in ``from_state`` and its progress is still at or before ``progress_before``
        (a concurrent user action wins)."""
        if from_state not in ("allocated", "review_ready", "duplicate_conflict", "failed"):
            raise ValueError("from_state must be an unconfirmed item state")
        with self._connection(commit=True, immediate=True) as conn:
            return self._transition_upload_item_in(
                conn, owner_id=owner_id, item_uuid=item_uuid, from_states=(from_state,),
                to_state="expired", now=now, fields={"lease_boot_id": None},
                progress_at_most=progress_before)

    def list_ended_upload_items(self) -> list[dict]:
        """Janitor: every owner's item in an ended state with its recorded paths."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid, state, source_path, part_path"
                f" FROM upload_items WHERE state IN ({_ENDED_MARKS})"
                " ORDER BY owner_id, batch_uuid, item_uuid",
                ENDED_STATES,
            ).fetchall()
        return [dict(row) for row in rows]

    def count_live_upload_items(self, *, owner_id: int, batch_uuid: str) -> int:
        """Items of an owned batch that are not in an ended state."""
        owner = _require_owner(owner_id)
        with self._connection() as conn:
            return conn.execute(
                "SELECT count(*) FROM upload_items WHERE owner_id = ? AND batch_uuid = ?"
                f" AND state NOT IN ({_ENDED_MARKS})",
                (owner, str(uuid.UUID(str(batch_uuid))), *ENDED_STATES),
            ).fetchone()[0]

    def list_upload_batches_for_retention(self, *, updated_before: int) -> list[dict]:
        """Janitor: every owner's batch last updated at or before ``updated_before``,
        with its item uuids. A candidate list only; ``prune_upload_batch`` decides."""
        with self._connection() as conn:
            batches = conn.execute(
                "SELECT owner_id, batch_uuid FROM upload_batches WHERE updated_at <= ?"
                " ORDER BY owner_id, batch_uuid",
                (updated_before,),
            ).fetchall()
            out = []
            for b in batches:
                items = conn.execute(
                    "SELECT item_uuid FROM upload_items WHERE owner_id = ? AND batch_uuid = ?"
                    " ORDER BY item_uuid",
                    (b["owner_id"], b["batch_uuid"]),
                ).fetchall()
                out.append({"owner_id": b["owner_id"], "batch_uuid": b["batch_uuid"],
                            "item_uuids": [i["item_uuid"] for i in items]})
        return out

    def prune_upload_batch(
        self, *, owner_id: int, batch_uuid: str, updated_before: int, dry_run: bool = False
    ) -> bool:
        """Retention: delete an owned batch and its items (identity and
        acknowledgement rows cascade) when, checked in this one write
        transaction, every item is ended and last updated at or before
        ``updated_before``, so is the batch, no item records a source or part
        path, no reservation names an item or its commit operation, and no
        commit journal remains. Receipts are never touched. False: kept.
        ``dry_run`` only answers whether it would prune."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(batch_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            batch = conn.execute(
                "SELECT 1 FROM upload_batches WHERE owner_id = ? AND batch_uuid = ?"
                " AND updated_at <= ?",
                (owner, key, updated_before),
            ).fetchone()
            if batch is None:
                return False
            kept = conn.execute(
                "SELECT 1 FROM upload_items WHERE owner_id = ? AND batch_uuid = ? AND ("
                f" state NOT IN ({_ENDED_MARKS})"
                " OR updated_at > ? OR source_path IS NOT NULL OR part_path IS NOT NULL"
                " OR EXISTS (SELECT 1 FROM storage_reservations r WHERE r.owner_id = upload_items.owner_id"
                "            AND r.subject_ref = upload_items.item_uuid)"
                " OR EXISTS (SELECT 1 FROM upload_commit_journal j WHERE j.owner_id = upload_items.owner_id"
                "            AND j.item_uuid = upload_items.item_uuid)"
                ") LIMIT 1",
                (owner, key, *ENDED_STATES, updated_before),
            ).fetchone()
            if kept is not None:
                return False
            if dry_run:
                return True
            conn.execute(
                "DELETE FROM upload_batches WHERE owner_id = ? AND batch_uuid = ?", (owner, key))
            return True

    def list_expanded_upload_archives(self) -> list[dict]:
        """Startup: expanded archives that still record their source file."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, source_path FROM upload_items"
                " WHERE state = 'expanded' AND source_path IS NOT NULL ORDER BY owner_id, item_uuid"
            ).fetchall()
        return [dict(row) for row in rows]

    def list_ended_upload_children(self) -> list[dict]:
        """Startup: cancelled or failed archive children that record no source."""
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT owner_id, item_uuid, batch_uuid FROM upload_items"
                " WHERE parent_item_uuid IS NOT NULL AND state IN ('cancelled', 'failed')"
                " AND source_path IS NULL ORDER BY owner_id, item_uuid"
            ).fetchall()
        return [dict(row) for row in rows]

    def reconcile_upload_validation(self, *, boot_id: str) -> int:
        """Startup: ``validating`` items leased by another boot go back to the
        queue (lease cleared). Idempotent; returns how many."""
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE state = 'validating'"
                " AND lease_boot_id IS NOT NULL AND lease_boot_id <> ?",
                (boot_id,),
            )
            return cur.rowcount

    def release_upload_validation_lease(self, *, owner_id: int, item_uuid: str, boot_id: str) -> bool:
        """A step that ends without a result clears this boot's lease: a still
        ``validating`` item goes back to the queue, a ``cancelled`` one carries no
        stale lease."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET lease_boot_id = NULL WHERE owner_id = ? AND item_uuid = ?"
                " AND state IN ('validating', 'cancelled') AND lease_boot_id = ?",
                (owner, key, boot_id),
            )
            return cur.rowcount == 1

    @staticmethod
    def _settle_upload_quota_in(
        conn, owner: int, item_uuid: str, *, settled_purpose: str, nbytes: int,
        reservation_id: int | None = None, receive_purpose: str | None = None,
    ) -> None:
        """A received file always ends with exactly one durable quota row: settle
        the item's receive row (the given one, else those of ``receive_purpose``),
        and restore the row if none exists. The bytes are on disk: no admission."""
        if reservation_id is not None:
            ids = [reservation_id]
        else:
            ids = [
                row["id"]
                for row in conn.execute(
                    "SELECT id FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
                    " AND purpose IN (?, ?) ORDER BY id",
                    (owner, item_uuid, receive_purpose, settled_purpose),
                )
            ]
        if ids:
            DatabaseCore._settle_storage_in(conn, ids[0], purpose=settled_purpose)
            for extra in ids[1:]:
                conn.execute("DELETE FROM storage_reservations WHERE id = ?", (extra,))
        has_row = conn.execute(
            "SELECT 1 FROM storage_reservations WHERE owner_id = ? AND subject_ref = ?"
            " AND purpose = ?",
            (owner, item_uuid, settled_purpose),
        ).fetchone()
        if has_row is None:
            conn.execute(
                "INSERT INTO storage_reservations"
                " (owner_id, purpose, subject_ref, bytes, lease_boot_id, created_at)"
                " VALUES (?, ?, ?, ?, NULL, unixepoch())",
                (owner, settled_purpose, item_uuid, nbytes),
            )

    def begin_upload_receipt(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str, now: int
    ) -> bool:
        """Claim an allocated item for receiving (allocated -> receiving, leased to
        ``boot_id``) and record its part path before the file exists. False when
        the claim was lost or a cancel is already requested (nothing changes)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        item_key = {"owner_id": owner, "item_uuid": key}
        with self._connection(commit=True, immediate=True) as conn:
            if not job_runtime.claim(
                conn, "upload_items", item_key,
                boot_id=boot_id, from_state="allocated", to_state="receiving",
            ):
                return False
            # A claim ignores the cancel flag on purpose; look at it now.
            if job_runtime.cancel_requested(conn, "upload_items", item_key):
                conn.rollback()
                return False
            conn.execute(
                "UPDATE upload_items SET part_path = ?, received_bytes = 0,"
                " received_sha256 = NULL, error_code = NULL, error_message = NULL,"
                " error_retryable = NULL, updated_at = ?, progress_at = ?"
                " WHERE owner_id = ? AND item_uuid = ?",
                (part_path, now, now, owner, key),
            )
            self._touch_upload_batch_in(conn, owner, key, now)
            return True

    def record_upload_progress(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str,
        received_bytes: int, now: int,
    ) -> bool:
        """Persist how many bytes a receipt has written. False when the guard no
        longer holds (not receiving, another lease or part, or a cancel is requested)."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET received_bytes = ?, progress_at = ?, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND lease_boot_id = ? AND part_path = ? AND cancel_requested = 0",
                (received_bytes, now, now, owner, key, boot_id, part_path),
            )
            return cur.rowcount == 1

    def complete_upload_receipt(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str, source_path: str,
        received_bytes: int, received_sha256: str, reservation_id: int,
        settled_purpose: str, now: int,
    ) -> bool:
        """receiving -> validating, guarded by this boot's lease and part path,
        with the upload's reservation settled in the same transaction. False
        (nothing changed) when the guard no longer holds."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = 'validating', source_path = ?,"
                " received_bytes = ?, received_sha256 = ?, part_path = NULL,"
                " lease_boot_id = NULL, progress_at = ?, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND lease_boot_id = ? AND part_path = ?",
                (source_path, received_bytes, received_sha256, now, now,
                 owner, key, boot_id, part_path),
            )
            if cur.rowcount != 1:
                return False
            self._touch_upload_batch_in(conn, owner, key, now)
            self._settle_upload_quota_in(
                conn, owner, key, settled_purpose=settled_purpose,
                nbytes=received_bytes, reservation_id=reservation_id,
            )
            return True

    def end_upload_receipt(
        self, item_uuid, *, owner_id: int, boot_id: str, part_path: str, to_state: str,
        error_code: str, error_message: str, error_retryable: bool, now: int,
        keep_part: bool = False,
    ) -> bool:
        """An uncommitted receipt ends: receiving -> ``to_state`` with an error,
        guarded by lease and part path. Where the part path is still this
        receipt's, it and the lease are cleared even if the state already moved.
        ``keep_part`` keeps the part path recorded (a leftover that could not be
        removed): only the lease is cleared."""
        owner = _require_owner(owner_id)
        key = str(uuid.UUID(str(item_uuid)))
        with self._connection(commit=True, immediate=True) as conn:
            cur = conn.execute(
                "UPDATE upload_items SET state = ?, error_code = ?, error_message = ?,"
                " error_retryable = ?, received_bytes = 0,"
                " part_path = CASE WHEN ? THEN part_path ELSE NULL END,"
                " lease_boot_id = NULL, updated_at = ?"
                " WHERE owner_id = ? AND item_uuid = ? AND state = 'receiving'"
                " AND lease_boot_id = ? AND part_path = ?",
                (to_state, error_code, error_message, int(error_retryable), int(keep_part), now,
                 owner, key, boot_id, part_path),
            )
            changed = cur.rowcount == 1
            if changed:
                self._touch_upload_batch_in(conn, owner, key, now)
            else:
                conn.execute(
                    "UPDATE upload_items SET lease_boot_id = NULL,"
                    " part_path = CASE WHEN ? THEN part_path ELSE NULL END"
                    " WHERE owner_id = ? AND item_uuid = ? AND part_path = ?",
                    (int(keep_part), owner, key, part_path),
                )
            return changed

    def transition_upload_item(
        self, item_uuid, *, owner_id: int, from_states, to_state: str, now: int,
        fields: dict | None = None,
    ) -> tuple[bool, dict | None]:
        with self._connection(commit=True, immediate=True) as conn:
            changed = self._transition_upload_item_in(
                conn, owner_id=owner_id, item_uuid=item_uuid, from_states=from_states,
                to_state=to_state, now=now, fields=fields,
            )
            row = self._upload_item_in(conn, owner_id=owner_id, item_uuid=item_uuid)
        return changed, row

    @staticmethod
    def _upload_item_dict(row) -> dict:
        return {column: row[column] for column in _UPLOAD_ITEM_API_COLUMNS}

    @staticmethod
    def _seed_dismissed_candidates_in(conn, uuid_id: str, partner_uuids) -> int:
        """Mark ``uuid_id`` and each partner as "keep both" (spec section 7).

        Runs on the caller's connection and inside its transaction; it never
        opens, commits or closes anything. Inserts canonical exact pairs as
        ``dismissed``, or sets an existing open pair to dismissed (its kind,
        band and score are kept). Only live partners of the subject's owner
        count; an unknown or non-live subject changes nothing. Returns the
        number of rows inserted or dismissed.
        """
        # Local import: app.services' package init imports this module (cycle).
        from app.services.duplicate_detection import SEEDED_MATCHER_VERSION

        owner_row = conn.execute(
            "SELECT owner_id FROM live_tracks WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()
        if owner_row is None:
            return 0
        owner = owner_row[0]
        changed = 0
        for partner in sorted(set(partner_uuids) - {uuid_id}):
            uuid_a, uuid_b = min(uuid_id, partner), max(uuid_id, partner)
            changed += conn.execute(
                "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
                "sort_score, matcher_version, detected_at, status, status_changed_at) "
                "SELECT ?, ?, ?, 'exact', 0, 1.0, ?, unixepoch(), 'dismissed', unixepoch() "
                "WHERE EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = ? AND owner_id = ?) "
                "ON CONFLICT(uuid_a, uuid_b) DO UPDATE SET status = 'dismissed', "
                "status_changed_at = excluded.status_changed_at "
                "WHERE track_duplicate_candidates.status = 'open'",
                (owner, uuid_a, uuid_b, SEEDED_MATCHER_VERSION, partner, owner),
            ).rowcount
        return changed
