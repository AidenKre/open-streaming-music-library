"""SP-AR-BE-05 (refactor BE-TIDY row 9): the full answer of every factory of the
three SC-22 error carriers, ``UploadError`` (``services/upload_errors.py``),
``DeletionError`` (``services/deletion_errors.py``) and ``LastfmError``
(``services/lastfm_errors.py``).

Each row pins what a client receives: the HTTP status, the ``detail`` object
key by key and in order (the JSON body's bytes follow that order), and the
headers. It also pins what the services read back from the error (its class,
``str()``, ``status``, ``code``, ``message``, ``retryable``, ``extra``).
The expected values are typed here by hand, not read from the modules.
"""

import inspect

import pytest
from fastapi import HTTPException

from app.services import deletion_errors, lastfm_errors, upload_errors
from app.services.deletion_errors import DeletionError
from app.services.lastfm_errors import LastfmError
from app.services.storage_ledger import InsufficientStorage
from app.services.upload_errors import UploadError


def _env(code, message, retryable, **extra):
    return {"error": code, "message": message, "retryable": retryable, **extra}


# (row id, factory name, call, carrier class, status, detail, headers)
UPLOAD_ROWS = [
    ("not_cancellable", "upload_item_not_cancellable",
     lambda: upload_errors.upload_item_not_cancellable("committed"), 409,
     _env("upload_item_not_cancellable", "This upload item can no longer be cancelled.",
          False, state="committed"), None),
    ("batch_not_found", "upload_batch_not_found",
     lambda: upload_errors.upload_batch_not_found(), 404,
     _env("upload_batch_not_found", "Upload batch not found.", False), None),
    ("batch_expired", "upload_batch_expired",
     lambda: upload_errors.upload_batch_expired(), 410,
     _env("upload_batch_expired", "This upload batch has expired. Start a new upload.", False),
     None),
    ("item_not_found", "upload_item_not_found",
     lambda: upload_errors.upload_item_not_found(), 404,
     _env("upload_item_not_found", "Upload item not found.", False), None),
    ("limit_exceeded", "upload_limit_exceeded",
     lambda: upload_errors.upload_limit_exceeded("max_file_bytes", 10, "Too big."), 413,
     _env("upload_limit_exceeded", "Too big.", False, limit="max_file_bytes", limit_value=10),
     None),
    ("limit_exceeded_extra", "upload_limit_exceeded",
     lambda: upload_errors.upload_limit_exceeded(
         "max_files_per_batch", 100, "Too many.", count=101, item_uuid="u-1"), 413,
     _env("upload_limit_exceeded", "Too many.", False, limit="max_files_per_batch",
          limit_value=100, count=101, item_uuid="u-1"),
     None),
    ("slots_busy", "upload_slots_busy",
     lambda: upload_errors.upload_slots_busy(retry_after_s=5), 503,
     _env("upload_slots_busy", "The server is busy receiving other uploads. Try again shortly.",
          True, retry_after_s=5),
     {"Retry-After": "5"}),
    ("not_receivable", "upload_item_not_receivable",
     lambda: upload_errors.upload_item_not_receivable("validating"), 409,
     _env("upload_item_not_receivable",
          "This upload item cannot take content in its current state.", False,
          state="validating"),
     None),
    ("storage_staged_quota", "upload_storage_refused",
     lambda: upload_errors.upload_storage_refused(InsufficientStorage(
         "staged_quota_exceeded", "hidden", needed=10, available=3, limit=20)), 413,
     _env("staged_quota_exceeded", "The server's staged upload quota is full. Try again later.",
          True, needed=10),
     None),
    ("storage_disk", "upload_storage_refused",
     lambda: upload_errors.upload_storage_refused(InsufficientStorage(
         "insufficient_storage", "hidden", needed=11, available=4)), 507,
     _env("insufficient_storage",
          "The server cannot store this upload right now. Try again later.", True, needed=11),
     None),
    ("storage_free_unknown", "upload_storage_refused",
     lambda: upload_errors.upload_storage_refused(InsufficientStorage(
         "free_space_unknown", "hidden", needed=12, available=None)), 507,
     _env("free_space_unknown",
          "The server cannot store this upload right now. Try again later.", True, needed=12),
     None),
    ("storage_user_quota", "upload_storage_refused",
     lambda: upload_errors.upload_storage_refused(InsufficientStorage(
         "user_staged_quota_exceeded", "Your quota is full.", needed=13, available=2,
         limit=30)), 413,
     _env("user_staged_quota_exceeded", "Your quota is full.", True, needed=13, available=2,
          limit=30),
     None),
    ("storage_other_no_limit", "upload_storage_refused",
     lambda: upload_errors.upload_storage_refused(InsufficientStorage(
         "some_quota", "No room.", needed=14, available=1)), 413,
     _env("some_quota", "No room.", True, needed=14, available=1),
     None),
    ("interrupted", "upload_interrupted",
     lambda: upload_errors.upload_interrupted(), 400,
     _env("upload_interrupted", "The upload was interrupted before it completed. Send it again.",
          True),
     None),
    ("incomplete", "upload_incomplete",
     lambda: upload_errors.upload_incomplete(), 422,
     _env("upload_incomplete", "The upload ended before all of its bytes arrived. Send it again.",
          True),
     None),
    ("digest_mismatch", "upload_digest_mismatch",
     lambda: upload_errors.upload_digest_mismatch(), 422,
     _env("upload_digest_mismatch", "The received bytes do not match the allocated digest.",
          False),
     None),
    ("disk_full", "upload_disk_full",
     lambda: upload_errors.upload_disk_full(), 507,
     _env("insufficient_storage", "The server ran out of disk space while receiving the upload.",
          True),
     None),
    ("write_failed", "upload_write_failed",
     lambda: upload_errors.upload_write_failed(), 500,
     _env("upload_write_failed", "The server could not write the upload. Try again.", True),
     None),
    ("too_large", "upload_too_large",
     lambda: upload_errors.upload_too_large(), 413,
     _env("upload_too_large", "The upload body is larger than the size it was allocated for.",
          False),
     None),
    ("length_mismatch", "upload_length_mismatch",
     lambda: upload_errors.upload_length_mismatch(), 422,
     _env("upload_length_mismatch",
          "The declared content length does not match the allocated size.", False),
     None),
    ("item_cancelled", "upload_item_cancelled",
     lambda: upload_errors.upload_item_cancelled(), 409,
     _env("upload_item_cancelled", "This upload was cancelled.", False), None),
    ("idle_timeout", "upload_idle_timeout",
     lambda: upload_errors.upload_idle_timeout(), 408,
     _env("upload_idle_timeout", "No upload data arrived for too long. Send it again.", True),
     None),
    ("transfer_in_progress", "upload_transfer_in_progress",
     lambda: upload_errors.upload_transfer_in_progress(), 409,
     _env("upload_transfer_in_progress",
          "This upload is already being received. Check its status and try again.", True),
     None),
    ("cleanup_failed", "upload_cleanup_failed",
     lambda: upload_errors.upload_cleanup_failed(), 500,
     _env("upload_cleanup_failed", "The server could not remove the leftovers of this upload.",
          False),
     None),
    ("probe_timeout", "probe_timeout",
     lambda: upload_errors.probe_timeout(), 503,
     _env("probe_timeout", "Checking the upload took too long. Try again.", True), None),
    ("probe_unavailable", "probe_unavailable",
     lambda: upload_errors.probe_unavailable(), 503,
     _env("probe_unavailable", "The server could not run its audio check. Try again later.",
          True),
     None),
    ("invalid_audio", "upload_invalid_audio",
     lambda: upload_errors.upload_invalid_audio(), 422,
     _env("upload_invalid_audio", "The upload is not a readable audio file.", False), None),
    ("unsupported_audio", "upload_unsupported_audio",
     lambda: upload_errors.upload_unsupported_audio(), 422,
     _env("upload_unsupported_audio",
          "The upload is audio in a format this server does not accept.", False),
     None),
    ("source_missing", "upload_source_missing",
     lambda: upload_errors.upload_source_missing(), 409,
     _env("upload_source_missing",
          "The received file is no longer on the server. Send it again.", True),
     None),
    ("archive_unsupported", "upload_archive_unsupported",
     lambda: upload_errors.upload_archive_unsupported(), 422,
     _env("upload_archive_unsupported", "ZIP archives are not accepted here.", False), None),
    ("validation_failed", "upload_validation_failed",
     lambda: upload_errors.upload_validation_failed(), 500,
     _env("upload_validation_failed",
          "The server could not finish checking this upload. Try again.", True),
     None),
    ("review_version_conflict", "upload_review_version_conflict",
     lambda: upload_errors.upload_review_version_conflict(3), 409,
     _env("upload_review_version_conflict",
          "This upload item changed since you last looked at it.", False, review_version=3),
     None),
    ("not_retryable", "upload_item_not_retryable",
     lambda: upload_errors.upload_item_not_retryable("ready"), 409,
     _env("upload_item_not_retryable",
          "This upload item cannot be retried in its current state.", False, state="ready"),
     None),
    ("range_no_headers", "range_not_satisfiable",
     lambda: upload_errors.range_not_satisfiable(), 416,
     _env("range_not_satisfiable", "The requested byte range cannot be served.", False), None),
    ("range_empty_headers", "range_not_satisfiable",
     lambda: upload_errors.range_not_satisfiable({}), 416,
     _env("range_not_satisfiable", "The requested byte range cannot be served.", False), None),
    ("range_headers", "range_not_satisfiable",
     lambda: upload_errors.range_not_satisfiable({"Content-Range": "bytes */100"}), 416,
     _env("range_not_satisfiable", "The requested byte range cannot be served.", False),
     {"Content-Range": "bytes */100"}),
    ("operation_conflict_default", "operation_conflict",
     lambda: upload_errors.operation_conflict(), 409,
     _env("operation_conflict", "This operation ID was already used for a different request.",
          False),
     None),
    ("operation_conflict_message", "operation_conflict",
     lambda: upload_errors.operation_conflict("This batch ID was used."), 409,
     _env("operation_conflict", "This batch ID was used.", False), None),
    ("not_committable", "upload_item_not_committable",
     lambda: upload_errors.upload_item_not_committable("ready"), 409,
     _env("upload_item_not_committable",
          "This upload item cannot be imported in its current state.", False, state="ready"),
     None),
    ("tag_write_unsupported", "tag_write_unsupported",
     lambda: upload_errors.tag_write_unsupported(), 422,
     _env("tag_write_unsupported",
          "This file type cannot take written tags. Import without writing tags.", True),
     None),
    ("tag_write_failed", "tag_write_failed",
     lambda: upload_errors.tag_write_failed(), 500,
     _env("tag_write_failed",
          "The tags could not be written to the copy. Try again or import without writing tags.",
          True),
     None),
    ("commit_disk_full", "commit_disk_full",
     lambda: upload_errors.commit_disk_full(), 507,
     _env("insufficient_storage",
          "The server ran out of disk space while preparing the import.", True),
     None),
    ("commit_failed", "upload_commit_failed",
     lambda: upload_errors.upload_commit_failed(), 500,
     _env("upload_commit_failed", "The import could not be prepared. Try again.", True), None),
    ("prepared_unreadable", "upload_prepared_unreadable",
     lambda: upload_errors.upload_prepared_unreadable(), 500,
     _env("upload_prepared_unreadable",
          "The server couldn't read the file after preparing it.", True),
     None),
    ("library_links_unsupported", "upload_library_links_unsupported",
     lambda: upload_errors.upload_library_links_unsupported(), 500,
     _env("upload_library_links_unsupported",
          "This server's library cannot take uploaded files (it does not support hard links)."
          " Ask the server's operator.", False),
     None),
    ("archive_invalid", "upload_archive_invalid",
     lambda: upload_errors.upload_archive_invalid(), 422,
     _env("upload_archive_invalid", "The ZIP archive is not valid.", False), None),
    ("archive_corrupt", "upload_archive_corrupt",
     lambda: upload_errors.upload_archive_corrupt(), 422,
     _env("upload_archive_corrupt", "The ZIP archive is damaged and could not be read.", False),
     None),
    ("archive_unsafe_path", "upload_archive_unsafe_path",
     lambda: upload_errors.upload_archive_unsafe_path(), 422,
     _env("upload_archive_unsafe_path", "The ZIP archive contains an unsafe file path.", False),
     None),
    ("archive_unsafe_member", "upload_archive_unsafe_member",
     lambda: upload_errors.upload_archive_unsafe_member(), 422,
     _env("upload_archive_unsafe_member",
          "The ZIP archive contains a file of a kind that is not allowed.", False),
     None),
    ("archive_encrypted", "upload_archive_encrypted",
     lambda: upload_errors.upload_archive_encrypted(), 422,
     _env("upload_archive_encrypted",
          "The ZIP archive contains encrypted files, which are not supported.", False),
     None),
    ("archive_unsupported_compression", "upload_archive_unsupported_compression",
     lambda: upload_errors.upload_archive_unsupported_compression(), 422,
     _env("upload_archive_unsupported_compression",
          "The ZIP archive uses a compression method that is not supported.", False),
     None),
    ("archive_duplicate_names", "upload_archive_duplicate_names",
     lambda: upload_errors.upload_archive_duplicate_names(), 422,
     _env("upload_archive_duplicate_names",
          "The ZIP archive contains files with duplicate names.", False),
     None),
    ("archive_nested", "upload_archive_nested",
     lambda: upload_errors.upload_archive_nested(), 422,
     _env("upload_archive_nested",
          "The ZIP archive contains another archive, which is not allowed.", False),
     None),
    ("archive_too_many_members", "upload_archive_too_many_members",
     lambda: upload_errors.upload_archive_too_many_members(), 422,
     _env("upload_archive_too_many_members", "The ZIP archive contains too many files.", False),
     None),
    ("archive_too_many_audio", "upload_archive_too_many_audio",
     lambda: upload_errors.upload_archive_too_many_audio(), 422,
     _env("upload_archive_too_many_audio", "The ZIP archive contains too many audio files.",
          False),
     None),
    ("archive_member_too_large", "upload_archive_member_too_large",
     lambda: upload_errors.upload_archive_member_too_large(), 422,
     _env("upload_archive_member_too_large", "A file in the ZIP archive is too large.", False),
     None),
    ("archive_expanded_too_large", "upload_archive_expanded_too_large",
     lambda: upload_errors.upload_archive_expanded_too_large(), 422,
     _env("upload_archive_expanded_too_large", "The ZIP archive is too large once unpacked.",
          False),
     None),
    ("archive_ratio_exceeded", "upload_archive_ratio_exceeded",
     lambda: upload_errors.upload_archive_ratio_exceeded(), 422,
     _env("upload_archive_ratio_exceeded",
          "The ZIP archive is compressed suspiciously well and was rejected.", False),
     None),
    ("not_resolvable", "upload_item_not_resolvable",
     lambda: upload_errors.upload_item_not_resolvable("ready"), 409,
     _env("upload_item_not_resolvable",
          "This upload item cannot be closed as a duplicate in its current state.", False,
          state="ready"),
     None),
    ("duplicate_match_unavailable", "upload_duplicate_match_unavailable",
     lambda: upload_errors.upload_duplicate_match_unavailable(), 409,
     _env("upload_duplicate_match_unavailable",
          "That track is not an available match for this upload item.", False),
     None),
]

