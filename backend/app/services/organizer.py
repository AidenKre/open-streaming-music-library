import hashlib
import logging
import os
import re
import sqlite3
import stat
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from app.core.internal_dirs import is_internal_path
from app.core.operator_log import operator_logger
from app.database.database import CoverArtGone, TrackPathTaken, _fold_path, effective_artist
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.audio_identity import ExactAudioHash, ExactUnavailable, exact_match
from app.services.cover_art_manager import CoverArtAddResult
# The file helpers live in file_ops.py. Every one that was public here is still
# importable from here (``organizer.move_file`` ...), together with the folder
# locks; this module's own code uses move_file, rollback_move, is_own_hard_link
# and COPY_BLOCK_BYTES.
from app.services.file_ops import (  # noqa: F401
    COPY_BLOCK_BYTES,
    FALLBACK_ERRNOS,
    HardLinkError,
    LinkUnknown,
    _directory_locks,
    directory_lock_key,
    flush_move,
    is_own_hard_link,
    move_back,
    move_file,
    place_no_replace,
    prune_empty_dirs,
    rollback_move,
    temp_name_for,
)
from app.services.import_outcome import ImportOutcome, file_signature
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.identity_reasons import is_content_failure
from app.services.metadata import (
    ProbeUnavailable, extract_cover_art_bytes, get_track_metadata, probe_unavailable_raises, probes_killed_by,
)
from app.services.path_sanitize import (
    PathEscapesRoot,
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


class _AudioNotReadableNow(Exception):
    """The audio of the file already under a taken name cannot be read now: the
    import is a temporary failure with ``outcome``, retried later."""

    def __init__(self, outcome: ImportOutcome):
        super().__init__(outcome.value)
        self.outcome = outcome


def same_bytes(a: Path, b: Path) -> bool:
    """True when both files hold the same bytes (size first, then SHA-256);
    False when either is gone. Any other read error (``OSError``) propagates."""
    try:
        if os.path.getsize(a) != os.path.getsize(b):
            return False
        return _sha256(a) == _sha256(b)
    except FileNotFoundError:
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
    # Whether a track already uses a path (any owner); register_in_place refuses
    # such a path. organize() does not use it.
    path_in_use: Callable[[Path], bool] | None = None
    # The metadata probe runs registered here, so closing it at shutdown ends it.
    probe_registry: FfmpegProcessRegistry | None = None
    # The tracks whose master file sits in a folder, with their stored exact
    # hash (Database.track_identities_in_folder rows). None: only the disk is
    # consulted when a library name is taken, and no stored hash is known.
    folder_tracks: Callable[[Path], list[dict]] | None = None
    # Whose import it is (a user id), only for log lines; None: not known.
    owner_id: int | None = None

    def __post_init__(self):
        if not self.should_organize_files and self.should_copy_files:
            raise ValueError(
                "If files are not being organized (should_organize_files is False), "
                "then files remain in their existing location. Therefore, should_copy_files must be False."
            )


class Organizer:
    def __init__(self, ctx: OrganizerContext):
        self.ctx = ctx

    def _compute_identity(self, file_path: Path, codec: str | None) -> Any:
        """The exact layer of the source file, or None (left pending for the
        worker) when not configured, stopping, or the compute fails. For the
        incoming file it never changes the import outcome (for a library file
        under a taken name, see ``_decode_existing``)."""
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
            operator_logger.warning(
                "ffprobe unavailable for %s of user %s", file_path.name, self.ctx.owner_id
            )
            return ImportOutcome.TOOL_UNAVAILABLE

        if trackmetadata is None or trackmetadata.is_empty():
            operator_logger.warning(
                "%s of user %s does not result in a TrackMetaData",
                file_path.name, self.ctx.owner_id,
            )
            return ImportOutcome.FAILS_CHECK
        # Before the destination is computed, so the folders and the database agree.
        trackmetadata = nfc_track_metadata(trackmetadata)

        try:
            safe_name = sanitize_file_name(file_path.name)
        except UnsafePathComponent:
            operator_logger.warning(
                "%s of user %s has an unusable file name", file_path.name, self.ctx.owner_id
            )
            return ImportOutcome.FAILS_CHECK

        destination_path = sanitized_destination_path(
            safe_name, trackmetadata, self.ctx.music_library_dir
        )

        # Explicit raise (not assert) so it holds under ``python -O``; checked
        # before anything touches the disk.
        assert_within(destination_path, self.ctx.music_library_dir)

        # Internal dirs (.staging, .uploads, ...) are never a library home.
        if is_internal_path(destination_path, self.ctx.music_library_dir):
            operator_logger.warning(
                "Destination %s is inside an internal directory.",
                os.path.relpath(destination_path, self.ctx.music_library_dir),
            )
            return ImportOutcome.FAILS_CHECK

        trackmetadata, cover_art_result, art_bytes = self._register_cover_art(
            file_path, trackmetadata
        )

        # Changed since it was read: abandon without touching the file.
        if file_signature(file_path) != before:
            self._cleanup_cover_art(cover_art_result)
            return ImportOutcome.CHANGED

        identity = self._compute_identity(file_path, trackmetadata.codec)

        # A taken name holding the same audio refuses the import; a different
        # track gets a numbered name; a library file whose audio cannot be read
        # now defers the import (TOOL_UNAVAILABLE or STOPPED, retried later).
        # move_file never replaces: a refusal on a name that now exists means a
        # concurrent import took it, so choose again. The same when the database
        # refuses the row (TrackPathTaken: another track's row came to name the
        # path after the name was chosen): the file is taken back first. (Refused
        # on _add_track's retry after vanished cover art, it ends as a failed row
        # write instead: the file is taken back and a later scan chooses again.)
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
            except _AudioNotReadableNow as e:
                logger.info("import deferred: the audio of the file already under this name "
                            "cannot be read now")
                self._cleanup_cover_art(cover_art_result)
                return e.outcome
            except Exception:
                self._cleanup_cover_art(cover_art_result)
                raise
            if choice is ImportOutcome.DUPLICATE:
                logger.info("import refused: the same audio is already in the library under this name")
                self._cleanup_cover_art(cover_art_result)
                return ImportOutcome.DUPLICATE
            destination_path = choice
            if not move_file(file_path=file_path, destination_path=destination_path):
                if not file_path.is_file() or not os.path.lexists(destination_path):
                    self._cleanup_cover_art(cover_art_result)
                    return ImportOutcome.MOVE_FAILED
                continue
            track = Track(
                file_path=destination_path, metadata=trackmetadata, audio_identity=identity
            )
            try:
                was_added, cover_art_result = self._add_track(track, art_bytes, cover_art_result)
            except TrackPathTaken:
                if rollback_move(destination_path=destination_path, original_path=file_path):
                    continue
                operator_logger.warning(
                    "Failed to add track to database after move: %s",
                    os.path.relpath(destination_path, self.ctx.music_library_dir),
                )
                self._cleanup_cover_art(cover_art_result)
                return ImportOutcome.DATABASE_ERROR
            break
        else:
            self._cleanup_cover_art(cover_art_result)
            return ImportOutcome.MOVE_FAILED

        if not was_added:
            operator_logger.warning(
                "Failed to add track to database after move: %s",
                os.path.relpath(destination_path, self.ctx.music_library_dir),
            )
            rollback_move(destination_path=destination_path, original_path=file_path)
            self._cleanup_cover_art(cover_art_result)
            return ImportOutcome.DATABASE_ERROR

        if destination_path != base_path:
            logger.info("import placed under a numbered name: a different track already uses the name")
        if self.ctx.on_imported is not None:
            self.ctx.on_imported(track, before)
        return ImportOutcome.IMPORTED

    def register_in_place(
        self, file_path: Path, metadata: TrackMetaData, identity: Any = None
    ) -> str | None:
        """Make a file that already lies inside the library root a track, without
        moving it. Returns the new track's uuid, or None (nothing touched) for a
        path outside the root, in an internal folder, not a regular file, already
        used by a track, or refused by the database."""
        root = self.ctx.music_library_dir
        try:
            assert_within(file_path, root)
        except PathEscapesRoot:
            return None
        if is_internal_path(file_path, root):
            return None
        try:
            if not stat.S_ISREG(os.lstat(file_path).st_mode):
                return None
        except OSError:
            return None
        if self.ctx.path_in_use is not None and self.ctx.path_in_use(file_path):
            return None
        metadata, cover_art_result, art_bytes = self._register_cover_art(file_path, metadata)
        track = Track(file_path=file_path, metadata=metadata, audio_identity=identity)
        try:
            was_added, cover_art_result = self._add_track(track, art_bytes, cover_art_result)
        except TrackPathTaken:  # refused by the database: used by a track after all
            was_added = False
        if not was_added:
            self._cleanup_cover_art(cover_art_result)
            return None
        return track.uuid_id

    def _register_cover_art(
        self, file_path: Path, metadata: TrackMetaData
    ) -> tuple[TrackMetaData, CoverArtAddResult | None, bytes | None]:
        """Extract and register the file's cover art, if it has any. Returns the
        metadata (pointing at the art), the add result and the art bytes."""
        cover_art_result: CoverArtAddResult | None = None
        art_bytes: bytes | None = None
        if metadata.has_album_art and self.ctx.add_cover_art is not None:
            with probes_killed_by(self.ctx.probe_registry):
                art_bytes = extract_cover_art_bytes(file_path)
            if art_bytes:
                try:
                    cover_art_result = self.ctx.add_cover_art(art_bytes)
                    metadata = metadata.model_copy(
                        update={"cover_art_id": cover_art_result.cover_art_id}
                    )
                except ValueError as e:
                    operator_logger.warning("Failed to add cover art for %s: %s", file_path.name, e)
        return metadata, cover_art_result, art_bytes

    def _add_track(
        self, track: Track, art_bytes: bytes | None,
        cover_art_result: CoverArtAddResult | None,
    ) -> tuple[bool, CoverArtAddResult | None]:
        """Insert the track; if its shared art was released between add_cover_art
        and the insert, re-register the art and retry exactly once. Returns
        whether it was added and the cover-art result now in effect."""
        try:
            return self.ctx.add_to_database(track), cover_art_result
        except CoverArtGone:
            if art_bytes and self.ctx.add_cover_art is not None:
                try:
                    cover_art_result = self.ctx.add_cover_art(art_bytes)
                    track.metadata = track.metadata.model_copy(
                        update={"cover_art_id": cover_art_result.cover_art_id}
                    )
                    return self.ctx.add_to_database(track), cover_art_result
                except CoverArtGone:
                    pass
                except Exception as e:
                    operator_logger.warning(
                        "Retry after vanished cover art failed for %s: %s",
                        track.file_path.name,
                        getattr(e, "strerror", None) or type(e).__name__,
                    )
            return False, cover_art_result

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
        # A certain duplicate wins over a copy that cannot be read now.
        not_now: _AudioNotReadableNow | None = None
        for existing, row in family:
            try:
                if self._same_audio(source, incoming, existing, row):
                    return ImportOutcome.DUPLICATE
            except _AudioNotReadableNow as e:
                not_now = not_now or e
        if not_now is not None:
            raise not_now
        return folder / numbered_name(stem, highest + 1, ext)

    def _same_audio(self, source: Path, incoming: Any, existing: Path, row: dict | None) -> bool:
        """Does ``existing`` hold the same audio as ``source`` (exact hash
        ``incoming``)? Its stored hash answers when current; otherwise it is
        decoded once. A hash missing on either side, or a file unreadable for
        good, compares the bytes. Raises ``_AudioNotReadableNow`` when
        ``existing`` (or, for the bytes, either file) cannot be read now."""
        if isinstance(incoming, ExactAudioHash):
            theirs = _stored_hash(row) or self._decode_existing(existing)
            if isinstance(theirs, ExactAudioHash):
                return exact_match(incoming, theirs)
        try:
            return same_bytes(source, existing)
        except OSError as e:
            raise self._not_now() from e

    def _not_now(self) -> _AudioNotReadableNow:
        """The deferral of an import: STOPPED while stopping, else TOOL_UNAVAILABLE."""
        stopping = self.ctx.should_stop is not None and self.ctx.should_stop()
        return _AudioNotReadableNow(ImportOutcome.STOPPED if stopping else ImportOutcome.TOOL_UNAVAILABLE)

    def _require_readable_now(self, path: Path) -> None:
        """Raise the deferral unless ``path`` can be opened and read now or is
        gone: ffprobe and ffmpeg report a file they cannot open (EACCES, EIO) like
        a refusal or a decode error, so their answer alone is no proof that it
        is unreadable for good."""
        try:
            with open(path, "rb") as f:
                f.read(1)
        except FileNotFoundError:
            return  # gone: the bytes answer "not the same"
        except OSError as e:
            raise self._not_now() from e

    def _decode_existing(self, path: Path) -> Any:
        """The exact hash of a library file without a stored one, or None when
        there is none for good (not configured, not a regular file, refused by
        ffprobe, unsupported, a content failure, each once the file is shown to
        be readable now): the bytes then decide. Raises ``_AudioNotReadableNow``
        when it cannot be read now: STOPPED while stopping, else
        TOOL_UNAVAILABLE (a path that cannot be examined, a probe or decode
        that cannot run or failed outside the file's content)."""
        if self.ctx.compute_identity is None:
            return None
        try:
            if not path.is_file():  # missing, not a folder, a symlink loop: False
                return None
        except OSError as e:  # Python 3.12 raises the others (EACCES, EIO ...)
            raise self._not_now() from e
        try:
            with probe_unavailable_raises(), probes_killed_by(self.ctx.probe_registry):
                meta = get_track_metadata(file_path=path)
        except ProbeUnavailable as e:
            raise self._not_now() from e
        if meta is None:
            self._require_readable_now(path)
            return None
        identity = self._compute_identity(path, meta.codec)
        if identity is None:  # stopping, or the compute raised
            raise self._not_now()
        exact = getattr(identity, "exact", None)
        if isinstance(exact, ExactUnavailable):
            if exact.state != "unsupported" and not is_content_failure(exact.reason):
                raise self._not_now()
            self._require_readable_now(path)
        return exact

    def _cleanup_cover_art(self, cover_art_result: CoverArtAddResult | None) -> None:
        if cover_art_result is None or not cover_art_result.was_created:
            return
        if self.ctx.release_cover_art is None:
            return
        try:
            self.ctx.release_cover_art(cover_art_result.cover_art_id)
        except ValueError as e:
            operator_logger.warning(
                "Failed to remove cover art %s: %s",
                cover_art_result.cover_art_id, e,
            )


def final_is_own_link(row) -> bool:
    """Is a commit journal's final name its work file's own link? Raises
    ``LinkUnknown`` when the name cannot be examined."""
    return is_own_hard_link(row["work_path"], row["final_path"], strict=True)


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
