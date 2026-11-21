"""Upload commit (Phase 7 spec §6): acceptance and the commit worker."""

import errno
import itertools
import json
import logging
import os
import shutil
import time
import uuid
from dataclasses import replace
from pathlib import Path

from app.core.durable_fs import fsync_file
from app.core.operator_log import operator_logger
from app.database.operation_receipts import OperationConflict
from app.models.uploads import CommitOperation, CommitRequest
from app.core.internal_dirs import is_internal_path
from app.models.track_meta_data import TrackMetaData
from app.services import (
    audio_identity, metadata, organizer, upload_placement, upload_recovery, upload_validation,
)
from app.services.audio_identity import ExactAudioHash, identity_to_columns
from app.services.ffmpeg_runner import ToolOptions
from app.services.media_input import demuxer_for
from app.services.metadata import is_wav
from app.services.path_sanitize import (
    UnsafePathComponent, assert_within, cut_to_bytes, sanitize_path_component, utf8_len,
)
from app.services.storage_ledger import UPLOAD_WORK_RESERVE, InsufficientStorage
from app.services.upload_errors import (
    UploadError,
    commit_disk_full,
    tag_write_failed,
    upload_commit_failed,
    upload_prepared_unreadable,
    upload_source_missing,
    upload_storage_refused,
    operation_conflict,
    tag_write_unsupported,
    upload_item_not_committable,
    upload_item_not_found,
    upload_library_changed,
    upload_review_version_conflict,
)
from app.services.upload_receipt import ReceiptFiles, _item_dir, owner_dir, remove_verified
from app.services.upload_validation import staged_identity_from_row
from app.services.worker_thread import PollingWorkerThread

log = logging.getLogger(__name__)
SEAM_POINTS = ("after_work_fsync", "after_art_registered", "before_prepared_journal",
               "after_prepared_journal")

_EXTENSIONS = {
    "flac": ".flac",
    "mp3": ".mp3",
    "wav": ".wav",
    "mov,mp4,m4a,3gp,3g2,mj2": ".m4a",
}


def validated_extension(detected: dict | None) -> str | None:
    """The master's file extension from the probed container, or None."""
    if not detected:
        return None
    return _EXTENSIONS.get(detected.get("container"))


def tag_write_supported(detected: dict | None) -> bool | None:
    extension = validated_extension(detected)
    if extension is None:
        return None
    return not is_wav(Path("x" + extension))


_ACTIVE_JOURNAL_STATES = ("committing", "prepared", "moved")


def accept(library, request: CommitRequest, item_uuid: str, *, uploads_root, now: int,
           new_uuid=lambda: str(uuid.uuid4())) -> tuple[int, dict]:
    """Accept a commit: ``(status, item row)``. 202 for a running operation,
    200 for a repeated terminal one."""

    def decide(row: dict) -> dict:
        if row["review_version"] != request.base_review_version:
            raise upload_review_version_conflict(row["review_version"])
        if row["state"] != "review_ready":
            raise upload_item_not_committable(row["state"])
        detected = None if row["detected_metadata"] is None else json.loads(row["detected_metadata"])
        extension = validated_extension(detected)
        if extension is None:
            raise upload_item_not_committable(row["state"])
        if request.write_tags and not tag_write_supported(detected):
            raise tag_write_unsupported()
        ack = request.acknowledged_duplicates
        return {
            "base_review_version": request.base_review_version,
            "reserved_track_uuid": new_uuid(),
            "edits": json.dumps(request.edits.edit_fields()),
            "write_tags": 1 if request.write_tags else 0,
            "acknowledged_duplicates": json.dumps({
                "library_tracks": sorted(str(u) for u in ack.library_tracks),
                "staged_items": sorted(str(u) for u in ack.staged_items),
            }),
            "source_path": row["source_path"],
            "work_path": str(
                _item_dir(uploads_root, library.owner_id, row)
                / f"work-{request.operation_uuid}{extension}"
            ),
        }

    try:
        outcome, row = library.accept_upload_commit(
            item_uuid,
            request_model=CommitOperation(item_uuid=item_uuid, request=request),
            decide=decide, now=now,
        )
    except OperationConflict as exc:
        raise operation_conflict() from exc
    if outcome == "not_found":
        raise upload_item_not_found()
    if outcome == "replay":
        state = row.pop("journal_state")
        return (202 if state in _ACTIVE_JOURNAL_STATES else 200), row
    return 202, row