DELETION_ROWS = [
    ("library_delete_disabled", "library_delete_disabled",
     lambda: deletion_errors.library_delete_disabled(), 403,
     _env("library_delete_disabled", "Server deletion is turned off on this server.", False),
     None),
    ("pair_not_found", "pair_not_found",
     lambda: deletion_errors.pair_not_found(), 404,
     _env("pair_not_found", "Duplicate pair not found.", False), None),
    ("operation_conflict", "operation_conflict",
     lambda: deletion_errors.operation_conflict(), 409,
     _env("operation_conflict", "This operation ID was already used for a different request.",
          False),
     None),
    ("deletion_job_not_found", "deletion_job_not_found",
     lambda: deletion_errors.deletion_job_not_found(), 404,
     _env("deletion_job_not_found", "Deletion job not found.", False), None),
    ("direct_with_extra", None,
     lambda: DeletionError(409, "some_code", "Some message.", retryable=True, state="x", n=2),
     409, _env("some_code", "Some message.", True, state="x", n=2), None),
]

LASTFM_ROWS = [
    ("disabled", "lastfm_disabled",
     lambda: lastfm_errors.lastfm_disabled(), 403,
     _env("lastfm_disabled", "Last.fm scrobbling is turned off on this server.", False), None),
    ("stopped", "lastfm_stopped",
     lambda: lastfm_errors.lastfm_stopped(), 503,
     _env("lastfm_stopped", "Last.fm is stopped on this server right now.", False), None),
    ("unavailable", "lastfm_unavailable",
     lambda: lastfm_errors.lastfm_unavailable(), 503,
     _env("lastfm_unavailable", "Last.fm did not respond. Try again shortly.", True), None),
    ("too_soon", "lastfm_too_soon",
     lambda: lastfm_errors.lastfm_too_soon(retry_after_s=7), 429,
     _env("lastfm_too_soon",
          "You started a Last.fm connection a moment ago. Wait a little and try again.", True),
     {"Retry-After": "7"}),
    ("not_authorized_yet", "lastfm_not_authorized_yet",
     lambda: lastfm_errors.lastfm_not_authorized_yet(), 409,
     _env("lastfm_not_authorized_yet",
          "Last.fm has not been approved yet. Approve it on last.fm, then try again.", True),
     None),
    ("approval_expired", "lastfm_approval_expired",
     lambda: lastfm_errors.lastfm_approval_expired(), 410,
     _env("lastfm_approval_expired", "The Last.fm approval has expired. Start connecting again.",
          False),
     None),
    ("account_mismatch", "lastfm_account_mismatch",
     lambda: lastfm_errors.lastfm_account_mismatch(
         stored_account="alpha", approved_account="beta"), 409,
     _env("lastfm_account_mismatch",
          "That approval was for a different Last.fm account than the one connected.", False,
          stored_account="alpha", approved_account="beta"),
     None),
    ("not_connected", "lastfm_not_connected",
     lambda: lastfm_errors.lastfm_not_connected(), 409,
     _env("lastfm_not_connected", "Last.fm is not connected yet.", False), None),
    ("connection_changed", "lastfm_connection_changed",
     lambda: lastfm_errors.lastfm_connection_changed(), 409,
     _env("lastfm_connection_changed",
          "The Last.fm connection changed since you last looked. Check it and try again.",
          False),
     None),
    ("reconnect_required", "lastfm_reconnect_required",
     lambda: lastfm_errors.lastfm_reconnect_required(), 409,
     _env("lastfm_reconnect_required",
          "Last.fm needs to be reconnected before it can be turned on.", False),
     None),
]


