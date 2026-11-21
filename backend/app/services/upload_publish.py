"""Upload publish (Phase 7 spec §6 steps 4-6): move the prepared work file to
its final path, insert the track in one transaction, finish the item."""

import errno
import json
import logging
import os
import re
import time
import uuid
from pathlib import Path

from app.core.operator_log import operator_logger
from app.database.database import ANY_OWNER, CoverArtGone
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import audio_identity, metadata, organizer, upload_placement
from app.services.audio_identity import identity_from_columns
from app.services.media_input import item_demuxer
from app.services.path_sanitize import assert_within
from app.services.upload_errors import commit_disk_full, upload_commit_failed, upload_library_changed
from app.services.upload_receipt import ReceiptFiles, owner_dir, remove_then_release, remove_verified

log = logging.getLogger(__name__)

# One operator line per fallback mode and process (no path or user data).
_FALLBACK_LINES = {
    "rename": "The music library cannot take hard links: uploaded files are moved into place"
              " instead, with weaker protection against a crash.",
    "copy": "The music library cannot take hard links from its uploads folder (another"
            " filesystem): uploaded files are copied into place instead, with weaker protection"
            " against a crash.",
}

SEAM_POINTS = ("after_link", "after_moved_journal", "after_work_unlink", "after_insert_commit",
               "after_conflict_journal", "after_conflict_cleanup", "after_failure_journal",
               "after_source_removed", "before_link", "before_insert_commit",
               # the link fallback's own boundaries (the last three reached through the organizer)
               "after_place_record", "mid_copy", "after_copy", "after_temp_placed")


class SimulatedCrash(BaseException):
    """Test-only: raised by a seam to stop the publisher dead, like a process kill."""


class _MoveFailed(Exception):
    """The link or the moved journal did not happen; nothing of ours is placed."""