class _SourceMissing(Exception):
    """The staged source is no longer a file."""


def _failure_for(exc: Exception) -> tuple[UploadError, str]:
    """The item error of a failed step and the item state it ends in."""
    if isinstance(exc, _SourceMissing):
        return upload_source_missing(), "failed"
    if isinstance(exc, upload_placement.LibraryChanged):
        return upload_library_changed(), "review_ready"
    if isinstance(exc, InsufficientStorage):
        return upload_storage_refused(exc), "review_ready"
    if isinstance(exc, metadata.TagWriteError):
        return tag_write_failed(), "review_ready"
    if isinstance(exc, OSError) and exc.errno in (errno.ENOSPC, errno.EDQUOT):
        return commit_disk_full(), "review_ready"
    if isinstance(exc, upload_validation.ValidationFailed):
        if exc.error.code == "upload_invalid_audio":
            # The upload passed its check; only the prepared copy is unreadable.
            return upload_prepared_unreadable(), "review_ready"
        return exc.error, "review_ready"
    return upload_commit_failed(), "review_ready"


_MAX_FILE_NAME = 200
MAX_HAND_OVER_RETRIES = 3  # per operation, in this process
TAG_WRITE_HEADROOM_BYTES = 1024 * 1024  # a tag write may grow the file
_FINAL_FIELDS = (
    "title", "artist", "album", "album_artist", "year", "date", "genre", "track_number",
    "disc_number",
)


def _final_stem(display_name: str, track_uuid: str, extension: str) -> str:
    """The sanitized stem of the display filename (never trusted), capped so
    ``<stem>-<track_uuid><ext>`` stays within the file-name cap."""
    name = display_name.replace("\\", "/").rsplit("/", 1)[-1]
    if "." in name:
        name = name.rpartition(".")[0]
    name = name.lstrip(".")
    try:
        stem = sanitize_path_component(name)
    except UnsafePathComponent:
        stem = "upload"
    room = _MAX_FILE_NAME - utf8_len(f"-{track_uuid}{extension}")  # UTF-8 bytes
    stem = cut_to_bytes(stem, room).rstrip(" .")
    return stem or "upload"


