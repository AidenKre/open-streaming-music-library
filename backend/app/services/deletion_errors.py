"""SC-22 errors of Phase 8 deletion. The one home for deletion error codes (O9, O12).
The item code lists of the job read model are in ``app/core/deletion_states.py``."""

from fastapi import HTTPException

from app.core.api_errors import ApiError

TRACK_PENDING_DELETION = "track_pending_deletion"


class DeletionError(ApiError):
    """An error of the deletion and duplicate-review routes."""


def track_pending_deletion_error(status: int) -> HTTPException:
    return DeletionError(
        status, TRACK_PENDING_DELETION, "This track is being deleted.", retryable=True
    ).to_http()


def library_delete_disabled() -> DeletionError:
    return DeletionError(
        403,
        "library_delete_disabled",
        "Server deletion is turned off on this server.",
        retryable=False,
    )


def pair_not_found() -> DeletionError:
    return DeletionError(404, "pair_not_found", "Duplicate pair not found.", retryable=False)


def operation_conflict() -> DeletionError:
    return DeletionError(
        409,
        "operation_conflict",
        "This operation ID was already used for a different request.",
        retryable=False,
    )


def deletion_job_not_found() -> DeletionError:
    return DeletionError(
        404, "deletion_job_not_found", "Deletion job not found.", retryable=False
    )
