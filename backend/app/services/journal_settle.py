"""Startup recovery settles every edit-journal row (sign-off OPEN-6.5-05, Part 2).

For one row: when the track's own file is in place, every other regular file the
row names is settled by the existing ownership proofs (rule a) or else by the
content rule (rule b: the same audio, deleted; rule c: a file ffprobe refuses
while the track's file hashed, deleted; other audio becomes a track of the row's
owner). When the track's file is missing, a copy (the staged copy, else the row's
other path) is adopted and the track describes it. With no copy the row just goes.

A row is planned with reads only, then acted on in a fixed order: every reading
and verdict; leftovers already in the library become tracks (claimed from then on,
so a rerun never deletes them); the staged copy is placed (adopted, or under the
row's "(recovered <id>)" name); one durable point; deletions (the staged copy
last); the identity mark; the row delete. Anything that raises keeps the row
(K1/K2) with nothing deleted. A staged copy found under the row's recovered name
while nothing is at the staged name is the copy an earlier run placed: it counts
as present, so a rerun never reads recovery's own move as the operation's.
Runtime recovery (``journal_recovery.reconcile_one``) does not come here.
``reconcile_journal`` is the start-up pass over every row.
"""

import logging
import os
from pathlib import Path
from typing import Callable, Optional

from app.core.operator_log import operator_logger
from app.database import ANY_OWNER
from app.database.database import Database, TrackPathTaken
from app.services import recovery_audio
from app.services.organizer import (
    Organizer,
    OrganizerContext,
    flush_move,
    move_back,
    move_file,
    prune_empty_dirs,
)
from app.services.path_sanitize import PathEscapesRoot, assert_name_within
from app.services.recovery_audio import (
    LEAVE,
    MAKE_TRACK,
    PROBE_OK,
    PROBE_REFUSED,
    REDUNDANT,
    UNREADABLE,
    AudioReading,
    leftover_verdict,
)
from app.services.journal_recovery import (
    SWAP_LOST_TEXT,
    SWAP_UNPROVEN_TEXT,
    TRACK_CHANGED_TEXT,
    JournalOwnershipUnproven,
    conversion_job_id_of,
    end_swap_job,
    is_current_master,
    is_regular_file,
    job_settled_lost,
    mark_identity_stale,
    reached_durable_point,
    replay_staged_copy,
    row_root,
    same_bitrate,
)

# U06-B-06: the job of a same-file conversion whose swap this row settles ends
# done (the converted file is the track's file now) or failed with a final text.
SWAP_DONE = "done"


logger = logging.getLogger(__name__)


class JournalRowKept(Exception):
    """Startup keeps the row (K1/K2); the message is a fixed, path-free reason."""


def reconcile_journal(
    database: Database, music_library_dir: Path, identity_signal=None,
    *, read_audio=None, cover_art=None,
) -> None:
    """Idempotent startup pass that finishes or reverts every outstanding
    ``edit_journal`` row, closing the move↔commit window. Safe to run on every
    boot; a clean shutdown leaves no rows. A recovered master write marks the track's
    audio identity stale and then wakes ``identity_signal`` (anything with notify()).
    Every row is settled (``journal_settle``); ``read_audio`` reads a file
    (default ``recovery_audio.read_audio``), ``cover_art`` (a CoverArtManager or
    None) serves a leftover that becomes a track."""
    entries = database.list_journal_entries(owner_id=ANY_OWNER)
    # A row may itself be only in the page cache; flush once before any file moves.
    if entries and not reached_durable_point(database):
        operator_logger.warning(
            "edit journal recovery goes ahead before a database flush (%d entries)",
            len(entries),
        )
    for entry in entries:
        try:
            settle_journal_row(
                database, entry,
                row_root(database, entry, music_library_dir, check=assert_name_within),
                identity_signal, read_audio or recovery_audio.read_audio, cover_art,
            )
        except Exception as e:  # never let one bad row block startup
            reason = (
                str(e) if isinstance(e, (JournalOwnershipUnproven, JournalRowKept))
                else type(e).__name__
            )
            operator_logger.warning(
                "journal entry %s for track %s kept: %s", entry["id"], entry["uuid_id"], reason
            )


