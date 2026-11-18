import errno
import hashlib
import logging
import os
import re
import shutil
import sqlite3
import stat
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Optional

from app.core.durable_fs import fsync_dir, fsync_file
from app.core.internal_dirs import is_internal_path
from app.database.database import CoverArtGone, _fold_path, effective_artist
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.audio_identity import ExactAudioHash, exact_match
from app.services.cover_art_manager import CoverArtAddResult
from app.services.import_outcome import ImportOutcome, file_signature
from app.services.keyed_locks import KeyedLocks
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.metadata import (
    ProbeUnavailable, extract_cover_art_bytes, get_track_metadata, probe_unavailable_raises, probes_killed_by,
)
from app.services.path_sanitize import (
    _MAX_COMPONENT_LEN,
    UnsafePathComponent,
    assert_within,
    cut_to_bytes,
    sanitize_file_name,
    sanitize_path_component,
    utf8_len,
)

logger = logging.getLogger(__name__)

# Caps the rounds of "choose a name, move refused because the name was just
# taken". Each refused round means a concurrent import placed a file in that
# folder; one owner's folder is fed by at most 16 concurrent imports (two import
# watchers, IMPORT_DIR and the user folders, with 8 workers each), so 16 rounds
# suffice in practice, and the cap ends it as MOVE_FAILED otherwise.
MAX_NAME_ATTEMPTS = 16


def numbered_name(stem: str, n: int, ext: str) -> str:
    """``"<stem> (n)<ext>"``, the stem cut so the whole name fits the
    component byte cap."""
    suffix = f" ({n}){ext}"
    return cut_to_bytes(stem, _MAX_COMPONENT_LEN - utf8_len(suffix)).rstrip(" .") + suffix


def _stored_hash(row: dict | None) -> ExactAudioHash | None:
    """The exact hash a track row stores, when it is current."""
    if row is None or row.get("exact_state") != "current" or not row.get("exact_digest"):
        return None
    return ExactAudioHash(row["exact_kind"], row["exact_digest"], row["sample_rate_hz"],
                          row["channels"], row["bits_per_sample"])


def same_bytes(a: Path, b: Path) -> bool:
    """True when both files hold the same bytes (size first, then SHA-256);
    False when either cannot be read."""
    try:
        if os.path.getsize(a) != os.path.getsize(b):
            return False
        return _sha256(a) == _sha256(b)
    except OSError:
        return False


def _same_file(a: Path, b: Path) -> bool:
    """True when ``a`` and ``b`` name one existing file; False when either cannot be examined."""
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while block := f.read(COPY_BLOCK_BYTES):
            digest.update(block)
    return digest.hexdigest()

# The text tags an import stores, NFC-normalised once so an NFD spelling (as
# macOS tools often write) lands in the same row and folder as the NFC one.
NFC_TEXT_FIELDS = ("title", "artist", "album", "album_artist", "genre", "date")


def nfc_text(value: Any) -> Any:
    """``value`` NFC-normalised when it is a string; anything else unchanged."""
    return unicodedata.normalize("NFC", value) if isinstance(value, str) else value


def nfc_track_metadata(meta: TrackMetaData) -> TrackMetaData:
    """A copy of ``meta`` with its text tags NFC-normalised (codec and numbers untouched)."""
    return meta.model_copy(update={f: nfc_text(getattr(meta, f)) for f in NFC_TEXT_FIELDS})

# Per-directory mutual exclusion for move_file/prune_empty_dirs: without it,
# one track's prune of a now-empty shared album directory can race another
# track's move into that same directory (removing it out from under a
# concurrent mkdir+replace), and two concurrent moves to the same destination
# can race the exists()-then-replace() check-then-act into a silent clobber.
# Mirrors TrackLocks' "never delete the entry" KeyedLocks pattern.
_directory_locks = KeyedLocks[Path]()


def directory_lock_key(path) -> Path:
    """The ``_directory_locks`` key of a folder: its resolved path in folded
    form, so spellings a case-insensitive disk treats as one folder
    ("ABBA/Gold", "Abba/Gold") share one lock."""
    return Path(_fold_path(str(Path(path).resolve())))