class UploadPublisher:
    def __init__(self, database, *, uploads_root, music_library_dir, cover_art, identity_signal,
                 fingerprinter_present: bool, clock=time.time,
                 extract_art=metadata.extract_cover_art_bytes, seam=None, copy_floor_bytes=None):
        self._database = database
        self._uploads_root = uploads_root
        self._music_library_dir = music_library_dir
        self._cover_art = cover_art
        self._identity_signal = identity_signal
        self._fingerprinter_present = fingerprinter_present
        self._clock = clock
        self._extract_art = extract_art
        self._seam = seam
        self._copy_floor_bytes = copy_floor_bytes
        self._fallback_logged = set()  # fallback modes already reported to the operator

    def _at(self, name: str) -> None:
        if self._seam is not None:
            self._seam(name)

    def __call__(self, prepared: dict) -> str:
        """Steps 3-6 on a ``prepared`` journal row, or step 5 onward on a ``moved``
        one (the final file is then this operation's). Any other state: nothing
        is touched."""
        prepared = dict(prepared)  # art re-registration updates this copy
        state = prepared.get("state")
        if state not in ("prepared", "moved"):
            return "error"
        owner = prepared["owner_id"]
        progress = {"final": None, "work_removed": False}  # what this run placed
        try:
            if state == "prepared":
                conflicts = self._database.upload_commit_preflight(
                    owner_id=owner, operation_uuid=prepared["operation_uuid"])
                if conflicts is None:
                    return "error"
                if conflicts:
                    return self._conflict_before_move(prepared, conflicts)
                self._move(prepared, progress)
            else:
                self._resume_moved(prepared, progress)
            status = self._publish(prepared, progress["final"], progress["work_removed"])
        except _MoveFailed as e:
            return self._fail_safely(prepared, None, False, e.__cause__ or e)
        except organizer.LinkUnknown as e:  # the conflict proof or an unreadable placement record
            log.warning("upload commit final name not examined: %s", type(e).__name__)
            return "error"
        except Exception as e:
            return self._fail_safely(prepared, progress["final"], progress["work_removed"], e)
        final = progress["final"]
        if status == "duplicate_conflict":
            self._at("after_conflict_journal")
            self._remove_own_final(final, owner)
            self._at("after_conflict_cleanup")
            self._release_created_art(prepared)
            return "duplicate_conflict"
        if status != "imported":
            return "error"
        self._at("after_insert_commit")
        self._identity_signal.notify()
        self._remove_source(prepared)
        return "imported"

    def fail_recovered(self, prepared: dict) -> str:
        """Recovery found the file this journal would publish missing or corrupt:
        record the failure (source retained). A moved journal's final file is
        ours; a prepared journal's only when it is the work file's own link or
        a file its placement record proves."""
        prepared = dict(prepared)
        final = Path(prepared["final_path"])
        placed = prepared.get("state") == "moved"
        if not placed:
            try:
                placed = self._final_is_placed(prepared)
            except organizer.LinkUnknown as e:  # unknown, not "not ours": record nothing
                log.warning("upload commit final name not examined: %s", type(e).__name__)
                return "error"
        # A library changed outside the server is why the file is missing or
        # invalid: recorded as such, for good, instead of an invalid file.
        cause = RuntimeError("recovered file invalid")
        try:
            upload_placement.assert_final_within(final, self._library_root(prepared["owner_id"]))
        except upload_placement.LibraryChanged as e:
            cause = e
        except Exception:
            pass
        return self._fail_safely(prepared, final if placed else None, False, cause)

    def _fail_safely(self, prepared: dict, final, work_removed: bool, exc) -> str:
        try:
            return self._fail(prepared, final, work_removed, exc)
        except Exception as e:  # recording the failure failed too
            log.warning("upload publish failure not recorded: %s", type(e).__name__)
            return "error"

    def _resume_moved(self, prepared: dict, progress: dict) -> None:
        """A ``moved`` journal: the final file is this operation's; drop the work
        name if it is still there."""
        owner = prepared["owner_id"]
        final = Path(prepared["final_path"])
        work = Path(prepared["work_path"])
        upload_placement.assert_final_within(final, self._library_root(owner))
        assert_within(work, owner_dir(self._uploads_root, owner))
        progress["final"] = final
        progress["work_removed"] = remove_verified(ReceiptFiles(), work)

    def _remove_source(self, prepared: dict) -> None:
        """Step 6: give the staged source back once the import is durable; the
        row is released only when the file is verifiably gone. Never fails the
        import."""
        owner = prepared["owner_id"]
        try:
            source = Path(prepared["source_path"])
            released = remove_then_release(
                ReceiptFiles(), source,
                lambda: self._database.release_removed_upload_source(
                    prepared["item_uuid"], owner_id=owner, source_path=str(source),
                    now=int(self._clock()), from_states=("imported",)),
                within=owner_dir(self._uploads_root, owner), remove=remove_verified,
                between=lambda: self._at("after_source_removed"))
            if released is None:  # the file is still there
                log.warning("imported source not removed")
        except Exception as e:
            log.warning("imported source cleanup incomplete: %s", type(e).__name__)

    def _track(self, prepared: dict, final: Path, cover_art_id=...) -> Track:
        now = int(self._clock())
        meta = {k: v for k, v in json.loads(prepared["final_metadata"]).items() if k != "v"}
        if cover_art_id is not ...:
            meta["cover_art_id"] = cover_art_id
        return Track(
            uuid_id=prepared["reserved_track_uuid"], file_path=final,
            metadata=TrackMetaData(**meta), created_at=now, last_updated=now,
            audio_identity=identity_from_columns(prepared))

    def _publish(self, prepared: dict, final: Path, work_removed: bool) -> str:
        """Step 5; a vanished cover art row is re-registered from the final file
        and the transaction retried once."""
        stat = audio_identity.stat_snapshot(final)
        track = self._track(prepared, final)
        for attempt in (1, 2):
            try:
                self._at("before_insert_commit")
                status, _ = self._database.publish_upload_commit(
                    owner_id=prepared["owner_id"], operation_uuid=prepared["operation_uuid"],
                    track=track, stat=stat, fingerprinter_present=self._fingerprinter_present,
                    work_removed=work_removed, now=int(self._clock()))
                return status
            except CoverArtGone:
                if attempt == 2:
                    raise
                track = self._track(prepared, final, self._reregister_art(prepared, final))

    def _reregister_art(self, prepared: dict, final: Path):
        """The new cover art id (journaled), or None when the file has no usable art."""
        demuxer = item_demuxer(self._database, prepared["owner_id"], prepared["item_uuid"])
        data = self._extract_art(final, **({} if demuxer is None else {"input_format": demuxer}))
        if not data:
            return None
        try:
            result = self._cover_art.add_album_art_with_status(data)
        except ValueError as e:
            log.warning("embedded artwork not usable: %s", type(e).__name__)
            return None
        created = 1 if result.was_created else 0
        if not self._database.record_upload_publish_art(
                owner_id=prepared["owner_id"], operation_uuid=prepared["operation_uuid"],
                cover_art_id=result.cover_art_id, cover_art_created=result.was_created,
                now=int(self._clock())):
            raise RuntimeError("publish art not journaled")
        prepared["cover_art_id"], prepared["cover_art_created"] = result.cover_art_id, created
        return result.cover_art_id

    def _move(self, prepared: dict, progress: dict) -> None:
        """Step 4: place work -> final (an existing final that is this work
        file's own link counts as placed), journal moved, drop the work link.
        Hard link first; a library that refuses links gets the work file moved
        or copied, after its placement record is flushed. Fills ``progress``;
        raises _MoveFailed (cause set) when nothing was placed or the journal
        could not move."""
        owner = prepared["owner_id"]
        db = self._database
        final = Path(prepared["final_path"])
        work = Path(prepared["work_path"])
        upload_placement.assert_final_within(final, self._library_root(owner))
        assert_within(work, owner_dir(self._uploads_root, owner))

        measured = {}  # a copy hashes the work file before its temp exists

        def before_temp() -> None:
            measured["work"] = upload_placement.measure(prepared)

        def before_fallback(mode: str) -> None:
            if mode not in self._fallback_logged:
                self._fallback_logged.add(mode)
                operator_logger.warning(_FALLBACK_LINES[mode])
            upload_placement.write_record(prepared, uploads_root=self._uploads_root,
                                          library_root=self._library_root(owner),
                                          temp=mode == "copy", measured=measured.get("work"))
            self._at("after_place_record")

        self._at("before_link")
        # An earlier attempt's temp goes (durably) before a new record can replace its proof.
        upload_placement.remove_earlier_temp(prepared, uploads_root=self._uploads_root,
                                             library_root=self._library_root(owner))
        try:
            placed = organizer.place_no_replace(
                work, final, in_use=lambda p: db.track_path_in_use(str(p), owner_id=ANY_OWNER),
                before_fallback=before_fallback, copy_floor_bytes=self._copy_floor_bytes,
                seam=self._at, before_temp=before_temp)
        except OSError as e:
            raise _MoveFailed() from e
        if placed is None:
            raise _MoveFailed()
        progress["final"] = final  # ours from here on
        self._at("after_link")
        # The final name and every folder made for it are durable before the journal moves.
        library_root = self._library_root(owner)
        folder = final.parent
        while True:
            ReceiptFiles().sync_dir(folder)
            if folder == library_root or folder == folder.parent:
                break
            folder = folder.parent
        if placed == "moved":  # the work name is gone: make its removal durable too
            ReceiptFiles().sync_dir(work.parent)
        if not db.mark_upload_commit_moved(
                owner_id=owner, operation_uuid=prepared["operation_uuid"], now=int(self._clock())):
            raise RuntimeError("commit journal is no longer prepared")
        self._at("after_moved_journal")
        progress["work_removed"] = remove_verified(ReceiptFiles(), work)
        self._at("after_work_unlink")

    def _fail(self, prepared: dict, final, work_removed: bool, exc) -> str:
        """Record the failure, then remove this operation's own file: the work
        copy when nothing was placed, else the placed final file (and the work
        link if it is still there); the work reservation goes once the work
        link is verifiably gone. A fallback placement that took effect but
        reported an error is ours when the placement record proves it."""
        owner = prepared["owner_id"]
        op = prepared["operation_uuid"]
        log.warning("upload publish failed: %s", type(exc).__name__)
        if final is None:
            try:
                if upload_placement.record_proves_final(
                        prepared, uploads_root=self._uploads_root,
                        library_root=self._library_root(owner)):
                    final = Path(prepared["final_path"])
            except organizer.LinkUnknown as e:  # unknown, not "not ours": record nothing
                log.warning("upload commit final name not examined: %s", type(e).__name__)
                return "error"
        disk_full = isinstance(exc, OSError) and exc.errno in (errno.ENOSPC, errno.EDQUOT)
        library_changed = isinstance(exc, upload_placement.LibraryChanged)
        # A changed library folder refuses every retry the same way: final, and
        # only the operator can fix it, so the line names what was found.
        if library_changed:
            error = upload_library_changed()
        else:
            error = commit_disk_full() if disk_full else upload_commit_failed()
        if not self._database.fail_upload_publish(
                owner_id=owner, operation_uuid=op, error_code=error.code,
                error_message=error.message, now=int(self._clock()), placed=final is not None,
                retryable=error.retryable):
            return "error"
        if library_changed:
            upload_placement.log_library_changed(owner, exc)
        self._at("after_failure_journal")
        try:
            if final is not None:
                self._remove_own_final(final, owner)
            work = Path(prepared["work_path"])
            assert_within(work, owner_dir(self._uploads_root, owner))
            if work_removed or remove_verified(ReceiptFiles(), work):
                self._database.release_upload_work(owner_id=owner, operation_uuid=op)
            else:
                log.warning("failed commit work copy not removed")
        except Exception as e:
            log.warning("failed commit cleanup incomplete: %s", type(e).__name__)
        self._release_created_art(prepared)
        return "failed"

    def _final_is_placed(self, prepared: dict) -> bool:
        """The final name is this operation's file (raises ``LinkUnknown``)."""
        return upload_placement.final_is_placed(
            prepared, uploads_root=self._uploads_root,
            library_root=self._library_root(prepared["owner_id"]))

    def _library_root(self, owner: int) -> Path:
        return upload_placement.owner_library_root(
            self._music_library_dir, self._database.get_user(owner))

    def _conflict_before_move(self, prepared: dict, track_uuids) -> str:
        """Step 3: record the conflict, then remove this operation's work copy
        (the reservation only once it is verifiably gone) and created art."""
        owner = prepared["owner_id"]
        op = prepared["operation_uuid"]
        final = Path(prepared["final_path"])
        # A crash after the placement leaves the final name as this operation's file.
        placed = self._final_is_placed(prepared)
        if not self._database.record_upload_commit_conflict(
                owner_id=owner, operation_uuid=op, track_uuids=track_uuids, now=int(self._clock()),
                placed=placed):
            return "error"
        self._at("after_conflict_journal")
        if placed:
            self._remove_own_final(final, owner)
        try:
            work = Path(prepared["work_path"])
            assert_within(work, owner_dir(self._uploads_root, owner))
            if remove_verified(ReceiptFiles(), work):
                self._database.release_upload_work(owner_id=owner, operation_uuid=op)
            else:
                log.warning("conflict work copy not removed")
        except Exception as e:
            log.warning("conflict work copy not removed: %s", type(e).__name__)
        self._at("after_conflict_cleanup")
        self._release_created_art(prepared)
        return "duplicate_conflict"

    def _remove_own_final(self, final: Path, owner: int) -> None:
        """Remove the final file this operation placed, unless a track now
        references that path, then prune its empty directories."""
        try:
            upload_placement.assert_final_within(final, self._library_root(owner))
            if self._database.track_path_in_use(str(final), owner_id=ANY_OWNER):
                return
            if remove_verified(ReceiptFiles(), final):
                organizer.prune_empty_dirs(final.parent, self._library_root(owner))
            else:
                log.warning("conflict final file not removed")
        except Exception as e:
            log.warning("conflict final file not removed: %s", type(e).__name__)

    def _release_created_art(self, prepared: dict) -> None:
        art_id = prepared["cover_art_id"]
        if prepared["cover_art_created"] == 1 and art_id is not None:
            try:
                self._cover_art.release_if_unreferenced(art_id)
            except Exception as e:
                log.warning("conflict artwork not released: %s", type(e).__name__)


