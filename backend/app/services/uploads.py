"""Upload rules layer (Phase 7 spec §4).

Lives here: allocation with its limit checks, the DTO builders (item_out,
_batch_out; every route that returns a batch or an item builds it with them),
the read services over the shared keyset cursors (app.core.keyset_cursor), and
cancel (CANCELLABLE lists the states a cancel may leave).
Routes stay thin and turn UploadError into HTTP; the database only stores.
"""

import json
import logging
import os
from pathlib import Path
from dataclasses import asdict

from app.core.keyset_cursor import (
    MAX_CURSOR_CHARS,
    decode_cursor,
    encode_cursor,
    invalid_cursor,
    page_rows,
)
from app.database.database import UploadItemsInUse
from app.services.duplicate_detection import TrackRef
from app.services.path_sanitize import assert_within
from app.services import upload_commit
from app.services.upload_receipt import (
    ReceiptFiles, discard_child_files, owner_dir, remove_then_release, remove_verified,
)
from app.services.upload_validation import duplicate_report_from_json, validation_token_key
from app.database.operation_receipts import OperationConflict
from app.models.api_return_models import UploadLimitsInfo
from app.models.uploads import (
    AllocationRequest,
    AllocationResponse,
    DuplicateCheckOut,
    DuplicateCoverageOut,
    DuplicateMatchOut,
    DuplicateStagedSummary,
    DuplicateTrackSummary,
    ResolveDuplicateOperation,
    UploadBatchOut,
    UploadBatchPage,
    UploadItemError,
    UploadItemOut,
    UploadItemPage,
)
from app.services.upload_errors import (
    operation_conflict,
    UploadError,
    upload_batch_expired,
    upload_batch_not_found,
    upload_duplicate_match_unavailable,
    upload_item_not_cancellable,
    upload_item_not_resolvable,
    upload_item_not_retryable,
    upload_review_version_conflict,
    upload_item_not_found,
    upload_limit_exceeded,
)

logger = logging.getLogger(__name__)


def _duplicate_check(library, stored: str | None) -> DuplicateCheckOut | None:
    """Built at read time from the stored refs (O8); every lookup goes through
    the caller's library, so a ref the caller cannot see reads as unavailable."""
    if stored is None:
        return None
    failed = DuplicateCheckOut(
        version=1, status="failed", no_duplicates_found=False,
        exact=None, fingerprint=None, matches=[],
    )
    try:
        report = duplicate_report_from_json(stored)
        return failed if report is None else _build_check(library, report)
    except Exception as exc:  # a corrupted stored report reads as a failed check
        logger.warning("stored duplicate report unreadable: %s", type(exc).__name__)
        return failed


def _library_track_match(library, uuid_id: str, **base) -> DuplicateMatchOut:
    """One library-track match entry, enriched through the caller's library (a
    track the caller cannot see reads ``available: false``)."""
    track = library.get_track_by_uuid(uuid_id)
    if track is not None and library.is_pending_deletion(uuid_id):
        track = None  # a track being deleted reads like a deleted one
    summary = None
    if track is not None:
        meta = track.metadata
        summary = DuplicateTrackSummary(
            title=meta.title, artist=meta.artist, album=meta.album, codec=meta.codec,
            bitrate_kbps=meta.bitrate_kbps, sample_rate_hz=meta.sample_rate_hz,
            duration_s=meta.duration,
        )
    return DuplicateMatchOut(
        **{**base, "subject_kind": "library_track", "track_uuid": uuid_id,
           "available": track is not None, "track": summary})


def _conflict_matches(library, row: dict) -> list[DuplicateMatchOut] | None:
    """The retained matches of a ``duplicate_conflict`` item, in stored order."""
    stored = row["conflict_track_uuids"]
    if row["state"] != "duplicate_conflict" or stored is None:
        return None
    try:
        uuids = json.loads(stored)
        if not isinstance(uuids, list) or not all(isinstance(u, str) for u in uuids):
            raise ValueError("not a list of uuids")
        return [
            _library_track_match(library, u, kind="exact", band="exact", score=None,
                                 item_uuid=None, track=None, staged_item=None)
            for u in uuids
        ]
    except Exception as exc:
        logger.warning("stored conflict matches unreadable: %s", type(exc).__name__)
        return None


# A staged match is live only in the states the validation worker compares
# against; once its upload ended (cancelled, expired, imported, failed...)
# nothing can be published from it, so it reads like a gone one.
_LIVE_STAGED_MATCH_STATES = ("review_ready", "committing", "duplicate_conflict")


