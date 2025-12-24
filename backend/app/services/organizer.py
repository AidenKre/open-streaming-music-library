from pathlib import Path
from dataclasses import dataclass

from app.models.track import Track
from app.services.metadata import get_track_metadata
from typing import Callable
from app.models.track import Track

# TODO: implement organizer

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
            raise NotImplementedError("Organizer does not support in place organization yet")
        
        if self.ctx.should_copy_files:
            raise NotImplementedError("Organizer does not support copying yet")
        
        # Case: Organizing and Moving (not copying)
        trackmetadata = get_track_metadata(file_path=file_path)

        if trackmetadata is None or trackmetadata.is_empty():
            print(f"{file_path} does not result in a TrackMetaData")
            return False
        
        destination_dir = self.ctx.music_library_dir

        if trackmetadata.artist:
            destination_dir = destination_dir / trackmetadata.artist
            if trackmetadata.album:
                destination_dir = destination_dir / trackmetadata.album

        destination_dir.mkdir(parents=True, exist_ok=True)

        destination_path = destination_dir / file_path.name

        was_moved = move_file(file_path=file_path, destination_path=destination_path)

        if not was_moved:
            return False
        
        track = Track(
            file_path=destination_path,
            metadata=trackmetadata,
            file_hash=None
        )

        self.ctx.add_to_database(track)

        return True


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