_PROBE_NAME = re.compile(r"\.link-probe-[0-9a-f]{32}")


def _probe_folders(users, music_library_dir) -> tuple[list[Path], bool]:
    """Every folder the probe may use: each user's existing library root and the
    music library itself (a root not made yet is probed there), never above it;
    and whether all of them could be looked at. A root that cannot be used is
    skipped alone (type-only warning)."""
    from app.library import library_root  # deferred: app.library imports the services

    music = Path(music_library_dir)
    folders, complete = [], True
    for user in users:
        try:
            root = library_root(music_library_dir, user)
            if root.is_dir():
                assert_within(root, music)
                folders.append(root)
        except Exception as e:
            complete = False
            log.warning("upload link probe skipped one library root: %s", type(e).__name__)
    if music.is_dir():
        folders.append(music)
    return folders, complete


def _twin_absent(folder: Path, name: str, scratch=None) -> bool:
    """True when ``folder / name`` is proven not to be ``scratch``'s own link:
    it does not exist, or it was examined and is another file. A folder that
    cannot be searched or read proves nothing."""
    try:
        os.lstat(folder / name)
    except (FileNotFoundError, NotADirectoryError):
        return True
    except OSError:
        return False
    return scratch is None or not organizer.is_own_hard_link(scratch, folder / name)


