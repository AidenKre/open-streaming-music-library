"""SC-22 errors of the upload API. The one home for upload API errors."""

from fastapi import HTTPException

from app.core.api_errors import api_error


class UploadError(Exception):
    def __init__(self, status, code, message, *, retryable, headers=None, **extra):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
        self.headers = headers
        self.extra = extra

    def to_http(self) -> HTTPException:
        exc = api_error(
            self.status,
            self.code,
            self.message,
            retryable=self.retryable,
            **self.extra,
        )
        if self.headers:
            exc.headers = dict(self.headers)
        return exc


def upload_item_not_cancellable(state: str) -> UploadError:
    return UploadError(
        409,
        "upload_item_not_cancellable",
        "This upload item can no longer be cancelled.",
        retryable=False,
        state=state,
    )


def invalid_cursor() -> UploadError:
    return UploadError(
        422, "invalid_cursor", "The page cursor is not valid.", retryable=False
    )


def upload_batch_not_found() -> UploadError:
    return UploadError(
        404, "upload_batch_not_found", "Upload batch not found.", retryable=False
    )


def upload_batch_expired() -> UploadError:
    return UploadError(
        410, "upload_batch_expired", "This upload batch has expired. Start a new upload.",
        retryable=False,
    )


def upload_item_not_found() -> UploadError:
    return UploadError(
        404, "upload_item_not_found", "Upload item not found.", retryable=False
    )


def upload_limit_exceeded(limit: str, limit_value: int, message: str, **extra) -> UploadError:
    return UploadError(
        413,
        "upload_limit_exceeded",
        message,
        retryable=False,
        limit=limit,
        limit_value=limit_value,
        **extra,
    )


# O4 / DEV-7-02 per-user fairness.
def upload_slots_busy(*, retry_after_s: int) -> UploadError:
    if (
        not isinstance(retry_after_s, int)
        or isinstance(retry_after_s, bool)
        or retry_after_s <= 0
    ):
        raise ValueError("retry_after_s must be a positive int")
    return UploadError(
        503,
        "upload_slots_busy",
        "The server is busy receiving other uploads. Try again shortly.",
        retryable=True,
        headers={"Retry-After": str(retry_after_s)},
        retry_after_s=retry_after_s,
    )


# 7A.2b: the streamed byte receipt.
def upload_item_not_receivable(state: str) -> UploadError:
    return UploadError(
        409,
        "upload_item_not_receivable",
        "This upload item cannot take content in its current state.",
        retryable=False,
        state=state,
    )


def upload_storage_refused(exc) -> UploadError:
    """An InsufficientStorage from the ledger: 507 for disk, 413 for a staged quota.
    The disk and server-wide quota refusals answer with a fixed message and only
    the caller's own size: remaining room and limits would reveal other users'
    totals. A per-user quota reports the caller's own numbers."""
    if exc.code == "staged_quota_exceeded":
        return UploadError(
            413,
            exc.code,
            "The server's staged upload quota is full. Try again later.",
            retryable=True,
            needed=exc.needed,
        )
    if exc.code in ("insufficient_storage", "free_space_unknown"):
        # The free room moves with other users' uploads: report only the caller's size.
        return UploadError(
            507,
            exc.code,
            "The server cannot store this upload right now. Try again later.",
            retryable=True,
            needed=exc.needed,
        )
    status = 413
    extra = {"needed": exc.needed, "available": exc.available}
    if exc.limit is not None:
        extra["limit"] = exc.limit
    return UploadError(status, exc.code, exc.message, retryable=True, **extra)


def upload_interrupted() -> UploadError:
    return UploadError(
        400,
        "upload_interrupted",
        "The upload was interrupted before it completed. Send it again.",
        retryable=True,
    )


def upload_incomplete() -> UploadError:
    return UploadError(
        422,
        "upload_incomplete",
        "The upload ended before all of its bytes arrived. Send it again.",
        retryable=True,
    )


def upload_digest_mismatch() -> UploadError:
    return UploadError(
        422,
        "upload_digest_mismatch",
        "The received bytes do not match the allocated digest.",
        retryable=False,
    )


