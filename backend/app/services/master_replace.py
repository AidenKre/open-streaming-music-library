"""The sequence that puts a track's new master file at a new path.

A tag edit that changes the artist or album (``TrackEditor``) and a conversion
to another extension (``ConversionOrchestrator``) both replace a track's master
by a staged copy that ends up at another path. ``move_to_new_path`` is that
sequence, written once. What differs between the two callers is passed in or
stays with them: the journal intent, the database commit, what happens right
after the commit (a conversion evicts the encoded caches), how a released
staged copy is dropped (the editor deletes it at once; the conversion leaves
it to its ``finally``, after its lock and its log line), their error types and
log lines, the track lock (the caller holds it for the whole call) and the
checks that every path lies inside the owner's root.

What the sequence guarantees (the crash matrix ``tests/test_master_replace_*``
stops it before every step):

- no track is given a path another track's row names, even with no file there
  (refused like a file at the path, before the journal row is written; a row
  that comes to name it after that is refused by the database at the commit,
  which is undone like any commit that raises and answered the same way);
- the journal row exists, and one flush of it was tried, before a file appears
  at the new path;
- from the call on the staged copy is the journal's: the caller may drop it
  only when the sequence says so (``release_staged``), which it does only
  after the row is gone or was never written (recovery reads "staged copy
  present" as "the move never happened");
- the move is flushed before the commit;
- a commit that raises is undone: the copy goes back to staging (or is deleted),
  the row is deleted, then the staged copy is released;
- after the commit the old master is deleted only after a durable point;
  otherwise it stays with the row and is remembered for the running server.

A same-path replace (an edit or a conversion that keeps the path) is not here:
its two forms share three statements and differ in everything around them
(who writes the row, the durable point, a refused replace, the identity step),
so each stays where it is.

``flush_journal_row`` and ``settle_old_master`` used to live in
``track_editor.py``, which still exports them.
"""

import logging
from pathlib import Path
from typing import Callable, TypeVar

from app.core.operator_log import operator_logger
from app.database.database import ANY_OWNER, Database, TrackPathTaken
from app.library import Library
from app.services.journal_recovery import (
    PendingOldMasters,
    is_current_master,
    reached_durable_point,
)
from app.services.file_ops import flush_move, move_back, move_file, prune_empty_dirs

# The lines these functions log keep the logger name they had in track_editor.py.
logger = logging.getLogger("app.services.track_editor")

T = TypeVar("T")


class MoveRefused(Exception):
    """The staged copy could not be placed at the new path. Nothing changed: the
    journal row is gone again (or was never written) and the staged copy was
    released."""


def move_to_new_path(
    library: Library, uuid_id: str, *, intent: str, source: Path, dest: Path, staged: Path,
    root: Path, commit: Callable[[], T], release_staged: Callable[[], None],
    pending_old_masters: PendingOldMasters, after_commit: Callable[[], None] = lambda: None,
) -> T:
    """Replace the master at ``source`` by the flushed ``staged`` copy placed at
    ``dest``; ``commit`` points the track at ``dest`` in the database and its
    answer is returned. The caller holds the track's lock and has checked the
    paths. From this call on the caller must not drop ``staged`` unless
    ``release_staged`` was called (no journal row names it any more, and it was
    not moved into the library). Raises ``MoveRefused`` when the copy cannot be
    placed or the database refuses ``dest`` at the commit (``TrackPathTaken``),
    and whatever else ``commit`` raises (after undoing the move)."""
    # Journal the move BEFORE doing it: a crash in the move↔commit window is
    # reverted (DB not advanced) or finished (DB advanced) at startup.
    try:
        # No track is ever given a path another track's row names (any owner;
        # any spelling a caseless disk reads as the same name), even when no
        # file is there: that track's master is missing, and a later deletion
        # of either track would take the other's file. Refused like a file at
        # the path.
        if library.unbound_database.track_path_in_use(
            str(dest), owner_id=ANY_OWNER, exclude_uuid=uuid_id
        ):
            raise MoveRefused()
        entry = library.insert_journal_entry(
            intent, uuid_id, old_path=str(source), new_path=str(dest), temp_path=str(staged),
        )
    except BaseException:
        release_staged()  # nothing journaled yet
        raise
    flushed = flush_journal_row(library.unbound_database, entry, uuid_id)
    if not move_file(file_path=staged, destination_path=dest):
        # A folder the refused move made goes while the row still exists (after
        # it nothing would tell the next start about the folder). The staged
        # copy stays until the row is gone: while the row exists it shows
        # recovery that the move never happened.
        prune_empty_dirs(dest.parent, root)
        library.delete_journal_entry(entry)
        release_staged()
        raise MoveRefused()
    flush_move(dest, staged, root)
    try:
        result = commit()
    except BaseException as error:
        # DB did not commit → revert: put the new copy back in staging and
        # keep the old master. The staged copy is released only after the row
        # is deleted, so a kept row still shows that the move was undone.
        if not move_back(dest, staged):
            dest.unlink(missing_ok=True)
        prune_empty_dirs(dest.parent, root)
        library.delete_journal_entry(entry)
        release_staged()
        if isinstance(error, TrackPathTaken):
            # The database's own refusal: another track's row came to name
            # ``dest`` after the question above. The same answer as there.
            raise MoveRefused() from error
        raise
    after_commit()
    # Committed: DB now points at `dest`; the old master is redundant.
    settle_old_master(
        library, entry, uuid_id, source, dest, root, pending_old_masters, wait=flushed
    )
    return result


def flush_journal_row(database: Database, entry_id: int, uuid_id: str) -> bool:
    """Best-effort durable point between a journal row insert and the file move;
    the move goes ahead either way (decision D10), with one path-free line.
    Returns whether the point was reached."""
    if reached_durable_point(database):
        return True
    operator_logger.warning(
        "journal entry %s for track %s: the file is about to move although it could not be "
        "confirmed just now that database.db holds every saved change (the entry itself is "
        "already on disk)",
        entry_id, uuid_id,
    )
    return False


def settle_old_master(
    library: Library, entry_id: int, uuid_id: str, source: Path, dest: Path, root: Path,
    pending_old_masters: "PendingOldMasters", *, wait: bool = True,
) -> None:
    """After the commit that points the track at ``dest``: delete the old master
    and the journal row once the commit is durable. Otherwise both stay, the old
    file is remembered, and a later edit, conversion or idle pass settles it.
    ``wait=False`` (the first point already failed) asks once without waiting."""
    if reached_durable_point(library.unbound_database, wait=wait):
        # Never delete the new master through another spelling of its path.
        if not is_current_master(str(source), str(dest)):
            source.unlink(missing_ok=True)
            prune_empty_dirs(source.parent, root)
        library.delete_journal_entry(entry_id)
        return
    try:  # best effort: the operation committed and answers success either way
        row = next((e for e in library.list_journal_entries() if e["id"] == entry_id), None)
        if row is not None:
            pending_old_masters.remember(row, source)
    except Exception as e:
        logger.warning("could not remember the old file of %s: %s", uuid_id, type(e).__name__)
    operator_logger.warning(
        "journal entry %s for track %s: the old file waits for a database flush",
        entry_id, uuid_id,
    )
