from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.cover_art_manager import CoverArtAddResult
from app.services.metadata import extract_cover_art_bytes, get_track_metadata

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
    # Currently only supporting atomic move, so if file exists, return false
    if destination_path.exists():
        print(f"Destination {destination_path} already exists.")
        return False

    parent = destination_path.parent

    if parent.exists() and not parent.is_dir():
        print(f"Destination parent is not a directory: {parent}")
        return False

    try:
        parent.mkdir(parents=True, exist_ok=True)
        # Fails if moving to a different filesystem, since it is an atomic move
        file_path.replace(destination_path)
        return True
    except (PermissionError, FileExistsError, OSError) as e:
        print(f"Exception trying to move {file_path} to {destination_path}: {e}")
        return False


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
    destination_dir = root_dir

    if trackmetadata.album_artist:
        destination_dir /= trackmetadata.album_artist
    elif trackmetadata.artist:
        destination_dir /= trackmetadata.artist

    if trackmetadata.album_artist or trackmetadata.artist:
        if trackmetadata.album:
            destination_dir /= trackmetadata.album

    return destination_dir
