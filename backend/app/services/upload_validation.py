"""Upload validation (Phase 7 spec §5 "Duplicate check", "Quick probe"): the
probe of a received upload, its detected metadata, and the bounded
validation worker (``UploadValidationWorker``)."""

import itertools
import os
import json
import logging
import time
from pathlib import Path
from dataclasses import replace

from app import config
from app.services import audio_identity, upload_errors
from app.services.audio_identity import (
    FINGERPRINT_COLUMNS,
    AudioIdentity,
    ExactUnavailable,
    IDENTITY_COLUMNS,
    FingerprintUnavailable,
    identity_from_columns,
    identity_to_columns,
)
from app.services.duplicate_detection import (
    DuplicateMatch,
    DuplicateReport,
    LayerCoverage,
    MatcherParams,
    StagedIdentity,
    StagedRef,
    TrackRef,
    find_duplicates,
)
from app.services.path_sanitize import assert_within
from app.services.ffmpeg_runner import NO_OPTIONS, ToolOptions, run_capture
from app.services.identity_reasons import (
    REASON_INTERNAL_ERROR,
    REASON_KILLED,
    REASON_OUTPUT_ERROR,
    REASON_TIMEOUT,
    REASON_TOOL_MISSING,
    reason_for_capture_exception,
    reason_for_exit,
)
from app.services.worker_thread import PollingWorkerThread
# Importing upload_receipt also registers the upload_items job table.
from app.services.upload_receipt import (
    ReceiptFiles, discard_child_files, owner_dir, remove_then_release, remove_verified,
)
from app.services.media_input import UPLOAD_PROBE_ARGS, demuxer_for
from app.services.metadata import build_track_metadata

log = logging.getLogger(__name__)

_ZIP_MAGIC = (b"PK\x03\x04", b"PK\x05\x06")

PROBE_TIMEOUT_S = 30
PROBE_MAX_STDOUT_BYTES = 1024 * 1024

# (ffprobe format_name, codec_name) -> MIME. The server's probe is the only
# authority: the filename and the client's content type are never consulted.
_MP4_FORMAT = "mov,mp4,m4a,3gp,3g2,mj2"
_SUPPORTED_MIME = {
    ("flac", "flac"): "audio/flac",
    ("mp3", "mp3"): "audio/mpeg",
    ("wav", "pcm_s16le"): "audio/wav",
    ("wav", "pcm_s24le"): "audio/wav",
    ("wav", "pcm_f32le"): "audio/wav",
    (_MP4_FORMAT, "aac"): "audio/mp4",
    (_MP4_FORMAT, "alac"): "audio/mp4",
}


class ValidationFailed(Exception):
    """The item fails validation with ``error`` (an UploadError)."""

    def __init__(self, error):
        super().__init__(error.code)
        self.error = error


class ValidationInterrupted(Exception):
    """A process step was killed (stop or cancel): no verdict, write nothing."""


def validation_token_key(owner_id, item_uuid):
    """The cancel-token key of a validation step. Distinct from the receipt's
    ``(owner_id, item_uuid)`` so the two never share (or discard) a token."""
    return ("upload-validation", owner_id, item_uuid)


def _fail_for_reason(reason):
    if reason == REASON_KILLED:
        raise ValidationInterrupted()
    if reason == REASON_TIMEOUT:
        raise ValidationFailed(upload_errors.probe_timeout())
    if reason == REASON_TOOL_MISSING:
        raise ValidationFailed(upload_errors.probe_unavailable())
    if reason == REASON_INTERNAL_ERROR:
        raise ValidationFailed(upload_errors.upload_validation_failed())
    raise ValidationFailed(upload_errors.upload_invalid_audio())