# TODO: implement copy_file
# TODO: do not assume that move destination is on the same filesystem as the source aka atomic rename for moving

# For now, organization is as follows:
# If a song has an artist it will go somewhere in music_library_dir / artist
# Only if a song has an artist and an album, it will go somewhere in music_library_dir / artists / album
# All otherwise, just go in music_library_dir


@dataclass(frozen=True)
class OrganizerContext:
    music_library_dir: Path
    should_organize_files: bool
    should_copy_files: bool
    add_to_database: Callable[[Track], bool]
    add_cover_art: Callable[[bytes], CoverArtAddResult] | None = None
    release_cover_art: Callable[[int], bool] | None = None
    # Called once after a successful import with the track and the signature
    # (size, mtime_ns) the file was read at (settle check, m-L-08).
    on_imported: Callable[[Track, tuple[int, int] | None], None] | None = None
    # Computes the exact audio identity of a file (path, codec hint); run on the
    # source just before the move and carried into add_track. None = not computed.
    compute_identity: Callable[[Path, str | None], Any] | None = None
    # True while the app is shutting down: the organizer then skips the hash and
    # leaves the identity pending for the worker.
    should_stop: Callable[[], bool] | None = None
    # The metadata probe runs registered here, so closing it at shutdown ends it.
    probe_registry: FfmpegProcessRegistry | None = None
    # The tracks whose master file sits in a folder, with their stored exact
    # hash (Database.track_identities_in_folder rows). None: only the disk is
    # consulted when a library name is taken, and no stored hash is known.
    folder_tracks: Callable[[Path], list[dict]] | None = None

    def __post_init__(self):
        if not self.should_organize_files and self.should_copy_files:
            raise ValueError(
                "If files are not being organized (should_organize_files is False), "
                "then files remain in their existing location. Therefore, should_copy_files must be False."
            )


