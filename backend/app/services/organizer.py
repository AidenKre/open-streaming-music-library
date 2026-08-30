from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from app.database.database import effective_artist
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.cover_art_manager import CoverArtAddResult
from app.services.keyed_locks import KeyedLocks
from app.services.metadata import extract_cover_art_bytes, get_track_metadata
from app.services.path_sanitize import UnsafePathComponent, sanitize_path_component

# Per-directory mutual exclusion for move_file/prune_empty_dirs: without it,
# one track's prune of a now-empty shared album directory can race another
# track's move into that same directory (removing it out from under a
# concurrent mkdir+replace), and two concurrent moves to the same destination
# can race the exists()-then-replace() check-then-act into a silent clobber.
# Mirrors TrackLocks' "never delete the entry" KeyedLocks pattern.
_directory_locks = KeyedLocks[Path]()

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
    remove_cover_art: Callable[[int], bool] | None = None

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
        if not self.ctx.should_organize_files:
            raise NotImplementedError(
                "Organizer does not support in place organization yet"
            )

        if self.ctx.should_copy_files:
            raise NotImplementedError("Organizer does not support copying yet")

        # Case: Organizing and Moving (not copying)
        trackmetadata = get_track_metadata(file_path=file_path)

        if trackmetadata is None or trackmetadata.is_empty():
            print(f"{file_path} does not result in a TrackMetaData")
            return False

        cover_art_result: CoverArtAddResult | None = None

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

        destination_dir = create_destination_dir(
            trackmetadata=trackmetadata, root_dir=self.ctx.music_library_dir
        )

        destination_dir.mkdir(parents=True, exist_ok=True)

        destination_path = destination_dir / file_path.name

        was_moved = move_file(file_path=file_path, destination_path=destination_path)

        if not was_moved:
            self._cleanup_cover_art(cover_art_result)
            return False

        track = Track(
            file_path=destination_path, metadata=trackmetadata, file_hash=None
        )

        was_added = self.ctx.add_to_database(track)
        if not was_added:
            print(f"Failed to add track to database after move: {destination_path}")
            rollback_move(destination_path=destination_path, original_path=file_path)
            self._cleanup_cover_art(cover_art_result)
            return False

        return True

    def _cleanup_cover_art(self, cover_art_result: CoverArtAddResult | None) -> None:
        if cover_art_result is None or not cover_art_result.was_created:
            return
        if self.ctx.remove_cover_art is None:
            return
        try:
            self.ctx.remove_cover_art(cover_art_result.cover_art_id)
        except ValueError as e:
            print(f"Failed to remove cover art {cover_art_result.cover_art_id}: {e}")


def move_file(file_path: Path, destination_path: Path) -> bool:
    if not file_path.is_file():
        return False
    parent = destination_path.parent

    # Held for the whole exists-check + mkdir + replace sequence so a
    # concurrent move_file to the same destination, or a concurrent
    # prune_empty_dirs on this same directory, can't interleave with it.
    with _directory_locks.lock(parent.resolve()):
        if parent.exists() and not parent.is_dir():
            print(f"Destination parent is not a directory: {parent}")
            return False
        # Currently only supporting atomic move, so if file exists, return false
        if destination_path.exists():
            print(f"Destination {destination_path} already exists.")
            return False
        try:
            parent.mkdir(parents=True, exist_ok=True)
            # Fails if moving to a different filesystem, since it is an atomic move
            file_path.replace(destination_path)
            return True
        except (PermissionError, FileExistsError, OSError) as e:
            print(f"Exception trying to move {file_path} to {destination_path}: {e}")
            return False


def prune_empty_dirs(directory: Path, root: Path) -> None:
    """Best-effort cleanup after a track leaves ``directory``: remove it and
    walk upward removing now-empty ancestors, never touching ``root`` itself
    or anything outside it. A directory holding even a hidden/junk file stops
    the walk — mirrors this codebase's policy of never destroying data the
    app didn't put there itself."""
    root = root.resolve()
    current = directory.resolve()
    while current != root and current.is_relative_to(root):
        # One directory's lock at a time (acquired, used, released before
        # moving to the parent) so this can never race move_file's own
        # per-directory lock into a deadlock.
        with _directory_locks.lock(current):
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


def create_destination_dir(trackmetadata: TrackMetaData, root_dir: Path) -> Path:
    # Use the same album_artist-vs-artist rule the DB identity uses so a
    # track's on-disk folder and its DB artist node can never disagree.
    destination_dir = root_dir
    artist = effective_artist(trackmetadata.album_artist, trackmetadata.artist)
    if artist:
        destination_dir /= artist
        if trackmetadata.album:
            destination_dir /= trackmetadata.album

    return destination_dir


def sanitized_destination_path(
    filename: str, trackmetadata: TrackMetaData, root_dir: Path
) -> Path:
    """Where a track named ``filename`` belongs under ``root_dir`` given its
    (new) metadata, with artist/album sanitized for on-disk use.

    The DB row and the file's tags keep the **raw** artist/album; only the
    folder names are sanitized — so ``AC/DC`` stays ``AC/DC`` in metadata but is
    foldered as ``AC_DC``. Reuses ``create_destination_dir`` by feeding it a
    sanitized copy of the metadata. The caller compares this against the current
    path to decide in-place vs relocation, and uses ``move_file`` to place the
    (already-tagged) staged file.
    """
    # Pick the winning raw artist first (matching the DB identity layer's
    # priority exactly), then sanitize only that winner -- sanitizing each
    # candidate independently before choosing would let the two layers pick
    # different artists whenever the raw winner collapses under sanitization
    # but the loser doesn't.
    raw_artist = effective_artist(trackmetadata.album_artist, trackmetadata.artist)
    sanitized = trackmetadata.model_copy(
        update={
            "album_artist": _safe_component(raw_artist),
            "artist": None,
            "album": _safe_component(trackmetadata.album),
        }
    )
    return create_destination_dir(sanitized, root_dir) / filename


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