def _assert_full_answer(error, carrier, status, detail, headers):
    assert type(error) is carrier
    assert str(error) == detail["message"]
    assert (error.status, error.code, error.message, error.retryable) == (
        status, detail["error"], detail["message"], detail["retryable"]
    )
    envelope = {"error", "message", "retryable"}
    assert error.extra == {k: v for k, v in detail.items() if k not in envelope}

    http = error.to_http()

    assert type(http) is HTTPException
    assert http.status_code == status
    # Key by key and in order: the JSON body is written in this order.
    assert list(http.detail.items()) == list(detail.items())
    assert http.headers == headers


@pytest.mark.parametrize(
    "factory, build, status, detail, headers",
    [row[1:] for row in UPLOAD_ROWS],
    ids=[row[0] for row in UPLOAD_ROWS],
)
def test_every_upload_factory_answers_exactly(factory, build, status, detail, headers):
    _assert_full_answer(build(), UploadError, status, detail, headers)


@pytest.mark.parametrize(
    "factory, build, status, detail, headers",
    [row[1:] for row in DELETION_ROWS],
    ids=[row[0] for row in DELETION_ROWS],
)
def test_every_deletion_factory_answers_exactly(factory, build, status, detail, headers):
    _assert_full_answer(build(), DeletionError, status, detail, headers)