def probe_upload(path, *, timeout_s=PROBE_TIMEOUT_S, options=NO_OPTIONS, run=run_capture) -> dict:
    """Probe ``path`` and return the detected-metadata JSON v1 dict; unknown is
    null. Raises ValidationFailed (typed item error) or ValidationInterrupted.
    The probe of staged bytes always runs at low priority, whatever ``options``
    say. The command restricts its own input (``UPLOAD_PROBE_ARGS``): it never
    reads ``options.input_format``."""
    options = replace(options, low_priority=True)
    cmd = ["ffprobe", "-v", "error", "-hide_banner", "-show_streams",
           "-show_format", "-of", "json", *UPLOAD_PROBE_ARGS, str(path)]
    try:
        result = run(cmd, timeout_s=timeout_s, max_stdout_bytes=PROBE_MAX_STDOUT_BYTES, options=options)
    except Exception as e:
        _fail_for_reason(reason_for_capture_exception(e)[0])
    if result.returncode != 0:
        _fail_for_reason(reason_for_exit(result.returncode))

    try:
        data = json.loads(result.stdout)
    except ValueError:
        data = None
    if not isinstance(data, dict):
        raise ValidationFailed(upload_errors.upload_invalid_audio())
    try:
        meta = build_track_metadata(data)
    except (AttributeError, TypeError):
        meta = None
    if meta is None:
        raise ValidationFailed(upload_errors.upload_invalid_audio())

    fmt = data.get("format")
    container = fmt.get("format_name") if isinstance(fmt, dict) else None
    mime = _SUPPORTED_MIME.get((container, meta.codec))
    if mime is None:
        raise ValidationFailed(upload_errors.upload_unsupported_audio())

    return {
        "v": 1,
        "container": container,
        "codec": meta.codec,
        "mime": mime,
        "duration_s": meta.duration,
        "bitrate_kbps": meta.bitrate_kbps,
        "sample_rate_hz": meta.sample_rate_hz,
        "channels": meta.channels,
        "has_album_art": bool(meta.has_album_art),
        "tags": {
            "title": meta.title,
            "artist": meta.artist,
            "album": meta.album,
            "album_artist": meta.album_artist,
            "date": meta.date,
            "year": meta.year,
            "genre": meta.genre,
            "track_number": meta.track_number,
            "disc_number": meta.disc_number,
        },
    }


def staged_identity_columns(identity, *, fingerprinter_present: bool) -> dict:
    """The SC-25 identity columns plus the writer-owned fingerprint state: a
    print that was not computed is stored ``unavailable`` (or ``failed`` with
    its reason); every column is present, unknown is None."""
    stored = identity_to_columns(identity)
    columns = dict.fromkeys(
        (*IDENTITY_COLUMNS, *FINGERPRINT_COLUMNS, "fp_failure_reason")
    )
    columns.update(stored)
    if "fp_state" not in stored:
        if isinstance(identity.fingerprint, FingerprintUnavailable):
            columns["fp_state"] = "failed"
            columns["fp_failure_reason"] = identity.fingerprint.reason
        else:
            columns["fp_state"] = "unavailable"
    return columns


def staged_identity_from_row(row):
    """Read a stored identity back through ``identity_from_columns``. A stored
    ``failed`` print reads as FingerprintUnavailable(reason); a malformed print
    is rewritten as a failed ``output_error`` print (never an item failure). A
    malformed exact layer raises ValueError."""
    try:
        identity = identity_from_columns(row)
    except ValueError:
        # Raises again if the exact layer is the malformed part.
        identity = identity_from_columns({**row, "fp_state": None})
        return replace(identity, fingerprint=FingerprintUnavailable(REASON_OUTPUT_ERROR))
    if row.get("fp_state") == "failed":
        return replace(
            identity,
            fingerprint=FingerprintUnavailable(row.get("fp_failure_reason") or REASON_OUTPUT_ERROR),
        )
    return identity


_REPORT_VERSION = 1
_LAYER_KEYS = ("subject_state", "library_pending", "library_failed", "library_not_comparable")


def _layer_to_json(layer) -> dict:
    return {
        "subject_state": layer.subject_state,
        "library_pending": layer.library_pending,
        "library_failed": layer.library_failed,
        "library_not_comparable": layer.library_not_comparable,
    }


def _layer_from_json(data) -> LayerCoverage:
    if not isinstance(data, dict) or set(data) != set(_LAYER_KEYS):
        raise ValueError("malformed duplicate report layer")
    values = [data[k] for k in _LAYER_KEYS]
    counts_ok = all(type(v) is int for v in values[1:])
    if not isinstance(values[0], str) or not counts_ok:
        raise ValueError("malformed duplicate report layer")
    return LayerCoverage(*values)


def duplicate_report_to_json(report) -> str:
    """Refs only. ``None`` (a finder error) is stored as the failed report."""
    if report is None:
        return json.dumps(
            {"v": _REPORT_VERSION, "status": "failed", "exact": None,
             "fingerprint": None, "matches": []}
        )
    matches = []
    for m in report.matches:
        if isinstance(m.subject, TrackRef):
            ref, ref_id = "library_track", m.subject.uuid_id
        else:
            ref, ref_id = "staged_item", m.subject.item_uuid
        matches.append({"ref": ref, "id": ref_id, "kind": m.kind, "band": m.band, "score": m.score})
    return json.dumps(
        {"v": _REPORT_VERSION, "status": "complete",
         "exact": _layer_to_json(report.exact),
         "fingerprint": _layer_to_json(report.fingerprint),
         "matches": matches}
    )