class Organizer:
    def __init__(self, ctx: OrganizerContext):
        self.ctx = ctx

    def organize_file(self, file_path: Path) -> bool:
        return self.organize(file_path) is ImportOutcome.IMPORTED

    def _compute_identity(self, file_path: Path, codec: str | None) -> Any:
        """The exact layer of the source file, or None (left pending for the
        worker) when not configured, stopping, or the compute fails. Never
        changes the import outcome."""
        ctx = self.ctx
        if ctx.compute_identity is None or (ctx.should_stop is not None and ctx.should_stop()):
            return None
        try:
            return ctx.compute_identity(file_path, codec)
        except Exception as e:
            logger.warning("audio identity compute failed at ingest: %s", type(e).__name__)
            return None

    def organize(self, file_path: Path) -> ImportOutcome:
        if not self.ctx.should_organize_files:
            raise NotImplementedError(
                "Organizer does not support in place organization yet"
            )

        if self.ctx.should_copy_files:
            raise NotImplementedError("Organizer does not support copying yet")

        # Case: Organizing and Moving (not copying)
        before = file_signature(file_path)
        try:
            with probe_unavailable_raises(), probes_killed_by(self.ctx.probe_registry):
                trackmetadata = get_track_metadata(file_path=file_path)
        except ProbeUnavailable:
            print(f"ffprobe unavailable for {file_path}")
            return ImportOutcome.TOOL_UNAVAILABLE

        if trackmetadata is None or trackmetadata.is_empty():
            print(f"{file_path} does not result in a TrackMetaData")
            return ImportOutcome.FAILS_CHECK
        # Before the destination is computed, so the folders and the database agree.
        trackmetadata = nfc_track_metadata(trackmetadata)

        try:
            safe_name = sanitize_file_name(file_path.name)
        except UnsafePathComponent:
            print(f"{file_path} has an unusable file name")
            return ImportOutcome.FAILS_CHECK

        destination_path = sanitized_destination_path(
            safe_name, trackmetadata, self.ctx.music_library_dir
        )

        # Explicit raise (not assert) so it holds under ``python -O``; checked
        # before anything touches the disk.
        assert_within(destination_path, self.ctx.music_library_dir)

        # Internal dirs (.staging, .uploads, ...) are never a library home.
        if is_internal_path(destination_path, self.ctx.music_library_dir):
            print(f"Destination {destination_path} is inside an internal directory.")
            return ImportOutcome.FAILS_CHECK

        cover_art_result: CoverArtAddResult | None = None
        art_bytes: bytes | None = None

        # Extract and register cover art if present
        if trackmetadata.has_album_art and self.ctx.add_cover_art is not None:
            art_bytes = extract_cover_art_bytes(file_path)
            if art_bytes:
                try:
                    cover_art_result = self.ctx.add_cover_art(art_bytes)
                    trackmetadata = trackmetadata.model_copy(
                        update={"cover_art_id": cover_art_result.cover_art_id}
                    )
                except ValueError as e:
                    print(f"Failed to add cover art for {file_path}: {e}")

        # Changed since it was read: abandon without touching the file.
        if file_signature(file_path) != before:
            self._cleanup_cover_art(cover_art_result)
            return ImportOutcome.CHANGED

        identity = self._compute_identity(file_path, trackmetadata.codec)

        # A taken name holding the same audio refuses the import; a different
        # track gets a numbered name. move_file never replaces: a refusal on a
        # name that now exists means a concurrent import took it, so choose again.
        base_path = destination_path
        incoming = getattr(identity, "exact", None)
        for _ in range(MAX_NAME_ATTEMPTS):
            try:
                choice = self._choose_destination(base_path, file_path, incoming)
            except sqlite3.Error as e:
                logger.warning("import failed: the library's tracks could not be read: %s",
                               type(e).__name__)
                self._cleanup_cover_art(cover_art_result)
                return ImportOutcome.DATABASE_ERROR
            except Exception:
                self._cleanup_cover_art(cover_art_result)
                raise
            if choice is ImportOutcome.DUPLICATE:
                logger.info("import refused: the same audio is already in the library under this name")
                self._cleanup_cover_art(cover_art_result)
                return ImportOutcome.DUPLICATE
            destination_path = choice
            if move_file(file_path=file_path, destination_path=destination_path):
                break
            if not file_path.is_file() or not os.path.lexists(destination_path):
                self._cleanup_cover_art(cover_art_result)
                return ImportOutcome.MOVE_FAILED
        else:
            self._cleanup_cover_art(cover_art_result)
            return ImportOutcome.MOVE_FAILED

        track = Track(
            file_path=destination_path, metadata=trackmetadata, audio_identity=identity
        )

        try:
            was_added = self.ctx.add_to_database(track)
        except CoverArtGone:
            # The shared art was released between add_cover_art and the insert:
            # re-register it and retry exactly once.
            was_added = False
            if art_bytes and self.ctx.add_cover_art is not None:
                try:
                    cover_art_result = self.ctx.add_cover_art(art_bytes)
                    track.metadata = trackmetadata = trackmetadata.model_copy(
                        update={"cover_art_id": cover_art_result.cover_art_id}
                    )
                    was_added = self.ctx.add_to_database(track)
                except CoverArtGone:
                    pass
                except Exception as e:
                    print(f"Retry after vanished cover art failed for {destination_path}: {e}")
        if not was_added:
            print(f"Failed to add track to database after move: {destination_path}")
            rollback_move(destination_path=destination_path, original_path=file_path)
            self._cleanup_cover_art(cover_art_result)
            return ImportOutcome.DATABASE_ERROR

        if destination_path != base_path:
            logger.info("import placed under a numbered name: a different track already uses the name")
        if self.ctx.on_imported is not None:
            self.ctx.on_imported(track, before)
        return ImportOutcome.IMPORTED

    def _choose_destination(self, base: Path, source: Path, incoming: Any) -> Path | ImportOutcome:
        """``base`` when the name is free; DUPLICATE when it or any of its
        numbered names holds the same audio as ``source``; otherwise the next
        numbered name, one above the highest in use (the base counts as 1; gaps
        are not reused). The folder is listed and its tracks read once."""
        folder = base.parent
        try:
            names = os.listdir(folder)
        except OSError:
            names = []  # a missing folder holds nothing
        # Folded name -> every [existing path, its track row or None] under it:
        # each file on disk, a track row joining the file it names.
        taken: dict[str, list[list]] = {}
        for name in names:
            taken.setdefault(_fold_path(name), []).append([folder / name, None])
        rows = self.ctx.folder_tracks(folder) if self.ctx.folder_tracks is not None else []
        for row in rows:
            row_path = Path(row["file_path"])
            entries = taken.setdefault(_fold_path(row_path.name), [])
            on_disk = next((e for e in entries if e[1] is None and _same_file(e[0], row_path)), None)
            if on_disk is not None:
                on_disk[1] = row
            else:
                entries.append([row_path, row])
        base_key = _fold_path(base.name)
        if base_key not in taken:
            if not os.path.lexists(base):
                return base
            taken[base_key] = [[base, None]]

        stem, ext = os.path.splitext(base.name)
        numbered = re.compile(r"(.*) \((\d+)\)" + re.escape(_fold_path(ext)), re.DOTALL)
        family = list(taken[base_key])
        highest = 1
        for key, entries in taken.items():
            match = numbered.fullmatch(key)
            if match is None or key == base_key:
                continue
            n = int(match[2])
            if _fold_path(numbered_name(stem, n, ext)) == key:
                family.extend(entries)
                highest = max(highest, n)
        for existing, row in family:
            if self._same_audio(source, incoming, existing, row):
                return ImportOutcome.DUPLICATE
        return folder / numbered_name(stem, highest + 1, ext)

    def _same_audio(self, source: Path, incoming: Any, existing: Path, row: dict | None) -> bool:
        """Does ``existing`` hold the same audio as ``source`` (exact hash
        ``incoming``)? Its stored hash answers when current; otherwise it is
        decoded once. A hash missing on either side compares the bytes."""
        if isinstance(incoming, ExactAudioHash):
            theirs = _stored_hash(row) or self._decode_existing(existing)
            if isinstance(theirs, ExactAudioHash):
                return exact_match(incoming, theirs)
        return same_bytes(source, existing)

    def _decode_existing(self, path: Path) -> Any:
        """The exact hash of a library file without a stored one, or None."""
        if self.ctx.compute_identity is None or not path.is_file():
            return None
        try:
            with probe_unavailable_raises(), probes_killed_by(self.ctx.probe_registry):
                meta = get_track_metadata(file_path=path)
        except ProbeUnavailable:
            return None
        if meta is None:
            return None
        return getattr(self._compute_identity(path, meta.codec), "exact", None)

    def _cleanup_cover_art(self, cover_art_result: CoverArtAddResult | None) -> None:
        if cover_art_result is None or not cover_art_result.was_created:
            return
        if self.ctx.release_cover_art is None:
            return
        try:
            self.ctx.release_cover_art(cover_art_result.cover_art_id)
        except ValueError as e:
            print(f"Failed to remove cover art {cover_art_result.cover_art_id}: {e}")