@pytest.mark.parametrize(
    "factory, build, status, detail, headers",
    [row[1:] for row in LASTFM_ROWS],
    ids=[row[0] for row in LASTFM_ROWS],
)
def test_every_lastfm_factory_answers_exactly(factory, build, status, detail, headers):
    _assert_full_answer(build(), LastfmError, status, detail, headers)


@pytest.mark.parametrize("status", [409, 503])
def test_track_pending_deletion_answers_exactly(status):
    http = deletion_errors.track_pending_deletion_error(status)

    assert type(http) is HTTPException
    assert http.status_code == status
    assert list(http.detail.items()) == list(
        _env("track_pending_deletion", "This track is being deleted.", True).items()
    )
    assert http.headers is None


def _factories(module):
    return {
        name for name, value in vars(module).items()
        if inspect.isfunction(value) and value.__module__ == module.__name__
    }


@pytest.mark.parametrize(
    "module, rows, others",
    [
        (upload_errors, UPLOAD_ROWS, set()),
        (deletion_errors, DELETION_ROWS, {"track_pending_deletion_error"}),
        (lastfm_errors, LASTFM_ROWS, set()),
    ],
    ids=["upload", "deletion", "lastfm"],
)
def test_every_factory_of_each_module_has_a_row(module, rows, others):
    covered = {row[1] for row in rows if row[1] is not None}

    assert _factories(module) == covered | others