def duplicate_report_from_json(text: str):
    """Inverse of ``duplicate_report_to_json``; None for a failed report.
    Raises ValueError for anything in an unknown version or shape."""
    data = json.loads(text)  # JSONDecodeError is a ValueError
    if not isinstance(data, dict) or data.get("v") != _REPORT_VERSION:
        raise ValueError("unknown duplicate report version")
    status = data.get("status")
    if status == "failed":
        return None
    if status != "complete":
        raise ValueError("unknown duplicate report status")
    raw_matches = data.get("matches")
    if not isinstance(raw_matches, list):
        raise ValueError("malformed duplicate report matches")
    matches = []
    for m in raw_matches:
        if not isinstance(m, dict):
            raise ValueError("malformed duplicate report match")
        ref_id = m.get("id")
        if not isinstance(ref_id, str):
            raise ValueError("malformed duplicate report ref id")
        if m.get("ref") == "library_track":
            subject = TrackRef(ref_id)
        elif m.get("ref") == "staged_item":
            subject = StagedRef(ref_id)
        else:
            raise ValueError("unknown duplicate report ref")
        if not {"kind", "band", "score"} <= set(m):
            raise ValueError("malformed duplicate report match")
        matches.append(DuplicateMatch(subject, m["kind"], m["band"], m["score"]))
    return DuplicateReport(
        exact=_layer_from_json(data.get("exact")),
        fingerprint=_layer_from_json(data.get("fingerprint")),
        matches=tuple(matches),
    )