def upload_disk_full() -> UploadError:
    return UploadError(
        507,
        "insufficient_storage",
        "The server ran out of disk space while receiving the upload.",
        retryable=True,
    )


def upload_write_failed() -> UploadError:
    return UploadError(
        500,
        "upload_write_failed",
        "The server could not write the upload. Try again.",
        retryable=True,
    )


def upload_too_large() -> UploadError:
    return UploadError(
        413,
        "upload_too_large",
        "The upload body is larger than the size it was allocated for.",
        retryable=False,
    )


def upload_length_mismatch() -> UploadError:
    return UploadError(
        422,
        "upload_length_mismatch",
        "The declared content length does not match the allocated size.",
        retryable=False,
    )


def upload_item_cancelled() -> UploadError:
    return UploadError(
        409,
        "upload_item_cancelled",
        "This upload was cancelled.",
        retryable=False,
    )


def upload_idle_timeout() -> UploadError:
    return UploadError(
        408,
        "upload_idle_timeout",
        "No upload data arrived for too long. Send it again.",
        retryable=True,
    )


def upload_transfer_in_progress() -> UploadError:
    return UploadError(
        409,
        "upload_transfer_in_progress",
        "This upload is already being received. Check its status and try again.",
        retryable=True,
    )


def upload_cleanup_failed() -> UploadError:
    return UploadError(
        500,
        "upload_cleanup_failed",
        "The server could not remove the leftovers of this upload.",
        retryable=False,
    )


# 7A.2c: the quick probe of a received upload.
def probe_timeout() -> UploadError:
    return UploadError(
        503,
        "probe_timeout",
        "Checking the upload took too long. Try again.",
        retryable=True,
    )


def probe_unavailable() -> UploadError:
    return UploadError(
        503,
        "probe_unavailable",
        "The server could not run its audio check. Try again later.",
        retryable=True,
    )


def upload_invalid_audio() -> UploadError:
    return UploadError(
        422,
        "upload_invalid_audio",
        "The upload is not a readable audio file.",
        retryable=False,
    )


def upload_unsupported_audio() -> UploadError:
    return UploadError(
        422,
        "upload_unsupported_audio",
        "The upload is audio in a format this server does not accept.",
        retryable=False,
    )


# 7A.2c: failures of a validation step.
def upload_source_missing() -> UploadError:
    return UploadError(
        409,
        "upload_source_missing",
        "The received file is no longer on the server. Send it again.",
        retryable=True,
    )


def upload_archive_unsupported() -> UploadError:
    return UploadError(
        422,
        "upload_archive_unsupported",
        "ZIP archives are not accepted here.",
        retryable=False,
    )


def upload_validation_failed() -> UploadError:
    return UploadError(
        500,
        "upload_validation_failed",
        "The server could not finish checking this upload. Try again.",
        retryable=True,
    )


# 7A.2c: retry.
def upload_review_version_conflict(review_version: int) -> UploadError:
    return UploadError(
        409,
        "upload_review_version_conflict",
        "This upload item changed since you last looked at it.",
        retryable=False,
        review_version=review_version,
    )


def upload_item_not_retryable(state: str) -> UploadError:
    return UploadError(
        409,
        "upload_item_not_retryable",
        "This upload item cannot be retried in its current state.",
        retryable=False,
        state=state,
    )


# 7A.2c: the preview of a staged source.
def range_not_satisfiable(headers: dict[str, str] | None = None) -> UploadError:
    return UploadError(
        416,
        "range_not_satisfiable",
        "The requested byte range cannot be served.",
        retryable=False,
        headers=headers,
    )


# 7A.3a: the commit.
def operation_conflict(
    message: str = "This operation ID was already used for a different request.",
) -> UploadError:
    return UploadError(
        409,
        "operation_conflict",
        message,
        retryable=False,
    )


def upload_item_not_committable(state: str) -> UploadError:
    return UploadError(
        409,
        "upload_item_not_committable",
        "This upload item cannot be imported in its current state.",
        retryable=False,
        state=state,
    )


def tag_write_unsupported() -> UploadError:
    return UploadError(
        422,
        "tag_write_unsupported",
        "This file type cannot take written tags. Import without writing tags.",
        retryable=True,
    )