def move_back(destination_path: Path, file_path: Path) -> bool:
    """Undo a ``move_file``: put the file at ``destination_path`` back at
    ``file_path``. False when it could not be moved back."""
    try:
        destination_path.replace(file_path)
        return True
    except OSError as e:
        logger.warning("could not move a file back: %s", e.strerror or type(e).__name__)
        return False


def flush_move(placed: Path, came_from: Path, root: Optional[Path] = None) -> None:
    """Force a rename to disk, best effort (see fsync_dir): the folder that now
    names the file and, when ``root`` is given, every folder above it up to and
    including ``root`` (move_file may have created them), then the folder the
    file came from."""
    folder = placed.parent
    fsync_dir(folder)
    if root is not None:
        while folder != root and root in folder.parents:
            folder = folder.parent
            fsync_dir(folder)
    fsync_dir(came_from.parent)


def move_file(file_path: Path, destination_path: Path) -> bool:
    if not file_path.is_file():
        return False
    parent = destination_path.parent

    # Held for the whole exists-check + mkdir + replace sequence so a
    # concurrent move_file to the same destination, or a concurrent
    # prune_empty_dirs on this same directory, can't interleave with it.
    with _directory_locks.lock(directory_lock_key(parent)):
        if parent.exists() and not parent.is_dir():
            logger.warning("could not move a file: the destination's parent is not a directory")
            return False
        # Currently only supporting atomic move, so if file exists (even a
        # dangling symbolic link), return false
        if os.path.lexists(destination_path):
            logger.warning("could not move a file: the destination already exists")
            return False
        try:
            parent.mkdir(parents=True, exist_ok=True)
            # Fails if moving to a different filesystem, since it is an atomic move
            file_path.replace(destination_path)
            return True
        except (PermissionError, FileExistsError, OSError) as e:
            logger.warning("could not move a file: %s", e.strerror or type(e).__name__)
            return False