def _build_check(library, report) -> DuplicateCheckOut:
    matches = []
    for m in report.matches:
        base = dict(kind=m.kind, band=m.band, score=m.score,
                    track_uuid=None, item_uuid=None, track=None, staged_item=None)
        if isinstance(m.subject, TrackRef):
            matches.append(_library_track_match(library, m.subject.uuid_id, **base))
        else:
            item = library.get_upload_item(m.subject.item_uuid)
            if item is not None and item["state"] not in _LIVE_STAGED_MATCH_STATES:
                item = None
            summary = None
            if item is not None:
                batch = library.get_upload_batch(item["batch_uuid"])
                summary = DuplicateStagedSummary(
                    filename=item["filename"], batch_uuid=item["batch_uuid"],
                    batch_created_at=None if batch is None else batch["created_at"],
                )
            matches.append(DuplicateMatchOut(
                **{**base, "subject_kind": "staged_item", "item_uuid": m.subject.item_uuid,
                   "available": item is not None, "staged_item": summary}))
    return DuplicateCheckOut(
        version=1, status="complete",
        no_duplicates_found=report.no_duplicates_found(layers=("exact", "fingerprint")),
        exact=DuplicateCoverageOut(**asdict(report.exact)),
        fingerprint=DuplicateCoverageOut(**asdict(report.fingerprint)),
        matches=matches,
    )


def item_out(row: dict, library) -> UploadItemOut:
    error = None
    if row["error_code"] is not None:
        retryable = row["error_retryable"]
        error = UploadItemError(
            code=row["error_code"],
            message=row["error_message"],
            retryable=None if retryable is None else bool(retryable),
        )
    detected = None if row["detected_metadata"] is None else json.loads(row["detected_metadata"])
    return UploadItemOut(
        **{
            key: row[key]
            for key in UploadItemOut.model_fields
            if key not in ("error", "detected_metadata", "tag_write_supported", "duplicate_check",
                           "conflict_matches")
        },
        error=error,
        detected_metadata=detected,
        tag_write_supported=upload_commit.tag_write_supported(detected),
        duplicate_check=_duplicate_check(library, row["duplicate_report"]),
        conflict_matches=_conflict_matches(library, row),
    )


def _batch_out(batch: dict) -> UploadBatchOut:
    return UploadBatchOut(
        batch_uuid=batch["batch_uuid"],
        label=batch["label"],
        created_at=batch["created_at"],
        updated_at=batch["updated_at"],
        item_count=batch["item_count"],
        state_counts=batch["state_counts"],
        items_path=f"/tracks/uploads/{batch['batch_uuid']}/items",
    )


def _check_limits(limits, request: AllocationRequest) -> None:
    """Count, per-file and batch byte limits, in that order; no database access."""
    items = request.items
    if len(items) > limits.max_files_per_batch:
        raise upload_limit_exceeded(
            "max_files_per_batch",
            limits.max_files_per_batch,
            f"This upload has {len(items)} files; the limit is "
            f"{limits.max_files_per_batch}.",
        )
    for item in items:
        if item.byte_length > limits.max_file_bytes:
            raise upload_limit_exceeded(
                "max_file_bytes",
                limits.max_file_bytes,
                f"A file is larger than the limit of {limits.max_file_bytes} bytes.",
                item_uuid=str(item.item_uuid),
            )
    total = sum(item.byte_length for item in items)
    if total > limits.max_batch_bytes:
        raise upload_limit_exceeded(
            "max_batch_bytes",
            limits.max_batch_bytes,
            f"This upload totals {total} bytes; the limit is "
            f"{limits.max_batch_bytes} bytes.",
        )


def allocate(library, limits, request: AllocationRequest, *, now: int):
    """Returns (created, AllocationResponse)."""
    _check_limits(limits, request)
    try:
        created = library.allocate_upload_batch(request, now=now)
    except OperationConflict as exc:
        raise operation_conflict(
            "This upload batch ID was already used for a different request."
        ) from exc
    except UploadItemsInUse as exc:
        raise UploadError(
            409,
            "upload_item_conflict",
            "Some item IDs are already used by another of your uploads.",
            retryable=False,
            conflicting_item_uuids=exc.item_uuids,
        ) from exc
    batch_uuid = str(request.batch_uuid)
    batch = library.get_upload_batch(batch_uuid)
    if batch is None:  # the receipt replays but retention pruned the batch
        raise upload_batch_expired()
    items = library.list_upload_items(batch_uuid, top_level_only=True)
    return created, AllocationResponse(
        batch=_batch_out(batch),
        items=[item_out(row, library) for row in items],
        limits=UploadLimitsInfo(**asdict(limits)),
    )