# 7A.3a: failures before a commit is prepared (all retryable).
def tag_write_failed() -> UploadError:
    return UploadError(
        500,
        "tag_write_failed",
        "The tags could not be written to the copy. Try again or import without writing tags.",
        retryable=True,
    )


def commit_disk_full() -> UploadError:
    return UploadError(
        507,
        "insufficient_storage",
        "The server ran out of disk space while preparing the import.",
        retryable=True,
    )


def upload_commit_failed() -> UploadError:
    return UploadError(
        500,
        "upload_commit_failed",
        "The import could not be prepared. Try again.",
        retryable=True,
    )


def upload_prepared_unreadable() -> UploadError:
    return UploadError(
        500,
        "upload_prepared_unreadable",
        "The server couldn't read the file after preparing it.",
        retryable=True,
    )


def upload_library_links_unsupported() -> UploadError:
    return UploadError(
        500,
        "upload_library_links_unsupported",
        "This server's library cannot take uploaded files (it does not support hard links)."
        " Ask the server's operator.",
        retryable=False,
    )


# 7A.2d: ZIP expansion.
def upload_archive_invalid() -> UploadError:
    return UploadError(
        422,
        "upload_archive_invalid",
        "The ZIP archive is not valid.",
        retryable=False,
    )


def upload_archive_corrupt() -> UploadError:
    return UploadError(
        422,
        "upload_archive_corrupt",
        "The ZIP archive is damaged and could not be read.",
        retryable=False,
    )


def upload_archive_unsafe_path() -> UploadError:
    return UploadError(
        422,
        "upload_archive_unsafe_path",
        "The ZIP archive contains an unsafe file path.",
        retryable=False,
    )


def upload_archive_unsafe_member() -> UploadError:
    return UploadError(
        422,
        "upload_archive_unsafe_member",
        "The ZIP archive contains a file of a kind that is not allowed.",
        retryable=False,
    )


def upload_archive_encrypted() -> UploadError:
    return UploadError(
        422,
        "upload_archive_encrypted",
        "The ZIP archive contains encrypted files, which are not supported.",
        retryable=False,
    )


def upload_archive_unsupported_compression() -> UploadError:
    return UploadError(
        422,
        "upload_archive_unsupported_compression",
        "The ZIP archive uses a compression method that is not supported.",
        retryable=False,
    )


def upload_archive_duplicate_names() -> UploadError:
    return UploadError(
        422,
        "upload_archive_duplicate_names",
        "The ZIP archive contains files with duplicate names.",
        retryable=False,
    )


def upload_archive_nested() -> UploadError:
    return UploadError(
        422,
        "upload_archive_nested",
        "The ZIP archive contains another archive, which is not allowed.",
        retryable=False,
    )


def upload_archive_too_many_members() -> UploadError:
    return UploadError(
        422,
        "upload_archive_too_many_members",
        "The ZIP archive contains too many files.",
        retryable=False,
    )


def upload_archive_too_many_audio() -> UploadError:
    return UploadError(
        422,
        "upload_archive_too_many_audio",
        "The ZIP archive contains too many audio files.",
        retryable=False,
    )


def upload_archive_member_too_large() -> UploadError:
    return UploadError(
        422,
        "upload_archive_member_too_large",
        "A file in the ZIP archive is too large.",
        retryable=False,
    )


def upload_archive_expanded_too_large() -> UploadError:
    return UploadError(
        422,
        "upload_archive_expanded_too_large",
        "The ZIP archive is too large once unpacked.",
        retryable=False,
    )


def upload_archive_ratio_exceeded() -> UploadError:
    return UploadError(
        422,
        "upload_archive_ratio_exceeded",
        "The ZIP archive is compressed suspiciously well and was rejected.",
        retryable=False,
    )


# 7A.3b: resolve-duplicate.
def upload_item_not_resolvable(state: str) -> UploadError:
    return UploadError(
        409,
        "upload_item_not_resolvable",
        "This upload item cannot be closed as a duplicate in its current state.",
        retryable=False,
        state=state,
    )


def upload_duplicate_match_unavailable() -> UploadError:
    return UploadError(
        409,
        "upload_duplicate_match_unavailable",
        "That track is not an available match for this upload item.",
        retryable=False,
    )
