"""Upload commit recovery (Phase 7 spec §6 restart rules, SC-16e)."""
import errno
import json
import logging
import os
import stat
import time
from pathlib import Path

from app.core.operator_log import operator_logger
from app.database.database import ANY_OWNER
from app.services import audio_identity, metadata, organizer, upload_placement
from app.services.identity_reasons import is_content_failure, is_stored_data_failure
from app.services.media_input import item_demuxer
from app.services.path_sanitize import assert_within
from app.services.upload_receipt import ReceiptFiles, owner_dir, remove_verified

log = logging.getLogger(__name__)


def reconcile_upload_commits(database, *, publisher, uploads_root, music_library_dir, cover_art,
                             compute_exact=None, extract_art=None) -> int:
    """Startup: resume every ``prepared`` or ``moved`` commit journal a dead
    process left, across owners, through the publisher. ``committing`` journals
    are left to the commit worker, which re-claims dead leases. One row's
    failure is logged and the rest still run. Returns the rows handed over."""
    for row in database.list_upload_commit_journals_to_resume(("committing",)):
        if row["cover_art_id"] is None:
            try:
                _adopt_art(database, row, uploads_root, cover_art,
                           extract_art or metadata.extract_cover_art_bytes)
            except Exception as e:
                log.warning("upload commit art recovery failed: %s", type(e).__name__)
    # Read first: a journal this pass fails is cleaned by the next one.
    finished = database.list_finished_upload_commit_journals()
    handed = 0
    compute = compute_exact or audio_identity.compute_exact
    for row in database.list_upload_commit_journals_to_resume():
        handed += 1
        try:
            try:
                audio = _AudioProof.for_row(database, row, compute)
            except Exception as e:  # e.g. the item's demuxer could not be read: unknown
                audio, valid, why = None, None, type(e).__name__
            else:
                try:
                    row = advance_if_placed(database, row, uploads_root=uploads_root,
                                            music_library_dir=music_library_dir, audio=audio)
                    if audio is not None and audio.matched and row["state"] == "moved":
                        valid, why = True, None  # that decode was the check: one decode at restart
                    else:
                        audio = None
                        valid, why = _valid(database, row, compute)
                except OSError as e:  # the placement proof could not examine the final name
                    valid, why = None, (getattr(e, "reason", None)
                                        or errno.errorcode.get(e.errno) or type(e).__name__)
            if valid is None:
                # Unknown (the tool or the run failed) is never "different": the
                # journal and every file stay as they are for the next start.
                operator_logger.warning(
                    "An upload commit of user %s could not be checked (%s); it is"
                    " left as it is and checked again at the next start.",
                    row["owner_id"], why)
            elif valid:
                outcome = publisher(row)
                if audio is not None:
                    operator_logger.warning(
                        "An upload commit interrupted by a crash (operation %s, item %s) was"
                        " recognised at startup by its library file's name and audio: %s.",
                        row["operation_uuid"], row["item_uuid"], outcome)
            else:
                publisher.fail_recovered(row)
        except Exception as e:
            log.warning("upload commit recovery failed: %s", type(e).__name__)
    for row in finished:
        try:
            clean_finished_journal(
                database, row, uploads_root=uploads_root, music_library_dir=music_library_dir,
                cover_art=cover_art)
        except Exception as e:
            log.warning("upload commit clean-up failed: %s", type(e).__name__)
    return handed