def _sweep_probe_leftovers(uploads_root, folders, complete) -> None:
    """A probe killed between its link and its unlink left a scratch file and its
    link under one name. A library name goes only when it is proven to be that
    scratch's own link, and the scratch (the only proof) only once every folder
    it could be in was looked at and proven free of it."""
    for scratch in Path(uploads_root).iterdir():
        try:
            if not _PROBE_NAME.fullmatch(scratch.name) or scratch.is_symlink() or not scratch.is_file():
                continue
            for f in folders:
                if organizer.is_own_hard_link(scratch, f / scratch.name):
                    (f / scratch.name).unlink()
            if complete and all(_twin_absent(f, scratch.name, scratch) for f in folders):
                scratch.unlink(missing_ok=True)
        except Exception as e:
            log.warning("upload link probe sweep failed for one file: %s", type(e).__name__)


def probe_library_links(database, *, uploads_root, music_library_dir) -> list[int]:
    """Startup probe (review r1 7-R1-10, r2 7-R2-11): the owners whose library
    root cannot take a hard link from ``uploads_root``. First it sweeps what an
    earlier killed probe left. Each probe uses one name for its scratch and its
    link, in the user's library root, or the music library when that root is not
    made yet (never above it; nothing is created). The scratch goes only once the
    library name is gone, so a name that stays keeps its proof for the next sweep.
    A refusal that means "no hard links" (``organizer.FALLBACK_ERRNOS``) adds the owner
    and logs one operator warning (errno name and user id, never a path or name)
    saying uploads there are moved or copied into place instead (link fallback);
    any other failure is logged and the owner is skipped (unknown is not a
    refusal). Never raises."""
    from app.library import library_root  # deferred: app.library imports the services

    refused = []
    try:
        users = database.list_users()
    except Exception as e:
        log.warning("upload link probe could not list users: %s", type(e).__name__)
        return refused
    try:
        _sweep_probe_leftovers(uploads_root, *_probe_folders(users, music_library_dir))
    except Exception as e:
        log.warning("upload link probe sweep failed: %s", type(e).__name__)
    for user in users:
        probe = f".link-probe-{uuid.uuid4().hex}"
        scratch = Path(uploads_root) / probe
        name = None
        try:
            folder = library_root(music_library_dir, user)
            if folder.is_dir():
                assert_within(folder, music_library_dir)
            else:
                folder = Path(music_library_dir)
                if not folder.is_dir():
                    log.warning("upload link probe skipped one user: no library folder")
                    continue
            name = folder / probe
            scratch.write_bytes(b"")
            try:
                organizer.os.link(scratch, name)
            except OSError as e:
                name = None  # never made
                if e.errno in organizer.FALLBACK_ERRNOS:
                    refused.append(user["id"])
                    operator_logger.warning(
                        "The music library of user %s cannot take hard links (%s): uploads there"
                        " are moved or copied into place instead, with weaker protection against"
                        " a crash.", user["id"], errno.errorcode.get(e.errno, e.errno))
                else:
                    operator_logger.warning(
                        "The music library of user %s could not be checked for hard links (%s).",
                        user["id"], errno.errorcode.get(e.errno, e.errno))
                continue
            if organizer.is_own_hard_link(scratch, name):
                name.unlink()
        except Exception as e:
            log.warning("upload link probe failed for one user: %s", type(e).__name__)
        finally:
            try:
                if name is None or _twin_absent(name.parent, name.name, scratch):  # the proof stays unless the name is proven gone
                    scratch.unlink(missing_ok=True)
            except OSError:
                log.warning("upload link probe scratch file not removed")
    return refused
