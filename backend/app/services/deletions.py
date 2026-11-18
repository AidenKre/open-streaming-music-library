"""Deletion rules layer (Phase 8 spec §4). Routes stay thin; the database only stores."""

import json

from app.core.keyset_cursor import decode_cursor, page_rows
from app.database.operation_receipts import OperationConflict
from app.services.deletion_errors import (
    ITEM_DETAIL_CODES,
    ITEM_ERROR_CODES,
    deletion_job_not_found,
    operation_conflict,
)
from app.services.deletion_worker import master_exists_in_root
from app.models.deletions import (
    DeletionJobItemOut,
    DeletionJobOut,
    DeletionJobPage,
    DeletionJobSummaryOut,
    DeletionPreviewRequest,
    DeletionPreviewResponse,
    DeletionPreviewTarget,
)


def preview(library, request: DeletionPreviewRequest) -> DeletionPreviewResponse:
    """Per target, in request order: the caller's current facts and flags.
    Another user's track or tombstone reads as unknown. Writes nothing, and the
    response carries no path."""
    uuids = [str(t.uuid_id) for t in request.targets]
    facts = library.get_deletion_preview_facts(uuids)
    rows = []
    for uuid_id, target in zip(uuids, request.targets):
        row = dict(
            uuid_id=uuid_id, base_revision=target.base_revision, revision=None,
            title=None, artist=None, album=None, master_exists=None, master_size=None,
            unknown=False, already_deleted=False, missing_master=False,
            conflict=False, busy=False,
        )
        fact = facts.get(uuid_id)
        if fact is None:
            row["unknown"] = True
        elif fact["state"] == "tombstone":
            row.update(revision=fact["revision"], already_deleted=True)
        else:
            exists, st = master_exists_in_root(library.root, fact["file_path"])
            row.update(
                revision=fact["revision"], title=fact["title"], artist=fact["artist"],
                album=fact["album"],
                master_exists=exists,
                master_size=st.st_size if exists else None,
                missing_master=exists is False,
                conflict=fact["revision"] != target.base_revision, busy=fact["busy"],
            )
        rows.append(DeletionPreviewTarget(**row))
    return DeletionPreviewResponse(targets=rows)


def aggregate_status(statuses) -> str:
    """Job status derived from the target outcomes (spec §5)."""
    statuses = list(statuses)
    if all(s == "pending" for s in statuses):
        return "pending"
    if any(s in ("pending", "running") for s in statuses):
        return "running"
    done = [s in ("deleted", "already_deleted") for s in statuses]
    if all(done):
        return "succeeded"
    return "failed" if not any(done) else "partial"


def _details(detail_json) -> list[str]:
    try:
        parsed = json.loads(detail_json) if detail_json else []
    except ValueError:
        return []
    if not isinstance(parsed, list):
        return []
    return [c for c in parsed if isinstance(c, str) and c in ITEM_DETAIL_CODES]


def job_out(job: dict) -> DeletionJobOut:
    items = [
        DeletionJobItemOut(
            uuid_id=row["uuid_id"],
            base_revision=row["base_revision"],
            status=row["status"],
            error=row["error_code"] if row["error_code"] in ITEM_ERROR_CODES else None,
            tombstone_revision=row["tombstone_revision"],
            details=_details(row["detail_json"]),
        )
        for row in job["items"]
    ]
    return DeletionJobOut(
        operation_uuid=job["operation_uuid"],
        created_at=job["created_at"],
        status=aggregate_status(i.status for i in items),
        item_count=len(items),
        items=items,
    )


def create_job(library, request, *, now: int) -> tuple[bool, DeletionJobOut]:
    """Accept the job durably (an exact replay returns the same job). Returns
    (created, job)."""
    try:
        created = library.create_deletion_job(request, now=now)
    except OperationConflict:
        raise operation_conflict() from None
    return created, job_out(library.get_deletion_job(str(request.operation_uuid)))


def get_job(library, operation_uuid: str) -> DeletionJobOut:
    """The caller's own job; an unknown or another user's reads as not found."""
    job = library.get_deletion_job(operation_uuid)
    if job is None:
        raise deletion_job_not_found()
    return job_out(job)


def list_jobs(library, after: str | None, limit: int) -> DeletionJobPage:
    cursor = None if after is None else decode_cursor(after, ("int", "uuid"))
    rows = library.list_deletion_jobs(after=cursor, limit=limit + 1)
    page, next_after = page_rows(rows, limit, lambda r: [r["created_at"], r["operation_uuid"]])
    return DeletionJobPage(
        jobs=[
            DeletionJobSummaryOut(
                operation_uuid=r["operation_uuid"],
                created_at=r["created_at"],
                status=aggregate_status(r["state_counts"]),
                item_count=sum(r["state_counts"].values()),
                state_counts=r["state_counts"],
            )
            for r in page
        ],
        next_after=next_after,
    )