def clean_finished_journal(database, row: dict, *, uploads_root, music_library_dir, cover_art,
                           clock=time.time) -> bool:
    """Finish what a finished (imported, duplicate_conflict, failed) commit journal
    left behind, then delete the journal row (the receipt stays). Every removal
    is proven the operation's own first. True when the row was deleted; False
    keeps it for the next pass."""
    owner = row["owner_id"]
    op = row["operation_uuid"]
    state = row["state"]
    if state not in ("imported", "duplicate_conflict", "failed"):
        return False
    from app.library import library_root  # deferred: app.library imports the services

    root = library_root(music_library_dir, database.get_user(owner))
    stage = owner_dir(uploads_root, owner)
    files = ReceiptFiles()
    clean = True
    if row.get("work_path"):
        work = Path(row["work_path"])
        try:
            assert_within(work, stage)
        except ValueError:
            return False  # not ours: never removed; the row and its reservation stay
        if not remove_verified(files, work):
            clean = False
    if clean:
        database.release_upload_work(owner_id=owner, operation_uuid=op)
    else:
        return False
    if state == "imported":
        clean = _release_source(database, row, stage, files, clock)
        if clean and row["cover_art_created"] == 1 and row["cover_art_id"] is not None:
            # Art the published track uses is refused; a rerun that found none leaks it.
            cover_art.release_if_unreferenced(row["cover_art_id"])
    else:
        clean = _remove_placed_final(database, row, root, files)
        if row["cover_art_created"] == 1 and row["cover_art_id"] is not None:
            cover_art.release_if_unreferenced(row["cover_art_id"])  # refusing is final
    # A fallback's leftovers (temp, then placement record) go before the row.
    if not clean or not upload_placement.clear_leftovers(
            row, uploads_root=uploads_root, library_root=root):
        return False
    return database.delete_finished_upload_commit_journal(
        owner_id=owner, operation_uuid=op, state=state)


def _release_source(database, row: dict, stage: Path, files, clock) -> bool:
    """The staged source goes only while the imported item still records it."""
    owner = row["owner_id"]
    recorded = database.get_upload_item_source_path(row["item_uuid"], owner_id=owner)
    item = database.get_upload_item(row["item_uuid"], owner_id=owner)
    if recorded is None or recorded != row["source_path"] or item is None \
            or item["state"] != "imported":
        return True  # not ours any more
    source = Path(recorded)
    assert_within(source, stage)
    if not remove_verified(files, source):
        return False
    database.release_cancelled_upload_source(
        row["item_uuid"], owner_id=owner, source_path=recorded, now=int(clock()),
        from_states=("imported",))
    return True


def _remove_placed_final(database, row: dict, root: Path, files) -> bool:
    """``final_path`` is set only when this operation placed it; it goes unless a
    track of any owner names it. ``root`` is the owner's library root."""
    if not row.get("final_path"):
        return True
    final = Path(row["final_path"])
    assert_within(final, root)
    if database.track_path_in_use(str(final), owner_id=ANY_OWNER):
        return True
    if not remove_verified(files, final):
        return False
    organizer.prune_empty_dirs(final.parent, root)
    return True


def _valid(database, row: dict, compute_exact) -> tuple[bool | None, str | None]:
    """``(verdict, reason)``. The file the publisher would publish (work when
    prepared, final when moved) is a non-empty regular file and, with a current
    verified digest, still hashes to it. False: missing, empty, not regular, or a
    digest that differs or cannot be computed because of the file's content, or the
    journal's own stored data is deterministically unusable (a parse error on values
    already read: ``is_stored_data_failure``). None:
    the check did not finish (an exception, or the tool or the run failed):
    unknown, not different; the caller leaves everything untouched. ``reason``
    says why for None (a fixed reason or an exception type name), never a path."""
    try:
        path = Path(row["work_path"] if row["state"] == "prepared" else row["final_path"])
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or st.st_size <= 0:
            return False, None
        checked = row["digest_check"] in _DIGEST_CHECKED and row["exact_state"] == "current"
        try:
            codec, expected = _stored_facts(row, checked)
        except Exception as e:
            if not is_stored_data_failure(e):
                raise
            log.warning("upload commit journal data unusable: %s", type(e).__name__)
            return False, None
        if checked:
            with open(path, "rb") as f:  # a file that cannot be opened is unknown, not damaged
                f.read(1)
            # The staged bytes open only their input; an unknown container keeps the plain call.
            demuxer = item_demuxer(database, row["owner_id"], row["item_uuid"])
            return _digest_verdict(compute_exact, path, codec, expected, demuxer)
        return True, None
    except (FileNotFoundError, NotADirectoryError):
        return False, None
    except Exception as e:
        # A check that did not finish proves nothing: unknown, never invalid.
        log.warning("upload commit validation failed: %s", type(e).__name__)
        return None, type(e).__name__


def _stored_facts(row: dict, checked: bool):
    """The journal's own stored data: ``(codec, expected digest or None)``."""
    codec = json.loads(row["final_metadata"])["codec"]
    if not isinstance(codec, str):
        raise TypeError("stored codec is not a str")
    return codec, (audio_identity.identity_from_columns(row).exact if checked else None)