class UploadValidationWorker(PollingWorkerThread):
    """The bounded validation worker. ``process_one`` takes the next item,
    probes it, computes its identity and finishes it in one transaction."""

    thread_name = "upload-validation-worker"

    def __init__(self, database, *, uploads_root, boot_id, tokens, registry, fingerprinter,
                 params=None, clock=time.time, probe=probe_upload,
                 compute_identity=audio_identity.compute_identity,
                 zip_handler=None, idle_poll_s=5.0):
        super().__init__(idle_poll_s=idle_poll_s, kill_registry=registry)
        self._database = database
        self._uploads_root = uploads_root
        self._boot_id = boot_id
        self._tokens = tokens
        self._registry = registry
        self._fingerprinter = fingerprinter
        self._params = params or MatcherParams.from_settings(config.settings)
        self._clock = clock
        self._probe = probe
        self._compute_identity = compute_identity
        self._zip_handler = zip_handler
        self._steps = itertools.count(1)

    def _check(self, owner_id):
        def check(conn, own_row, extra_rows):
            identity = staged_identity_from_row(dict(own_row))
            extra = []
            for row in extra_rows:
                try:
                    extra.append(StagedIdentity(
                        StagedRef(row["item_uuid"]), staged_identity_from_row(dict(row))))
                except ValueError as e:
                    log.warning("staged identity unreadable, skipped: %s", type(e).__name__)
            try:
                report = find_duplicates(
                    conn, identity, owner_id=owner_id, extra_subjects=extra, params=self._params)
            except Exception as e:  # advisory: the item stays reviewable
                log.warning("duplicate finder failed: %s", type(e).__name__)
                report = None
            return duplicate_report_to_json(report)
        return check

    def _identity_columns(self, identity):
        present = self._fingerprinter is not None
        columns = staged_identity_columns(identity, fingerprinter_present=present)
        # Store only what reads back: a print that would not is kept as failed.
        return staged_identity_columns(staged_identity_from_row(columns), fingerprinter_present=present)

    def _probe_step(self, path, *, job_id):
        return self._probe(path, options=ToolOptions(registry=self._registry, job_id=job_id, low_priority=True))

    def _compute(self, path, detected, job_id):
        try:
            return self._compute_identity(
                path, detected["codec"], fingerprinter=self._fingerprinter,
                known_duration_s=detected["duration_s"], params=self._params,
                options=ToolOptions(registry=self._registry, job_id=job_id, low_priority=True,
                                    input_format=demuxer_for(detected["container"])))
        except ValidationInterrupted:
            raise
        except Exception as e:  # advisory: the item stays reviewable
            log.warning("identity computation failed: %s", type(e).__name__)
            return AudioIdentity(
                exact=ExactUnavailable("failed", REASON_INTERNAL_ERROR),
                tool_versions=None, computed_at=int(self._clock()),
                fingerprint=(FingerprintUnavailable(REASON_INTERNAL_ERROR)
                             if self._fingerprinter is not None else None))

    def _fail(self, claimed, error, *, path=None):
        """End the item as failed (guarded, source and quota row kept). A
        non-retryable failure then gives the source back: remove the file and,
        only once it is verifiably gone, clear the path and release the quota
        row. A stale step (guard failed) never touches the file."""
        owner, item = claimed["owner_id"], claimed["item_uuid"]
        dropped = self._database.fail_upload_validation(
            owner_id=owner, item_uuid=item, boot_id=self._boot_id,
            review_version=claimed["review_version"], error_code=error.code,
            error_message=error.message, error_retryable=error.retryable,
            now=int(self._clock()))
        if dropped is None:
            return "stale"
        for child in dropped:  # the failed archive's staged children are not published
            try:
                discard_child_files(ReceiptFiles(), self._uploads_root, owner, child)
            except Exception as e:
                log.warning("failed archive child files not removed: %s", type(e).__name__)
        if not error.retryable and path is not None:
            try:  # the path was checked inside the owner's stage when the step read it
                remove_then_release(
                    ReceiptFiles(), path,
                    lambda: self._database.release_removed_upload_source(
                        item, owner_id=owner, source_path=str(path),
                        now=int(self._clock()), from_states=("failed",)),
                    remove=remove_verified)
            except Exception as e:
                log.warning("failed upload source not released: %s", type(e).__name__)
        return "failed"

    def process_one(self):
        """One step; never raises. Returns idle, review_ready, failed, stale,
        interrupted, cancelled or error."""
        try:
            claimed = self._database.claim_upload_validation(boot_id=self._boot_id)
        except Exception as e:
            log.warning("upload validation claim failed: %s", type(e).__name__)
            return "error"
        if claimed is None:
            return "idle"
        key = validation_token_key(claimed["owner_id"], claimed["item_uuid"])
        job_id = ("upload-validation", next(self._steps))
        outcome = "error"
        try:
            token = self._tokens.register(key)
            token.on_cancel(lambda: self._registry.kill(job_id))
            self._stop_hit_step = False
            outcome = self._run(claimed, job_id, token)
        except Exception as e:
            log.warning("upload validation step failed: %s", type(e).__name__)
        finally:
            self._tokens.discard(key)
        if outcome in ("stale", "cancelled", "interrupted", "error"):
            # No result was written: give the lease back (a still-validating item
            # is queued again; a cancelled one carries no stale lease).
            try:
                self._database.release_upload_validation_lease(
                    owner_id=claimed["owner_id"], item_uuid=claimed["item_uuid"],
                    boot_id=self._boot_id)
            except Exception as e:
                log.warning("validation lease not released: %s", type(e).__name__)
        return outcome

    def _unfinished(self, token):
        """Why this step must write nothing, or None."""
        if token.cancelled:
            return "cancelled"
        if self._stop.is_set() or self._stop_hit_step:
            return "interrupted"
        return None

    def _run(self, claimed, job_id, token):
        path = None
        try:
            try:
                path = Path(claimed["source_path"])
                assert_within(path, owner_dir(self._uploads_root, claimed["owner_id"]))
            except Exception:
                path = None
                raise
            if not os.path.isfile(path):
                return self._fail(claimed, upload_errors.upload_source_missing())
            check = self._check(claimed["owner_id"])
            now = int(self._clock())
            if claimed["detected_metadata"] is not None and claimed["has_identity"]:
                detected_json, columns = claimed["detected_metadata"], None
            else:
                with open(path, "rb") as handle:
                    magic = handle.read(4)
                if magic in _ZIP_MAGIC:
                    if self._zip_handler is not None:
                        return self._zip_handler(claimed, token=token, stopping=self._stop.is_set)
                    return self._fail(claimed, upload_errors.upload_archive_unsupported(), path=path)
                detected = self._process_step(self._probe_step, path, job_id=job_id)
                if (why := self._unfinished(token)) is not None:
                    return why
                columns = self._identity_columns(
                    self._process_step(self._compute, path, detected, job_id=job_id))
                detected_json = json.dumps(detected)
            if (why := self._unfinished(token)) is not None:
                return why
            done = self._database.finish_upload_validation(
                owner_id=claimed["owner_id"], item_uuid=claimed["item_uuid"],
                boot_id=self._boot_id, review_version=claimed["review_version"],
                detected_metadata=detected_json, identity_columns=columns,
                check=check, now=now)
            return "review_ready" if done else "stale"
        except ValidationInterrupted:
            # A stop or a cancel killed the process; anything else killed it from
            # outside and is a retryable failure of the item.
            if (why := self._unfinished(token)) is not None:
                return why
            return self._safe_fail(claimed, upload_errors.upload_validation_failed(), None)
        except ValidationFailed as e:
            return self._safe_fail(claimed, e.error, path)
        except Exception as e:
            log.warning("upload validation step failed: %s", type(e).__name__)
            return self._safe_fail(claimed, upload_errors.upload_validation_failed(), None)

    def _safe_fail(self, claimed, error, path):
        try:
            return self._fail(claimed, error, path=path)
        except Exception as e:
            log.warning("upload validation failure not recorded: %s", type(e).__name__)
            return "error"


def reconcile_upload_validation(database, *, boot_id: str) -> int:
    """Startup step: items a dead process was validating go back to the queue."""
    return database.reconcile_upload_validation(boot_id=boot_id)