class LinkUnknown(OSError):
    """The name could not be examined: neither proven ours nor proven not ours."""


def is_own_hard_link(a, b, *, strict: bool = False) -> bool:
    """True only when ``a`` and ``b`` are both regular files (never followed
    symbolic links) that are the same file: the proof a name is our own link.
    A name proven absent (missing, a parent that is not a directory, or too long for
    the filesystem to hold) is False in both modes.
    Any other OSError (a name that cannot be examined) is also False by default;
    with ``strict`` it is raised as ``LinkUnknown`` (chained from the original error),
    so the caller can tell "unknown" from "not ours"."""
    try:
        sa, sb = os.lstat(a), os.lstat(b)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError as e:
        if e.errno == errno.ENAMETOOLONG:  # a name the filesystem cannot hold cannot exist
            return False
        if strict:
            raise LinkUnknown(e.errno, e.strerror) from e
        return False
    return (
        stat.S_ISREG(sa.st_mode) and stat.S_ISREG(sb.st_mode)
        and sa.st_dev == sb.st_dev and sa.st_ino == sb.st_ino
    )


def final_is_own_link(row) -> bool:
    """Is a commit journal's final name its work file's own link? Raises
    ``LinkUnknown`` when the name cannot be examined."""
    return is_own_hard_link(row["work_path"], row["final_path"], strict=True)


class HardLinkError(OSError):
    """``os.link`` itself failed (not making the folders): the cause of "hard links
    are not supported here" is told apart from a folder that cannot be made."""


# ``os.link`` refusals that mean "this filesystem will not hard-link here".
FALLBACK_ERRNOS = (errno.EXDEV, errno.EPERM, errno.ENOTSUP, errno.EOPNOTSUPP, errno.EMLINK)
COPY_BLOCK_BYTES = 1024 * 1024


def link_no_replace(source: Path, destination: Path, *, in_use) -> bool:
    """Hard-link ``source`` to ``destination`` under the destination directory
    lock, never replacing anything. False when the destination exists, is a
    track's master (``in_use(destination)``), or its parent is unusable. On an
    OSError the folders this call made are removed again (one at a time under
    their own locks, deepest first, never one that is not empty) and the error
    propagates; a failure of ``os.link`` itself (including a filesystem that
    refuses hard links) is raised as ``HardLinkError``. Never moves or copies."""
    return _place(source, destination, in_use=in_use, fallback=False) is not None


def temp_name_for(destination: Path) -> Path:
    """The hidden name next to ``destination`` a copy is written under: derived
    from the final name, a fixed 43 bytes, so it fits wherever the final does."""
    digest = hashlib.sha256(destination.name.encode("utf-8", "surrogateescape")).hexdigest()
    return destination.parent / f".{digest[:32]}.osml-part"