_DIGEST_CHECKED = ("verified", "computed", "changed")


def _digest_verdict(compute_exact, path, codec, expected, demuxer) -> tuple[bool | None, str | None]:
    """Decode ``path`` (low priority, the item's demuxer forced when known) and
    compare with the stored exact hash: ``(verdict, reason)`` as in ``_valid``.
    ``unsupported`` (answered from the codec hint alone) and a content failure
    are False; any other failure is unknown (None) with its reason."""
    forced = {} if demuxer is None else {"input_format": demuxer}
    computed = compute_exact(path, codec, low_priority=True, **forced)
    if isinstance(computed, audio_identity.ExactUnavailable):
        if computed.state == "unsupported" or is_content_failure(computed.reason):
            return False, None
        return None, computed.reason or "unknown"
    return audio_identity.exact_match(computed, expected), None


class _AudioProof:
    """Startup's third placement proof for one row: the final's decoded audio
    equals the journaled digest of the prepared work file. ``matched`` says it
    proved the final. Built only when the stored digest describes the work file
    (checked, current, usable) and the item's demuxer is known."""

    def __init__(self, compute_exact, codec, expected, demuxer):
        self._args = (codec, expected, demuxer)
        self._compute_exact = compute_exact
        self.matched = False

    @classmethod
    def for_row(cls, database, row: dict, compute_exact):
        if row["state"] != "prepared" or row["digest_check"] not in _DIGEST_CHECKED \
                or row["exact_state"] != "current":
            return None
        try:
            codec, expected = _stored_facts(row, True)
        except Exception:  # unusable stored data: as before (``_valid`` decides)
            return None
        demuxer = item_demuxer(database, row["owner_id"], row["item_uuid"])
        if expected is None or demuxer is None:
            return None  # an unknown container is never decoded here
        return cls(compute_exact, codec, expected, demuxer)

    def __call__(self, final: Path) -> bool:
        codec, expected, demuxer = self._args
        try:
            verdict, why = _digest_verdict(self._compute_exact, final, codec, expected, demuxer)
        except Exception as e:  # a check that did not finish proves nothing
            raise upload_placement.AudioUnknown(type(e).__name__) from e
        if verdict is None:
            raise upload_placement.AudioUnknown(why)
        self.matched = verdict
        return verdict


def _adopt_art(database, row: dict, uploads_root, cover_art, extract_art) -> None:
    """A crash after the art was registered and before it was journaled: resolve
    it again from the work copy; it is this operation's only when nothing else
    references it (the database checks that in the journaling transaction)."""
    if not row.get("work_path"):
        return
    work = Path(row["work_path"])
    assert_within(work, owner_dir(uploads_root, row["owner_id"]))
    if os.path.islink(work) or not os.path.isfile(work):  # none yet: nothing registered
        return
    demuxer = item_demuxer(database, row["owner_id"], row["item_uuid"])
    data = extract_art(work, **({} if demuxer is None else {"input_format": demuxer}))
    if not data:
        return
    try:
        result = cover_art.add_album_art_with_status(data)
    except ValueError:
        return
    database.adopt_upload_commit_art(
        owner_id=row["owner_id"], operation_uuid=row["operation_uuid"],
        cover_art_id=result.cover_art_id, now=int(time.time()))


def advance_if_placed(database, row: dict, *, uploads_root, music_library_dir, audio=None) -> dict:
    """A ``prepared`` journal whose final name is already this operation's file
    (crash after the placement: the work file's own link, a moved or copied
    file its placement record proves, or, at startup only (``audio`` given,
    the work file proven absent), a file whose name and audio prove it) is
    ``moved``: the placed file is ours, so the journal says so before anything
    else decides about it. Raises ``LinkUnknown`` when the final name or its
    audio cannot be examined."""
    if row["state"] != "prepared" or not row.get("work_path") or not row.get("final_path"):
        return row
    from app.library import library_root  # deferred: app.library imports the services

    placed = upload_placement.final_is_placed(
        row, uploads_root=uploads_root,
        library_root=library_root(music_library_dir, database.get_user(row["owner_id"])),
        audio=audio)
    if placed and database.mark_upload_commit_moved(
            owner_id=row["owner_id"], operation_uuid=row["operation_uuid"], now=int(time.time())):
        return {**row, "state": "moved"}
    return row