@pytest.mark.parametrize(
    "build",
    [
        lambda s: upload_errors.upload_slots_busy(retry_after_s=s),
        lambda s: lastfm_errors.lastfm_too_soon(retry_after_s=s),
    ],
    ids=["upload_slots_busy", "lastfm_too_soon"],
)
@pytest.mark.parametrize("value", [0, -1, True, 1.5, "5"])
def test_a_retry_after_that_is_not_a_positive_int_is_refused(build, value):
    with pytest.raises(ValueError, match="retry_after_s must be a positive int"):
        build(value)


# Review m2: the conversion helper the routers use. The Last.fm routes keep the
# service error out of the HTTP error's chain (keep_cause=False); the others
# chain it.


@pytest.mark.parametrize("keep_cause", [True, False])
def test_answer_errors_turns_its_kind_into_the_http_answer(keep_cause):
    from app.core.api_errors import answer_errors

    error = lastfm_errors.lastfm_too_soon(retry_after_s=3)
    with pytest.raises(HTTPException) as raised:
        with answer_errors(LastfmError, keep_cause=keep_cause):
            raise error

    http = raised.value
    assert (http.status_code, http.headers) == (429, {"Retry-After": "3"})
    assert http.detail["error"] == "lastfm_too_soon"
    assert http.__context__ is error
    assert http.__cause__ is (error if keep_cause else None)
    assert http.__suppress_context__ is True  # set by any "raise ... from"


def test_answer_errors_lets_other_errors_through():
    from app.core.api_errors import answer_errors

    with pytest.raises(UploadError):
        with answer_errors(LastfmError):
            raise upload_errors.upload_item_not_found()