def get_batch(library, batch_uuid: str) -> UploadBatchOut:
    batch = library.get_upload_batch(batch_uuid)
    if batch is None:
        raise upload_batch_not_found()
    return _batch_out(batch)


def get_item(library, item_uuid: str) -> UploadItemOut:
    row = library.get_upload_item(item_uuid)
    if row is None:
        raise upload_item_not_found()
    return item_out(row, library)


def list_batches(library, after: str | None, limit: int) -> UploadBatchPage:
    cursor = None if after is None else decode_cursor(after, ("int", "uuid"))
    rows = library.list_upload_batches(after=cursor, limit=limit + 1)
    page, next_after = page_rows(rows, limit, lambda r: [r["created_at"], r["batch_uuid"]])
    return UploadBatchPage(batches=[_batch_out(r) for r in page], next_after=next_after)


def _item_cursor_key(row: dict) -> list:
    """The keyset key of an item row; a member key too long for a bounded cursor
    is left null and read back from the item itself."""
    key = [row["selection_index"], row["member_order_key"], row["item_uuid"]]
    if len(encode_cursor(key)) > MAX_CURSOR_CHARS:
        key[1] = None
    return key


def list_items(library, batch_uuid: str, after: str | None, limit: int) -> UploadItemPage:
    cursor = None if after is None else decode_cursor(after, ("int", "str?", "uuid"))
    if library.get_upload_batch(batch_uuid) is None:
        raise upload_batch_not_found()
    if cursor is not None and cursor[1] is None:
        # The key was too long to carry: it is the cursor item's own member key.
        own = library.get_upload_item(cursor[2])
        if own is None or own["batch_uuid"] != batch_uuid or own["selection_index"] != cursor[0]:
            raise invalid_cursor()
        cursor = (cursor[0], own["member_order_key"], cursor[2])
    rows = library.list_upload_items(batch_uuid, after=cursor, limit=limit + 1)
    page, next_after = page_rows(rows, limit, _item_cursor_key)
    return UploadItemPage(items=[item_out(r, library) for r in page], next_after=next_after)


# The states a cancel may leave. A cancelled or expanded ZIP parent also
# cancels its children that are in one of these states
# (Database.cancel_upload_item).
CANCELLABLE = frozenset(
    {"allocated", "receiving", "validating", "review_ready", "duplicate_conflict", "failed"})


def _release_cancelled_source(
    library, item_uuid: str, uploads_root, now: int, from_states=("cancelled", "expanded")
) -> bool:
    """A cancelled item that still records a validated source gives it back:
    remove the file, and only once it is gone clear the path and release its
    quota row together. Anything else stays recorded (logged by type only); the
    cancel itself still succeeds. A receiving item records no source path.
    Returns whether a source was recorded."""
    try:
        recorded = library.get_upload_item_source_path(item_uuid)
        if recorded is None:
            return False
        remove_then_release(
            ReceiptFiles(), Path(recorded),
            lambda: library.release_removed_upload_source(
                item_uuid, source_path=recorded, now=now, from_states=from_states),
            within=owner_dir(uploads_root, library.owner_id), remove=remove_verified)
    except Exception as exc:
        logger.warning("cancelled upload source not released: %s", type(exc).__name__)
    return True


def cancel(library, item_uuid: str, *, now: int, tokens=None, uploads_root=None) -> UploadItemOut:
    """Cancel an item; never waits for a transfer. ``tokens`` (the shared
    CancelTokens) signals a running receipt right after the durable write."""
    changed, row, children = library.cancel_upload_item(
        item_uuid, from_states=sorted(CANCELLABLE), now=now
    )
    if row is None:
        raise upload_item_not_found()
    if changed or row["state"] in ("cancelled", "expanded"):
        owner = library.owner_id
        for uid in [item_uuid, *children]:
            if tokens is not None:
                tokens.cancel((owner, uid))  # the receipt's token
                tokens.cancel(validation_token_key(owner, uid))
            if uploads_root is None:
                continue
            had_source = _release_cancelled_source(library, uid, uploads_root, now)
            if uid != item_uuid and not had_source:
                try:
                    discard_child_files(
                        ReceiptFiles(), uploads_root, owner, {"batch_uuid": row["batch_uuid"], "item_uuid": uid})
                except Exception as exc:
                    logger.warning("cancelled child files not removed: %s", type(exc).__name__)
        return item_out(row, library)
    raise upload_item_not_cancellable(row["state"])


