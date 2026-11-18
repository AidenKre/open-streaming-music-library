"""Upload expiry janitor (Phase 7 spec §3 retention): expires unconfirmed items,
removes the owned stages of ended ones and cleans finished commit journals."""
import logging
import os
import time
from pathlib import Path

from app.services import upload_recovery
from app.services.path_sanitize import assert_within
from app.services.worker_thread import WorkerThread
from app.services.upload_receipt import ReceiptFiles, _item_dir, _safe_uuid, owner_dir, remove_verified

log = logging.getLogger(__name__)

DAY = 86_400
_SOURCE_STATES = ("cancelled", "expired", "imported", "duplicate")


class UploadJanitor:
    def __init__(self, database, *, uploads_root, music_library_dir, cover_art, clock=time.time,
                 expiry_s=7 * DAY, retention_s=30 * DAY, journal_grace_s=3600):
        self._database = database
        self._uploads_root = uploads_root
        self._music_library_dir = music_library_dir
        self._cover_art = cover_art
        self._clock = clock
        self._expiry_s = expiry_s
        self._retention_s = retention_s
        self._journal_grace_s = journal_grace_s

    def run_once(self) -> None:
        now = int(self._clock())
        for part in (self._clean_journals, self._expire, self._remove_ended_stages,
                     self._remove_empty_folders, self._retain):
            try:
                part(now)
            except Exception as e:
                log.warning("upload janitor step failed: %s", type(e).__name__)

    def _each(self, rows, fn) -> None:
        """One row's failure is logged (type name only); the rest still run."""
        for row in rows:
            try:
                fn(row)
            except Exception as e:
                log.warning("upload janitor row failed: %s", type(e).__name__)

    def _clean_journals(self, now: int) -> None:
        rows = self._database.list_finished_upload_commit_journals(
            updated_before=now - self._journal_grace_s)
        self._each(rows, lambda row: upload_recovery.clean_finished_journal(
            self._database, row, uploads_root=self._uploads_root,
            music_library_dir=self._music_library_dir, cover_art=self._cover_art,
            clock=self._clock))

    def _expire(self, now: int) -> None:
        rows = self._database.list_expirable_upload_items(progress_before=now - self._expiry_s)
        self._each(rows, lambda row: self._database.expire_upload_item(
            row["item_uuid"], owner_id=row["owner_id"], from_state=row["state"],
            progress_before=now - self._expiry_s, now=now))

    def _remove_ended_stages(self, now: int) -> None:
        rows = [r for r in self._database.list_ended_upload_items()
                if r["state"] in _SOURCE_STATES and (r["source_path"] or r["part_path"])]
        self._each(rows, lambda row: self._remove_ended_stage(row, now))

    def _remove_ended_stage(self, row: dict, now: int) -> None:
        owner = row["owner_id"]
        stage = owner_dir(self._uploads_root, owner)
        files = ReceiptFiles()
        # The part and the source are independent: one failing never stops the other.
        failure = None
        for recorded, release in ((row["part_path"], self._release_part),
                                  (row["source_path"], self._release_source)):
            if not recorded:
                continue
            try:
                path = Path(recorded)
                assert_within(path, stage)  # not ours: never removed, left recorded
                if remove_verified(files, path):
                    release(row, now)
            except Exception as e:
                failure = failure or e
        if failure is not None:
            raise failure

    def _release_part(self, row: dict, now: int) -> None:
        self._database.clear_upload_part(owner_id=row["owner_id"], item_uuid=row["item_uuid"])

    def _release_source(self, row: dict, now: int) -> None:
        self._database.release_cancelled_upload_source(
            row["item_uuid"], owner_id=row["owner_id"], source_path=row["source_path"], now=now,
            from_states=(row["state"],))

    def _remove_empty_folders(self, now: int) -> None:
        self._each(self._database.list_ended_upload_items(), self._remove_folders)

    def _remove_folders(self, row: dict) -> None:
        owner = row["owner_id"]
        folder = _item_dir(self._uploads_root, owner, row)
        try:
            os.rmdir(folder)
        except OSError:
            pass  # missing, or holds something: stays
        if self._database.count_live_upload_items(
                owner_id=owner, batch_uuid=row["batch_uuid"]) == 0:
            try:
                os.rmdir(folder.parent)
            except OSError:
                pass

    def _retain(self, now: int) -> None:
        """Batch and item records go once everything in them ended and aged out;
        receipts stay. The batch folder must be gone first (``rmdir`` only)."""
        cutoff = now - self._retention_s
        self._each(self._database.list_upload_batches_for_retention(updated_before=cutoff),
                   lambda row: self._prune(row, cutoff))

    def _prune(self, row: dict, cutoff: int) -> None:
        owner = row["owner_id"]
        batch = row["batch_uuid"]
        folders = [_item_dir(self._uploads_root, owner, {"batch_uuid": batch, "item_uuid": item})
                   for item in row["item_uuids"]]
        if not self._database.prune_upload_batch(
                owner_id=owner, batch_uuid=batch, updated_before=cutoff, dry_run=True):
            return
        for folder in folders:
            try:
                os.rmdir(folder)
            except FileNotFoundError:
                pass
            except OSError:
                return  # holds something unknown: batch skipped
        try:
            os.rmdir(owner_dir(self._uploads_root, owner) / _safe_uuid(batch))
        except FileNotFoundError:
            pass
        except OSError:
            return
        self._database.prune_upload_batch(owner_id=owner, batch_uuid=batch, updated_before=cutoff)


class UploadJanitorThread(WorkerThread):
    """Runs ``janitor.run_once()`` every ``interval_s`` until stopped. Startup
    already ran a pass, so the first periodic one waits one interval."""

    thread_name = "upload-janitor"

    def __init__(self, janitor, *, interval_s):
        super().__init__()
        self._janitor = janitor
        self._interval_s = interval_s

    def _first_wait_s(self):
        return self._interval_s

    def run_step(self):
        try:
            self._janitor.run_once()
        except Exception as e:
            log.warning("upload janitor pass failed: %s", type(e).__name__)
        return self._interval_s