def place_no_replace(source: Path, destination: Path, *, in_use, before_fallback=None,
                     allow_copy: bool = True, copy_floor_bytes=None, seam=None, before_temp=None):
    """Put ``source`` at ``destination`` without ever replacing anything:
    ``"linked"`` (hard link, or our own earlier link), ``"moved"``, ``"copied"``,
    or None when the name is taken, is a track's master, or its parent is
    unusable. Exactly ``link_no_replace``, except that a link refused with one of
    ``FALLBACK_ERRNOS`` falls back: ``"rename"`` calls ``before_fallback("rename")``
    then moves the source (same filesystem); ``"copy"`` (EXDEV; a plain EXDEV
    OSError when not ``allow_copy``) answers None for a taken name, refuses with
    ENOSPC when the copy would leave less than ``copy_floor_bytes`` free, calls
    ``before_temp()`` (the slow work that must not happen while a temp exists
    unrecorded), creates ``temp_name_for(destination)`` with O_EXCL (a file
    already there raises ``FileExistsError`` before the hook), calls
    ``before_fallback("copy")``, then copies through the temp and leaves the
    source alone. A fallback failure removes this call's temp and folders and
    propagates unchanged. ``seam(name)`` is a test hook."""
    return _place(source, destination, in_use=in_use, fallback=True,
                  before_fallback=before_fallback, allow_copy=allow_copy,
                  copy_floor_bytes=copy_floor_bytes, seam=seam, before_temp=before_temp)


def _place(source, destination, *, in_use, fallback, before_fallback=None,
           allow_copy=True, copy_floor_bytes=None, seam=None, before_temp=None):
    parent = destination.parent
    created = []  # the directories this call makes, deepest first
    with _directory_locks.lock(directory_lock_key(parent)):
        if parent.exists() and not parent.is_dir():
            return None
        if in_use(destination):
            return None
        ancestor = parent
        while not ancestor.exists():
            created.append(ancestor)
            ancestor = ancestor.parent
        try:
            parent.mkdir(parents=True, exist_ok=True)
            try:
                os.link(source, destination)
            except FileExistsError:
                # Our own earlier link (a crash before the journal moved) is not a collision.
                return "linked" if is_own_hard_link(source, destination) else None
            except OSError as e:
                if not fallback or e.errno not in FALLBACK_ERRNOS:
                    failure = HardLinkError(e.errno, e.strerror)
                    failure.__cause__ = e
                elif e.errno == errno.EXDEV and not allow_copy:
                    failure = OSError(errno.EXDEV, os.strerror(errno.EXDEV))
                else:
                    try:
                        return _fall_back(source, destination, e.errno, before_fallback,
                                          copy_floor_bytes, seam, before_temp)
                    except Exception as fallback_error:  # never BaseException: a kill keeps the temp
                        failure = fallback_error
            else:
                return "linked"
        except OSError as e:
            failure = e
    for directory in created:  # after the parent's lock: an ancestor may be in use
        with _directory_locks.lock(directory_lock_key(directory)):
            try:
                directory.rmdir()
            except OSError:
                break  # not empty or gone: stop, never rmtree
    raise failure


def _fall_back(source, destination, link_errno, before_fallback, copy_floor_bytes, seam,
               before_temp=None):
    if link_errno == errno.EXDEV:
        result = _copy_through_temp(source, destination, before_fallback, copy_floor_bytes, seam,
                                    before_temp)
    else:
        if before_fallback is not None:
            before_fallback("rename")
        result = None
        if _is_absent(destination):
            os.rename(source, destination)
            result = "moved"
    if result is not None:
        fsync_dir(destination.parent)
    return result


def _is_absent(path) -> bool:
    """True only when ``path`` is proven not to exist; other errors propagate."""
    try:
        os.lstat(path)
    except FileNotFoundError:
        return True
    return False