class UploadCommitWorker(PollingWorkerThread):
    """The commit worker, steps 1-2 (spec section 6): it claims an accepted
    commit, copies the staged source to a work file, re-probes it, builds the
    final catalog metadata, re-verifies the exact digest and journals
    ``prepared``. It never moves or inserts.

    ``process_one`` never raises; it returns ``idle``, ``prepared``,
    ``interrupted`` or ``error``, or, when ``after_prepared`` is set, that
    callable's return value. ``after_prepared(journal_row)`` runs steps 3-6
    (move, insert, finish) on the prepared row; the server passes an
    ``upload_publish.UploadPublisher``."""

    thread_name = "upload-commit-worker"

    def __init__(self, database, *, uploads_root, music_library_dir, boot_id, ledger, quota,
                 cover_art, registry, clock=time.time, probe=upload_validation.probe_upload,
                 compute_exact=audio_identity.compute_exact,
                 write_tags=metadata.write_metadata_tags,
                 extract_art=metadata.extract_cover_art_bytes,
                 after_prepared=None, idle_poll_s=5.0, seam=None):
        super().__init__(idle_poll_s=idle_poll_s, kill_registry=registry)
        self._database = database
        self._uploads_root = uploads_root
        self._music_library_dir = music_library_dir
        self._boot_id = boot_id
        self._ledger = ledger
        self._quota = quota
        self._cover_art = cover_art  # used by the tag and artwork step
        self._registry = registry
        self._clock = clock
        self._probe = probe
        self._compute_exact = compute_exact
        self._write_tags = write_tags  # used by the tag and artwork step
        self._extract_art = extract_art  # used by the tag and artwork step
        self._after_prepared = after_prepared
        self._unrecorded = {}  # (owner, operation) -> retries used; this process's own only
        self._seam = seam
        self._steps = itertools.count(1)
        self._reservation_id = None
        self._art = (None, None)

    def _interrupted(self) -> bool:
        return self._stop.is_set() or self._stop_hit_step

    def _at(self, name: str) -> None:
        if self._seam is not None:
            self._seam(name)

    def process_one(self):
        try:
            claimed = self._database.claim_upload_commit(boot_id=self._boot_id)
        except Exception as e:
            log.warning("upload commit claim failed: %s", type(e).__name__)
            return "error"
        if claimed is None:
            return self._retry_unrecorded()
        job_id = ("upload-commit", next(self._steps))
        self._stop_hit_step = False
        self._reservation_id = None
        self._art = (claimed["cover_art_id"], claimed["cover_art_created"])
        prepared = None
        outcome = "error"
        failure = None
        try:
            prepared = self._prepare(claimed, job_id)
            outcome = "interrupted" if prepared is None and self._interrupted() else (
                "prepared" if prepared is not None else "error")
        except Exception as e:
            if self._interrupted():
                operator_logger.info("upload commit step stopped by the shutdown: %s", type(e).__name__)
            else:
                log.warning("upload commit step failed: %s", type(e).__name__)
                failure = e
        if prepared is None:
            if failure is not None:
                return self._fail(claimed, failure)
            self._give_back(claimed)
            return outcome
        self._at("after_prepared_journal")
        if self._after_prepared is None:
            return "prepared"
        outcome = self._hand_over(prepared)
        if outcome == "error":  # its outcome could not be recorded: retried while idle
            self._unrecorded.setdefault((prepared["owner_id"], prepared["operation_uuid"]), 0)
        return outcome

    def _hand_over(self, prepared):
        try:
            # The publisher re-reads the cover art; it runs registered in this
            # worker's registry so that shutdown ends it.
            with metadata.probes_killed_by(self._registry):
                return self._after_prepared(prepared)
        except Exception as e:
            log.warning("upload commit hand-over failed: %s", type(e).__name__)
            return "error"

    def _retry_unrecorded(self):
        """Idle: hand an operation of this process whose outcome could not be
        recorded back to the publisher, from a fresh read of its journal, at most
        ``MAX_HAND_OVER_RETRIES`` times; after that it is left for the next start."""
        for key, used in list(self._unrecorded.items()):
            owner, operation = key
            try:
                row = next((r for r in self._database.list_upload_commit_journals_to_resume()
                            if (r["owner_id"], r["operation_uuid"]) == key), None)
                item = None if row is None else self._database.get_upload_item(
                    row["item_uuid"], owner_id=owner)
            except Exception as e:
                log.warning("upload commit retry lookup failed: %s", type(e).__name__)
                return "idle"
            if row is None or item is None or item["state"] != "committing":
                del self._unrecorded[key]
                continue
            if used >= MAX_HAND_OVER_RETRIES:
                log.warning("upload commit outcome still unrecorded; left for the next start")
                del self._unrecorded[key]
                continue
            self._unrecorded[key] = used + 1
            try:  # the same first step startup recovery takes: a placed final file is ours
                row = upload_recovery.advance_if_placed(
                    self._database, row, uploads_root=self._uploads_root,
                    music_library_dir=self._music_library_dir)
            except Exception as e:
                log.warning("upload commit retry could not record a placement: %s", type(e).__name__)
                return "error"
            outcome = self._hand_over(row)
            if outcome != "error":
                del self._unrecorded[key]
            return outcome
        return "idle"

    def _fail(self, claimed, exc):
        """The one failure handler of steps 1-2: remove this operation's own work
        file (only a journaled path proven inside the owner's stage), end the
        journal ``failed`` and the item back at review (or ``failed`` when the
        staged source is gone), give the reservation back, then release art this
        operation created. The staged source is never touched."""
        error, item_state = _failure_for(exc)
        removed = False
        try:
            work = Path(claimed["work_path"])
            assert_within(work, owner_dir(self._uploads_root, claimed["owner_id"]))
            removed = remove_verified(ReceiptFiles(), work)
            if not removed:
                log.warning("commit work copy not removed")
        except Exception as e:
            log.warning("commit work copy not removed: %s", type(e).__name__)
        try:
            done = self._database.fail_upload_commit(
                owner_id=claimed["owner_id"], operation_uuid=claimed["operation_uuid"],
                boot_id=self._boot_id, error_code=error.code, error_message=error.message,
                item_state=item_state, reservation_id=self._reservation_id,
                keep_reservation=not removed, retryable=error.retryable, now=int(self._clock()))
        except Exception as e:
            log.warning("upload commit failure not recorded: %s", type(e).__name__)
            done = False
        if not done:
            self._give_back(claimed)
            return "error"
        if isinstance(exc, upload_placement.LibraryChanged):
            upload_placement.log_library_changed(claimed["owner_id"], exc)
        art_id, created = self._art
        if created == 1 and art_id is not None:
            try:
                self._cover_art.release_if_unreferenced(art_id)
            except Exception as e:
                log.warning("commit artwork not released: %s", type(e).__name__)
        return "failed"

    def _give_back(self, claimed):
        """No result was written: release the work reservation and the leases."""
        if self._reservation_id is not None:
            try:
                self._ledger.release(self._reservation_id)
            except Exception as e:
                log.warning("commit work reservation not released: %s", type(e).__name__)
        try:
            self._database.release_upload_commit_lease(
                owner_id=claimed["owner_id"], operation_uuid=claimed["operation_uuid"],
                boot_id=self._boot_id)
        except Exception as e:
            log.warning("commit lease not released: %s", type(e).__name__)

    def _prepare(self, claimed, job_id):
        """Steps 1-2. Returns the prepared journal row, or None when stopped."""
        owner = claimed["owner_id"]
        stage = owner_dir(self._uploads_root, owner)
        source = Path(claimed["source_path"])
        work = Path(claimed["work_path"])
        assert_within(source, stage)
        assert_within(work, stage)
        if not os.path.isfile(source):
            raise _SourceMissing()
        detected = json.loads(claimed["detected_metadata"])
        extension = validated_extension(detected)
        if extension is None:
            raise ValueError("no validated extension")
        track_uuid = claimed["reserved_track_uuid"]
        root = upload_placement.owner_library_root(
            self._music_library_dir, self._database.get_user(owner))

        # Step 1: the planned name (only journaled, never created here).
        stem = _final_stem(claimed["filename"], track_uuid, extension)
        edits = json.loads(claimed["edits"])

        # Step 2: the work copy.
        if os.path.lexists(work) and not remove_verified(ReceiptFiles(), work):
            raise OSError("stale work copy not removable")
        will_tag = bool(claimed["write_tags"] and edits)
        reserve = os.path.getsize(source)
        if will_tag:
            reserve += TAG_WRITE_HEADROOM_BYTES + 2 * len(claimed["edits"].encode())
        self._reservation_id = self._ledger.reserve(
            owner_id=owner, purpose=UPLOAD_WORK_RESERVE, nbytes=reserve,
            subject_ref=claimed["operation_uuid"], quota=self._quota)
        if will_tag:
            # The tag writer produces the work file from the staged source.
            self._process_step(
                self._tool_step, self._write_tags, source, work, metadata.build_ffmpeg_tags(edits),
                job_id=job_id, input_format=self._input_format(claimed))
            fsync_file(work)
            if os.path.getsize(work) > reserve:
                raise OSError("tag-written work file larger than its reservation")
        else:
            fd = os.open(work, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
            with os.fdopen(fd, "wb") as out, open(source, "rb") as src:
                shutil.copyfileobj(src, out)
                out.flush()
            fsync_file(work)
        ReceiptFiles().sync_dir(work.parent)
        self._at("after_work_fsync")
        if self._interrupted():
            return None

        probed = self._process_step(self._tool_step, self._probe, work, job_id=job_id, low_priority=True)
        if self._interrupted():
            return None
        tags = probed["tags"]
        final = {"v": 1, **{k: tags.get(k) for k in _FINAL_FIELDS},
                 "codec": probed["codec"], "duration": probed["duration_s"],
                 "bitrate_kbps": probed["bitrate_kbps"], "sample_rate_hz": probed["sample_rate_hz"],
                 "channels": probed["channels"], "has_album_art": bool(probed["has_album_art"]),
                 "cover_art_id": None}
        if probed["has_album_art"]:
            cover = self._register_art(claimed, work)
            final["cover_art_id"] = cover
            if self._interrupted():
                return None
        final.update(edits)
        # NFC before the path, so the folder and the published row agree.
        for key in organizer.NFC_TEXT_FIELDS:
            if key in final:
                final[key] = organizer.nfc_text(final[key])
        final_path = organizer.sanitized_destination_path(
            f"{stem}-{track_uuid}{extension}",
            TrackMetaData(**{k: v for k, v in final.items() if k != "v"}), root)
        upload_placement.assert_final_within(final_path, root)
        if is_internal_path(final_path, self._music_library_dir):
            raise ValueError("final path is internal")

        identity, digest_check = self._verify_digest(claimed, work, probed, job_id)
        if self._interrupted():
            return None
        self._at("before_prepared_journal")
        return self._database.prepare_upload_commit(
            owner_id=owner, operation_uuid=claimed["operation_uuid"], boot_id=self._boot_id,
            final_path=str(final_path), final_metadata=json.dumps(final),
            identity_columns=identity_to_columns(identity), digest_check=digest_check,
            reservation_id=self._reservation_id, now=int(self._clock()))

    def _tool_step(self, fn, *args, job_id, low_priority=False, input_format=None):
        """``fn(*args, options=...)`` as one process step: killable through this
        worker's registry under the step's job id."""
        return fn(*args, options=ToolOptions(registry=self._registry, job_id=job_id,
                                             low_priority=low_priority, input_format=input_format))

    @staticmethod
    def _input_format(claimed):
        """The demuxer the probe detected: staged bytes and the work copy open only their input."""
        return demuxer_for(json.loads(claimed["detected_metadata"]).get("container"))

    def _register_art(self, claimed, work):
        """Register the work file's embedded art; journal it at once. Returns
        the cover art id, or None (no data, or not an image).

        A rerun first gives back the art an earlier run of this operation
        created, then forgets it in the journal, and only then registers the
        image again. In this order a crash at any point leaves no image that
        nothing names: until the journal is cleared it still names the earlier
        art, and art registered after the clear is adopted at start-up because
        the journal then names none. Clearing first would leak the earlier art.
        The earlier art is kept, and still ours, when another commit's journal
        names it (its registration found the same image): giving it back looks
        only at tracks, so that commit would lose its cover. An image this call
        created is given back at once when journaling it fails, since nothing
        would name it otherwise."""
        owner, operation = claimed["owner_id"], claimed["operation_uuid"]
        old = claimed["cover_art_id"]
        kept = None  # earlier art of ours another journal also names
        if claimed["cover_art_created"] == 1 and old is not None:
            if self._database.upload_commit_art_named_elsewhere(
                    owner_id=owner, operation_uuid=operation, cover_art_id=old):
                kept = old
            else:
                self._cover_art.release_if_unreferenced(old)
                if not self._database.record_upload_commit_art(
                        owner_id=owner, operation_uuid=operation,
                        boot_id=self._boot_id, cover_art_id=None,
                        cover_art_created=False, now=int(self._clock())):
                    raise RuntimeError("commit lease lost while recording artwork")
                self._art = (None, None)
        # Registered in this worker's registry so that shutdown ends the extraction.
        with metadata.probes_killed_by(self._registry):
            data = self._extract_art(work, input_format=self._input_format(claimed))
        if not data:
            return None
        try:
            result = self._cover_art.add_album_art_with_status(data)
        except ValueError as e:
            log.warning("embedded artwork not usable: %s", type(e).__name__)
            return None
        self._at("after_art_registered")
        created = result.was_created or result.cover_art_id == kept
        try:
            recorded = self._database.record_upload_commit_art(
                owner_id=owner, operation_uuid=operation, boot_id=self._boot_id,
                cover_art_id=result.cover_art_id, cover_art_created=created,
                now=int(self._clock()))
        except Exception:
            self._give_back_unrecorded_art(result)
            raise
        if not recorded:
            self._give_back_unrecorded_art(result)
            raise RuntimeError("commit lease lost while recording artwork")
        self._art = (result.cover_art_id, 1 if created else 0)
        return result.cover_art_id

    def _give_back_unrecorded_art(self, result):
        """An image this call created that the journal could not name: nothing
        else would ever give it back."""
        if not result.was_created:
            return
        try:
            self._cover_art.release_if_unreferenced(result.cover_art_id)
        except Exception as e:
            log.warning("unrecorded commit artwork not released: %s", type(e).__name__)

    def _verify_digest(self, claimed, work, probed, job_id):
        """SC-25: the prepared work file against the staged identity. Returns
        ``(identity to insert, digest_check)``."""
        staged = staged_identity_from_row(claimed["identity"])
        work_hash = self._process_step(
            self._tool_step, self._compute_exact, work, probed["codec"],
            job_id=job_id, low_priority=True, input_format=self._input_format(claimed))
        if not isinstance(work_hash, ExactAudioHash):
            return staged, "unverified"
        if not isinstance(staged.exact, ExactAudioHash):
            return replace(staged, exact=work_hash), "computed"
        if audio_identity.exact_match(staged.exact, work_hash):
            return staged, "verified"
        log.warning("upload commit: exact audio digest changed in the work copy")
        return replace(staged, exact=work_hash, fingerprint=None), "changed"