def settle_journal_row(
    database, entry: dict, root: Path, identity_signal, read_audio: Callable,
    cover_art=None,
) -> None:
    """Settle one row at startup. ``root`` is the row owner's library root, every
    path of the row already checked to lie inside it (or inside the staging dir)."""
    row = _Row(database, entry, root, read_audio)
    if row.relocating:
        row.plan_relocating()
    else:
        row.plan_in_place()
        if row.convert and conversion_job_id_of(entry) is not None:
            row.plan_swap_job()
        row.refuse_redo_over_another_track()
    row.act(identity_signal, cover_art)


class _Row:
    def __init__(self, database, entry: dict, root: Path, read_audio: Callable):
        self.db = database
        self.entry = entry
        self.root = root
        self._read_audio = read_audio
        self.owner = entry["owner_id"]
        self.uuid = entry["uuid_id"]
        self.convert = entry["intent"] == "convert"
        self.O = Path(entry["old_path"]) if entry["old_path"] else None
        new = entry["new_path"]
        self.relocating = entry["intent"] == "relocate" or (
            self.convert and bool(new) and new != entry["old_path"]
        )
        self.N = Path(new) if self.relocating and new else None
        self.T = Path(entry["temp_path"]) if entry["temp_path"] else None
        self.D = database.get_track_file_path(self.uuid, owner_id=self.owner)
        self.in_place = self.D is not None and _stat_regular(self.D)
        self.final: Optional[str] = self.D  # the track's file once settled
        # Anything at the staged name (a dangling link too) means no move consumed it.
        self.t_lex = self.T is not None and os.path.lexists(self.T)
        self.t_reg = is_regular_file(self.T)
        self.R = self._recovered_name()
        # The staged copy: at its staged name, or where an earlier run placed it.
        self.S: Optional[Path] = None
        if self.t_reg:
            self.S = self.T
        elif self.R is not None and not self.t_lex and self.usable(self.R, self.D):
            self.S = self.R
        # Anything at this row's recovered name was put there by an earlier run, which
        # consumed the staged copy: that is no proof the operation's move happened.
        placed_before = self.R is not None and (
            os.path.lexists(self.R) or self.D == str(self.R)
        )
        self.t_present = self.t_lex or placed_before
        # The plan.
        self.redo_in_place = False
        self.adopt_src: Optional[Path] = None  # the file the track adopts
        self.adopt_dest: Optional[Path] = None  # where it ends up (a staged copy moves)
        self.refresh_from_old = False  # D9: columns read again from the old path
        self.compare: list[Path] = []  # content rule against the track's file
        self.orphans: list[Path] = []  # track gone: library files that become tracks
        self.staged_orphan = False  # track gone, the staged copy is the only copy
        self.deletes: list[tuple[Path, str]] = []  # library files, rule a/b/c
        self.delete_temp = False
        self.temp_unreadable = False  # the staged copy goes by rule c
        self.prune: list[Path] = []  # folders of files already gone (today's finish)
        self.old_by_adoption: Optional[Path] = None  # P-old that rests on our own move
        self.mark = False
        self.phrases: list[str] = []
        self._readings: dict[Path, AudioReading] = {}
        self._moved: list[tuple[Path, Path]] = []  # (placed at, came from), not yet referenced
        self._durable = False  # a durable point since the last database change
        self._left = 0  # D2 lines, written once the row is settled
        self.swap_outcome: Optional[str] = None  # U06-B-06: SWAP_DONE or a final job text

    # --- predicates ---------------------------------------------------------------------------------

    def claimed(self, path: Path) -> bool:
        return self.db.track_path_in_use(str(path), owner_id=ANY_OWNER, exclude_uuid=self.uuid)

    def usable(self, path: Optional[Path], current: Optional[str]) -> bool:
        return (
            path is not None and is_regular_file(path) and not self.claimed(path)
            and not is_current_master(str(path), current)
        )

    def read(self, path: Path) -> AudioReading:
        if path not in self._readings:
            self._readings[path] = self._read_audio(path)
        return self._readings[path]

    def _recovered_name(self) -> Optional[Path]:
        """This row's one "(recovered <id>)" name (D7): next to N, or next to O for
        an in-place row, with the staged copy's suffix."""
        base = self.N if self.relocating else self.O
        if base is None or self.T is None:
            return None
        return base.with_name(f"{base.stem} (recovered {self.entry['id']}){self.T.suffix}")

    def _free_recovered(self) -> Path:
        if self.R is None or os.path.lexists(self.R) or self.claimed(self.R):
            raise JournalRowKept("the recovered name is taken")
        return self.R

    # --- phase 1: plan (reads only) -----------------------------------------------------------------

    def plan_in_place(self) -> None:
        O, D = self.O, self.D
        if D is None:
            self._plan_gone([O])
            return
        self.mark = True
        old_ok = O is not None and (not os.path.lexists(O) or is_regular_file(O))
        if D == str(O) and old_ok:
            if self.S == self.T and self.S is not None:
                self.redo_in_place = True
                self.phrases.append("the staged copy was put in place")
            elif self.S is not None:
                self.compare.append(self.S)
            if self.convert and self.t_lex and not self.t_reg:
                self.refresh_from_old = True  # D9: the replace never happened
            return
        if self.in_place and D != str(O):
            if self.usable(O, D):
                self.compare.append(O)
            if self.S == self.T and self.S is not None:
                logger.warning(
                    "journal entry %s: track no longer at its recorded path; "
                    "discarding its staged temp", self.entry["id"],
                )
            self._staged_by_proof()
            return
        # The track's file is missing (or O is no file to replay onto): adopt a copy.
        if self.S is not None:
            self._adopt_staged([D, O])
        elif self.usable(O, D):
            self._adopt_file(O)
        else:
            self.phrases.append("the track's file is missing")
            return
        if self.usable(O, self.final) and str(O) != self.final:
            self.compare.append(O)

    def refuse_redo_over_another_track(self) -> None:
        """Reads only. The staged copy of an in-place row (an edit's, or a
        conversion's whose name carries no job) is never put over a path another
        track names: the row and the copy stay."""
        if self.redo_in_place and self.claimed(self.O):
            raise JournalRowKept("another track's file is at the path")

    def plan_swap_job(self) -> None:
        """U06-B-06, reads only (plus the job text on a refusal): how the job of a
        same-file conversion whose own swap may have failed ends with this row."""
        O, D = self.O, self.D
        if O is not None and D == str(O) and self.claimed(O):
            # Another track's file is at the path: never written over; the row stays.
            end_swap_job(self.db, self.entry, SWAP_UNPROVEN_TEXT)
            raise JournalRowKept("another track's file is at the path")
        if D is None:
            self.swap_outcome = TRACK_CHANGED_TEXT
        elif self.in_place and D != str(O):
            # Moved on, unless a stop after this row adopted the converted copy:
            # then the track's file is that copy (at the recovered name, or reading
            # as the conversion committed it).
            adopted = not self.t_present and (
                D == str(self.R) or self._committed_columns(Path(D)) is True
            )
            self.swap_outcome = SWAP_DONE if adopted else TRACK_CHANGED_TEXT
        elif self.redo_in_place:
            self.swap_outcome = SWAP_DONE
        elif self.refresh_from_old:
            self.swap_outcome = SWAP_LOST_TEXT  # D9: the replace never happened
        elif self.adopt_src is not None:
            self.swap_outcome = SWAP_DONE if self.adopt_src in (self.T, self.R) else SWAP_LOST_TEXT
        elif (
            D == str(O) and self.S is None and not self.t_present and is_regular_file(O)
        ):
            # The staged file is gone: prove the swap before the job may say done.
            matches = None if job_settled_lost(self.db, self.entry) else self._committed_columns(O)
            if matches is True:
                self.swap_outcome = SWAP_DONE
            elif matches is None and not job_settled_lost(self.db, self.entry):
                # ffprobe refuses the file for good: D9, the columns become unknown.
                self.refresh_from_old = True
                self.swap_outcome = SWAP_UNPROVEN_TEXT
            else:
                self.refresh_from_old = True
                self.swap_outcome = SWAP_LOST_TEXT
        else:
            self.swap_outcome = SWAP_UNPROVEN_TEXT

    def _committed_columns(self, path: Path) -> Optional[bool]:
        """Whether the file reads as the conversion committed it (codec, rate,
        channels, bitrate); None when ffprobe refuses it. A reading that could not
        be made (no tool, a timeout) keeps the row: nothing is proved."""
        reading = self.read(path)
        if reading.probe == PROBE_REFUSED:
            return None
        if reading.probe != PROBE_OK:
            raise JournalRowKept("the track's file could not be read")
        track = self.db.get_track_by_uuid(self.uuid, owner_id=self.owner)
        if track is None:
            raise JournalRowKept("the track is gone")
        meta, committed = reading.metadata, track.metadata
        return (
            meta.codec == committed.codec
            and meta.sample_rate_hz == committed.sample_rate_hz
            and meta.channels == committed.channels
            and same_bitrate(meta.bitrate_kbps, committed.bitrate_kbps)
        )

    def plan_relocating(self) -> None:
        O, N, D = self.O, self.N, self.D
        p_new_own = (
            D != str(N) and self.T is not None and not self.t_present and self.usable(N, D)
        )
        if D is None:  # M7: nothing to compare with
            self._plan_gone([O, N])
            return
        if self.in_place:
            if D == str(N):
                if self.usable(O, D):
                    if not self.t_present and self._regular_at_new(adopted_staged=False):
                        self._old_by_proof(O)
                    else:
                        self.compare.append(O)  # e.g. a symlink at N proves nothing
                elif O is not None and not os.path.lexists(O) and not self.t_present:
                    self.prune.append(O.parent)  # the old file is gone already
                if self.S is not None:
                    self.compare.append(self.S)  # D8: it may be the only copy
                self.mark = True
            else:
                self._settle_new(N, D, p_new_own)
                if D != str(O) and self.usable(O, D):
                    self.compare.append(O)
                self._staged_by_proof()
            return
        # The track's file is missing: adopt a copy (staged copy, then N, then O).
        adopted_staged = False
        if self.S is not None:
            self._adopt_staged([D, N, O])
            adopted_staged = True
        elif self.usable(N, D):
            self._adopt_file(N)
        elif self.usable(O, D):
            self._adopt_file(O)
        else:
            self.phrases.append("the track's file is missing")
            return
        final = self.final
        if N is not None and str(N) != final:
            self._settle_new(N, final, p_new_own)
        if O is not None and str(O) != final and self.usable(O, final):
            # D5: the staged copy now at N proves the row's own move finished; not
            # when the track had moved on (D elsewhere).
            if (final == str(N) and self._regular_at_new(adopted_staged)
                    and (D == str(N) or (adopted_staged and D == str(O)))):
                self._old_by_proof(O)
                self.old_by_adoption = O  # rests on the copy landing at N (D5)
            else:
                self.compare.append(O)

    def _plan_gone(self, paths: list) -> None:
        """The track is gone (M7): nothing to compare with. Library files become
        tracks when readable; a staged copy goes only when another copy is there,
        else it is the only copy and is placed under the recovered name (#6)."""
        self.orphans = [p for p in paths if self.usable(p, None)]
        if self.S == self.R and self.S is not None:
            self.orphans.append(self.R)
        elif self.S is not None:
            if self.orphans:
                self.delete_temp = True
            else:
                self.staged_orphan = True
        self.phrases.append("the track is gone")

    def _staged_by_proof(self) -> None:
        """The track's own file is in place: the operation's staged copy goes (rule
        a); a copy an earlier run placed goes to the content rule."""
        if self.S is None:
            return
        if self.S == self.T:
            self.delete_temp = True
        else:
            self.compare.append(self.S)

    def _regular_at_new(self, adopted_staged: bool) -> bool:
        """P-old needs a regular file at N (lstat; a symlink there proves nothing).
        A staged copy this recovery places at N is one (checked by lstat at T)."""
        return (adopted_staged and self.final == str(self.N)) or is_regular_file(self.N)

    def _settle_new(self, N: Path, current: Optional[str], p_new_own: bool) -> None:
        """N, not the track's file: the operation's own output goes (P-new),
        anything else usable goes to the content rule."""
        if not self.usable(N, current):
            return
        if p_new_own:
            self._new_by_proof(N)
        else:
            self.compare.append(N)

    def _old_by_proof(self, path: Path) -> None:
        self.deletes.append((path, "a"))
        self.phrases.append("the old file was removed")

    def _new_by_proof(self, path: Path) -> None:
        self.deletes.append((path, "a"))
        self.phrases.append("the unfinished copy was removed")

    def _adopt_file(self, path: Path) -> None:
        self.adopt_src = self.adopt_dest = path
        self.final = str(path)
        self.phrases.append("the file at the other location was adopted")

    def _adopt_staged(self, targets: list) -> None:
        if self.S == self.T:
            self.adopt_src = self.T
            self.adopt_dest = self._placement(targets)
        else:  # placed by an earlier run: point at it
            self.adopt_src = self.adopt_dest = self.S
        self.final = str(self.adopt_dest)
        self.phrases.append("the staged copy was put in place")

    def _placement(self, targets: list) -> Path:
        """The first free, unclaimed target with the staged copy's suffix (the
        track's own path only inside the owner's root), else (D7) the row's
        recovered name."""
        suffix = self.T.suffix.lower()
        for target in targets:
            if target is None:
                continue
            target = Path(target)
            if str(target) == self.D and not self._inside_root(target):
                continue
            if (target.suffix.lower() == suffix and not os.path.lexists(target)
                    and not self.claimed(target)):
                return target
        return self._free_recovered()

    def _reference_not_ours(self) -> bool:
        """The track's file is a symlink to another track's file or to a file outside
        the owner's root: its audio proves no copy redundant (review #10)."""
        if self.adopt_src is not None or self.final is None or not os.path.islink(self.final):
            return False
        link = Path(self.final)
        literal = link.parent / os.readlink(link)  # as a stored path would spell it
        resolved = Path(os.path.realpath(link))
        return (
            self.claimed(literal) or self.claimed(resolved) or not self._inside_root(resolved)
        )

    def _inside_root(self, path: Path) -> bool:
        try:
            assert_name_within(path, self.root)
            return True
        except PathEscapesRoot:
            return False

    # --- phase 2: act -------------------------------------------------------------------------------

    def act(self, identity_signal, cover_art) -> None:
        # 1. Every reading and verdict first: a failing read leaves everything as it
        # was (nothing on disk or in the database changes in this step).
        self.in_library: list[tuple[Path, AudioReading]] = []  # become tracks where they lie
        self.staged_track: Optional[AudioReading] = None  # the staged copy becomes a track
        self.place_staged = False  # the staged copy moves to the recovered name
        if self.adopt_src is not None:
            self.read(self.adopt_src)
        if self.refresh_from_old:
            self.read(self.O)
        reference = None
        if self.compare or self.old_by_adoption is not None:
            reference = self.read(self.adopt_src if self.adopt_src is not None else Path(self.final))
        for path in self.compare:
            self._apply_verdict(path, reference)
        for path in self.orphans:
            reading = self.read(path)
            if reading.probe == PROBE_OK:
                self.in_library.append((path, reading))
            else:
                self._left += 1
        if self.staged_orphan:
            reading = self.read(self.T)
            self.place_staged = True
            self.staged_track = reading if reading.probe == PROBE_OK else None
            self._left += reading.probe != PROBE_OK
        if self._left and self.adopt_src == self.T and self.adopt_dest != self.R:
            self._retarget_to_recovered(reference)
        if self.place_staged:
            self._free_recovered()

        try:
            self._change(identity_signal, cover_art)
        except BaseException:
            self._put_staged_copy_back()
            raise
        for _ in range(self._left):
            operator_logger.warning(
                "journal entry %s for track %s: a file nothing could read was left in place",
                self.entry["id"], self.uuid,
            )
        operator_logger.info(
            "journal entry %s for track %s settled: %s", self.entry["id"], self.uuid,
            "; ".join(self.phrases) or "nothing was left to do",
        )

    def _apply_verdict(self, path: Path, reference: AudioReading) -> None:
        """The content rule for one file against the track's file (step 1: plans only)."""
        reading = self.read(path)
        verdict = leftover_verdict(reading, reference)
        if self._reference_not_ours():
            verdict = {REDUNDANT: MAKE_TRACK, UNREADABLE: LEAVE}.get(verdict, verdict)
        if verdict == REDUNDANT:
            self._delete(path, "b")
            self.phrases.append("a redundant copy was removed")
        elif verdict == UNREADABLE:
            self._delete(path, "c")
        elif path == self.T:  # MAKE_TRACK or LEAVE: never left in staging
            self.place_staged = True
            self.staged_track = reading if verdict == MAKE_TRACK else None
            self._left += verdict == LEAVE
        elif verdict == MAKE_TRACK:
            self.in_library.append((path, reading))
        else:
            self._left += 1

    def _retarget_to_recovered(self, reference: AudioReading) -> None:
        """A file is left in place (D2) and the staged copy would land at an ordinary
        path: a failure after the adoption would make the next start read that move
        as the operation's and remove the file by proof. Place the copy under the
        recovered name instead, which the next start recognises (review R-1). A P-old
        that rested on the copy landing at N loses its premise: content rule."""
        self.adopt_dest = self._free_recovered()
        self.final = str(self.adopt_dest)
        O = self.old_by_adoption
        if O is not None:
            self.deletes.remove((O, "a"))
            self.phrases.remove("the old file was removed")
            self.old_by_adoption = None
            self._apply_verdict(O, reference)

    def _change(self, identity_signal, cover_art) -> None:
        """Steps 2-7. A staged copy moved here and not yet referenced by a commit is
        put back if anything raises."""
        organizer = self._organizer(cover_art)
        # U06-B-06: a job that ends failed is settled before anything changes, so
        # a later failure leaves nothing a rerun could mistake for a done swap.
        if self.swap_outcome not in (None, SWAP_DONE):
            end_swap_job(self.db, self.entry, self.swap_outcome)
        # 2. Leftovers already in the library become tracks first, where they lie.
        for path, reading in self.in_library:
            self._register(organizer, path, reading)

        # 3. The staged copy is placed: the redo (after a durable point: it replaces
        # the old bytes), the adoption, or the recovered name.
        if self.redo_in_place:
            self._durable_point()
            self.O.parent.mkdir(parents=True, exist_ok=True)  # the folder may be gone too
            replay_staged_copy(self.T, self.O)
        if self.adopt_src is not None:
            if self.adopt_src == self.T:
                self._move(self.T, self.adopt_dest)
            self._refresh(self.adopt_src, str(self.adopt_dest))
            self._moved.clear()  # the track names it now: never moved back
        if self.refresh_from_old:
            self._refresh(self.O, None)
        if self.place_staged:
            self._move(self.T, self.R)
            if self.staged_track is not None:
                self._register(organizer, self.R, self.staged_track)
            self._moved.clear()

        # 4. The durable point (D11): database changes above, deletions below.
        temp_link = self.T is not None and os.path.islink(self.T)
        if (self.deletes or self.delete_temp or temp_link) and not self._durable:
            self._durable_point()

        # 5. Deletions, each re-checked; the staged copy last.
        for path, rule in self.deletes:
            if self.usable(path, self.final):
                path.unlink(missing_ok=True)
                prune_empty_dirs(path.parent, self.root)
                if rule == "c":
                    self._unreadable_removed()
        for folder in self.prune:
            prune_empty_dirs(folder, self.root)
        if self.delete_temp and is_regular_file(self.T):
            self.T.unlink(missing_ok=True)
            if self.temp_unreadable:
                self._unreadable_removed()
        elif temp_link:
            self.T.unlink(missing_ok=True)

        # 6-7. Identity mark, then the row.
        if self.mark:
            mark_identity_stale(self.db, self.entry, identity_signal)
        elif self.adopt_src is not None and identity_signal is not None:
            identity_signal.notify()  # the refresh marked it stale ('settle')
        if self.swap_outcome == SWAP_DONE:
            # The bytes changed under the revision the conversion committed:
            # clients must see the change. Then the job is done.
            self.db.bump_track_revision(self.uuid, owner_id=self.owner)
            end_swap_job(self.db, self.entry, None)
        self.db.delete_journal_entry(self.entry["id"], owner_id=self.owner)

    def _register(self, organizer: Organizer, path: Path, reading: AudioReading) -> None:
        new_uuid = organizer.register_in_place(path, reading.metadata, identity=None)
        self._durable = False
        if new_uuid is None:
            raise JournalRowKept("a leftover file could not become a track")
        self.phrases.append(f"a leftover file became track {new_uuid}")

    def _durable_point(self) -> None:
        if not reached_durable_point(self.db):
            raise JournalRowKept("the database flush failed")
        self._durable = True

    def _put_staged_copy_back(self) -> None:
        """Best effort: a kept row's staged copy is its evidence; put it back."""
        for placed, came_from in reversed(self._moved):
            try:
                if not move_back(placed, came_from):
                    raise OSError("move back refused")
            except Exception as e:
                logger.warning(
                    "journal entry %s: could not put a staged copy back: %s",
                    self.entry["id"], type(e).__name__,
                )

    def _unreadable_removed(self) -> None:
        operator_logger.warning(
            "journal entry %s for track %s: an unreadable leftover file was removed",
            self.entry["id"], self.uuid,
        )

    def _delete(self, path: Path, rule: str) -> None:
        if path == self.T:
            self.delete_temp = True
            self.temp_unreadable = rule == "c"
        else:
            self.deletes.append((path, rule))

    def _move(self, source: Path, dest: Path) -> None:
        if not move_file(file_path=source, destination_path=dest):
            raise JournalRowKept("the staged copy could not be placed")
        self._moved.append((dest, source))
        flush_move(dest, source, self.root)

    def _refresh(self, columns_from: Path, file_path: Optional[str]) -> None:
        """Point the track at ``file_path`` (None: unchanged) with the technical
        columns of the file read; unreadable: an edit keeps its columns, a
        conversion's become unknown (D9). Marks the identity stale ('settle')."""
        reading = self.read(columns_from)
        if reading.probe == PROBE_OK:
            meta = reading.metadata
            columns = (meta.codec, meta.bitrate_kbps, meta.sample_rate_hz, meta.channels, meta.duration)
        elif self.convert:
            columns = (None, None, None, None, None)
        else:
            meta = self.db.get_track_by_uuid(self.uuid, owner_id=self.owner).metadata
            columns = (meta.codec, meta.bitrate_kbps, meta.sample_rate_hz, meta.channels, None)
        codec, bitrate, rate, channels, duration = columns
        try:
            self.db.refresh_track_audio_properties(
                self.uuid, codec=codec, bitrate_kbps=bitrate, sample_rate_hz=rate,
                channels=channels, duration=duration, file_path=file_path, owner_id=self.owner,
            )
        except TrackPathTaken as e:
            # The database's own refusal of a path ``claimed`` found free.
            raise JournalRowKept("another track's file is at the path") from e
        self._durable = False

    def _organizer(self, cover_art) -> Organizer:
        return Organizer(OrganizerContext(
            music_library_dir=self.root,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=lambda track: self.db.add_track(track, owner_id=self.owner),
            add_cover_art=cover_art.add_album_art_with_status if cover_art is not None else None,
            release_cover_art=cover_art.release_if_unreferenced if cover_art is not None else None,
            path_in_use=lambda path: self.db.track_path_in_use(str(path), owner_id=ANY_OWNER),
        ))


def _stat_regular(path: str) -> bool:
    """Whether ``path`` (following a symlink) is a regular file."""
    try:
        return Path(path).is_file()
    except OSError:
        return False