def resolve_duplicate(library, request, item_uuid: str, *, now: int, uploads_root) -> UploadItemOut:
    """Close a review_ready or duplicate_conflict item as a duplicate of one of
    its live library matches (reported, or retained by the conflict)."""
    chosen = str(request.existing_track_uuid)

    def decide(row: dict, is_live) -> tuple[str, str]:
        if row["review_version"] != request.expected_review_version:
            raise upload_review_version_conflict(row["review_version"])
        if row["state"] not in ("review_ready", "duplicate_conflict"):
            raise upload_item_not_resolvable(row["state"])
        kinds: dict[str, str] = {}
        if row["duplicate_report"] is not None:
            try:
                report = duplicate_report_from_json(row["duplicate_report"])
            except ValueError:
                report = None
            for m in () if report is None else report.matches:
                if isinstance(m.subject, TrackRef) and m.kind in ("exact", "fingerprint"):
                    if kinds.get(m.subject.uuid_id) != "exact":
                        kinds[m.subject.uuid_id] = m.kind
        if row["state"] == "duplicate_conflict" and row["conflict_track_uuids"] is not None:
            try:
                retained = json.loads(row["conflict_track_uuids"])
                kinds.update({u: "exact" for u in retained if isinstance(u, str)})  # exact wins
            except ValueError:
                pass
        if chosen not in kinds or not is_live(chosen):
            raise upload_duplicate_match_unavailable()
        return chosen, kinds[chosen]

    try:
        outcome, row = library.resolve_upload_duplicate(
            item_uuid, request_model=ResolveDuplicateOperation(
                item_uuid=item_uuid, request=request),
            decide=decide, now=now)
    except OperationConflict as exc:
        raise operation_conflict() from exc
    if outcome == "not_found":
        raise upload_item_not_found()
    if outcome == "resolved":
        _release_cancelled_source(library, item_uuid, uploads_root, now, from_states=("duplicate",))
    return item_out(row, library)


def retry(library, item_uuid: str, expected_review_version: int, *, now: int, uploads_root):
    """Retry a duplicate_conflict or retryable failed item. Returns the item DTO."""
    def source_present(recorded: str) -> bool:
        # Gone only when verifiably so; anything else the worker will type.
        try:
            assert_within(Path(recorded), owner_dir(uploads_root, library.owner_id))
        except Exception:
            return False  # not inside this owner's folder: not its source
        try:
            os.lstat(recorded)
        except FileNotFoundError:
            return False
        except Exception:
            return True
        return True

    outcome, row = library.retry_upload_item(
        item_uuid, expected_review_version=expected_review_version,
        source_present=source_present, now=now)
    if outcome == "not_found":
        raise upload_item_not_found()
    if outcome == "version_conflict":
        raise upload_review_version_conflict(row["review_version"])
    if outcome == "not_retryable":
        raise upload_item_not_retryable(row["state"])
    return item_out(row, library)


def commit(library, request, item_uuid: str, *, uploads_root, now: int):
    """Accept a commit; returns ``(status, item DTO)``."""
    status, row = upload_commit.accept(
        library, request, item_uuid, uploads_root=uploads_root, now=now)
    return status, item_out(row, library)


def open_preview(library, item_uuid: str, uploads_root):
    """Open the staged source of the caller's own review_ready item for a preview.
    Returns ``(handle, mime)``. Everything that is not servable (no such item,
    another state, a path outside the tree, a missing file, unreadable
    metadata) is the same ``upload_item_not_found``: never a path."""
    stored = library.get_upload_preview(item_uuid)
    if stored is None or stored["source_path"] is None or stored["detected_metadata"] is None:
        raise upload_item_not_found()
    try:
        mime = json.loads(stored["detected_metadata"])["mime"]
        if not isinstance(mime, str) or not mime:
            raise ValueError("no mime")
        path = Path(stored["source_path"])
        assert_within(path, owner_dir(uploads_root, library.owner_id))
        return open(path, "rb"), mime
    except Exception as exc:
        logger.warning("upload preview unavailable: %s", type(exc).__name__)
        raise upload_item_not_found() from None