def _copy_through_temp(source, destination, before_fallback, copy_floor_bytes, seam,
                       before_temp=None):
    if not _is_absent(destination):
        return None  # a taken name is a collision, even on a nearly full disk
    if copy_floor_bytes is not None:
        free = shutil.disk_usage(destination.parent).free
        if free - os.stat(source).st_size < copy_floor_bytes:
            raise OSError(errno.ENOSPC, "copy would go below the free-space floor")
    if before_temp is not None:  # no temp exists yet: a failure here leaves only the folders
        before_temp()
    temp = temp_name_for(destination)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)  # never someone else's file
    try:
        if before_fallback is not None:  # only now is the temp provably this call's
            before_fallback("copy")
        with open(fd, "wb") as out, open(source, "rb") as src:
            first = True
            while block := src.read(COPY_BLOCK_BYTES):
                out.write(block)
                if first and seam is not None:
                    seam("mid_copy")
                first = False
            out.flush()
        fsync_file(temp)
        if seam is not None:
            seam("after_copy")
        try:
            os.link(temp, destination)
            linked = True
        except FileExistsError:
            _remove_temp(temp)
            return None
        except OSError as e:
            if e.errno not in FALLBACK_ERRNOS:
                raise
            if not _is_absent(destination):
                _remove_temp(temp)
                return None
            os.rename(temp, destination)  # from here the temp name is not ours any more
            linked = False
    except Exception:
        _remove_temp(temp)
        raise
    if seam is not None:
        seam("after_temp_placed")
    if linked:
        _remove_temp(temp)  # best effort: the destination is already in place
    return "copied"


def _remove_temp(temp) -> None:
    try:
        os.unlink(temp)
    except FileNotFoundError:
        pass
    except OSError as e:
        logger.warning("could not remove a copy's temporary file: %s", type(e).__name__)


def prune_empty_dirs(directory: Path, root: Path) -> None:
    """Best-effort cleanup after a track leaves ``directory``: remove it and
    walk upward removing now-empty ancestors, never touching ``root`` itself
    or anything outside it. A directory holding even a hidden/junk file stops
    the walk — mirrors this codebase's policy of never destroying data the
    app didn't put there itself."""
    if is_internal_path(directory, root):
        return  # internal dirs (and their stages) are never pruned
    root = root.resolve()
    current = directory.resolve()
    while current != root and current.is_relative_to(root):
        # One directory's lock at a time (acquired, used, released before
        # moving to the parent) so this can never race move_file's own
        # per-directory lock into a deadlock.
        with _directory_locks.lock(directory_lock_key(current)):
            try:
                current.rmdir()
            except OSError:
                return  # not empty, already gone, or a permissions error — stop
        current = current.parent


def rollback_move(destination_path: Path, original_path: Path) -> bool:
    if not destination_path.exists():
        return False
    if original_path.exists():
        print(f"Cannot roll back move because original path already exists: {original_path}")
        return False
    try:
        original_path.parent.mkdir(parents=True, exist_ok=True)
        destination_path.replace(original_path)
        return True
    except (PermissionError, FileExistsError, OSError) as e:
        print(
            f"Exception trying to roll back move from {destination_path} to {original_path}: {e}"
        )
        return False


def sanitized_destination_path(
    filename: str, trackmetadata: TrackMetaData, root_dir: Path
) -> Path:
    """Where a track named ``filename`` belongs under ``root_dir`` given its
    (new) metadata, with artist/album sanitized for on-disk use.

    The DB row and the file's tags keep the **raw** artist/album; only the
    folder names are sanitized — so ``AC/DC`` stays ``AC/DC`` in metadata but is
    foldered as ``AC_DC``. Files go under the artist folder, and under the album
    folder only when there is an artist. The caller compares this against the current
    path to decide in-place vs relocation, and uses ``move_file`` to place the
    (already-tagged) staged file.
    """
    # Pick the winning raw artist first (matching the DB identity layer's
    # priority exactly), then sanitize only that winner -- sanitizing each
    # candidate independently before choosing would let the two layers pick
    # different artists whenever the raw winner collapses under sanitization
    # but the loser doesn't.
    raw_artist = effective_artist(trackmetadata.album_artist, trackmetadata.artist)
    destination_dir = root_dir
    artist = _safe_component(raw_artist)
    if artist:
        destination_dir /= artist
        album = _safe_component(trackmetadata.album)
        if album:
            destination_dir /= album
    return destination_dir / filename


def _safe_component(value: str | None) -> str | None:
    """Sanitize a folder-name component, collapsing an unusable value (empty,
    ``.``/``..``, all-illegal) to ``None`` so the track simply isn't foldered
    under it rather than raising mid-relocation."""
    if value is None or not value.strip():
        return None
    try:
        return sanitize_path_component(value)
    except UnsafePathComponent:
        return None
