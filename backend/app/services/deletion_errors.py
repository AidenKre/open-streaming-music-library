"""SC-22 errors of Phase 8 deletion. The one home for deletion error codes (O9, O12)."""

from fastapi import HTTPException

from app.core.api_errors import api_error

TRACK_PENDING_DELETION = "track_pending_deletion"

# Closed vocabularies of the deletion job read model (plan O12): nothing outside
# these lists is ever echoed to a client.
ITEM_ERROR_CODES = (
    "not_found", "conflict", "busy", "path_rejected", "rename", "recovery_required",
    "internal_error",
)
ITEM_DETAIL_CODES = ("master_missing", "storage_cleanup_pending")


class DeletionError(Exception):
    def __init__(self, status, code, message, *, retryable, **extra):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.extra = extra

    def to_http(self) -> HTTPException:
        return api_error(
            self.status,
            self.code,
            self.message,
            retryable=self.retryable,
            **self.extra,
        )


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
