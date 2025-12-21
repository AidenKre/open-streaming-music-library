from pathlib import Path
from app.core.media_types import AUDIO_EXTENSIONS, ARCHIVE_EXTENSIONS
from .organizer import organize_file
from dataclasses import dataclass
import libarchive
import shutil
import subprocess
import json

@dataclass(frozen=True)
class IngestionContext:
    workspace_dir: Path

class IngestionService:
    def __init__(self, ctx: IngestionContext):
        self.ctx = ctx

    def ingest_file(self, file_path: Path) -> bool:
        if is_archive(file_path):
            extract_dir = extract_archive(file_path, self.ctx.workspace_dir)

            if extract_dir is None:
                return False
            
            for path in extract_dir.rglob("*"):
                if not path.is_file():
                    continue

                if not is_music_file(path):
                    continue

                if not does_music_pass_quick_check(path):
                    continue

                organize_file(path)
            return True

        if not is_music_file(file_path):
            return False
        if not does_music_pass_quick_check(file_path):
            return False
        
        organize_file(file_path)
        return True
        
def is_music_file(file_path: Path) -> bool:
    return file_path.suffix.lower() in AUDIO_EXTENSIONS

def is_archive(file_path: Path) -> bool:
    # Match against known archive extensions at the *end* of the filename.
    # This intentionally supports names with extra dots like "my.album.v1.zip" or "backup.2025.12.tar.gz".
    name = file_path.name.lower()
    return any(name.endswith(ext) for ext in ARCHIVE_EXTENSIONS)

def does_music_pass_quick_check(file_path: Path) -> bool:
    try:
        completed_process = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "a",
                "-hide_banner",
                "-show_entries",
                "stream=codec_type",
                "-read_intervals",
                "0%+#20",
                "-of",
                "json",
                str(file_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        print("ffprobe not found")
        return False
    except OSError:
        return False

    if completed_process.returncode != 0:
        return False

    try:
        output = json.loads(completed_process.stdout or "")
    except json.JSONDecodeError:
        return False

    if not isinstance(output, dict):
        return False

    streams = output.get("streams", [])
    if not isinstance(streams, list):
        return False

    for stream in streams:
        if isinstance(stream, dict) and stream.get("codec_type") == "audio":
            return True
    return False

# TODO: Create propper directory path naming scheme
def handle_extract_path(extract_path: Path) -> Path:
    try:
        extract_path.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        extract_path = extract_path.with_name(extract_path.name + "_1")
        return handle_extract_path(extract_path)
    return extract_path

# TODO: Do not assume disk usage allows to extract archive
def extract_archive(archive_path: Path, base_dir: Path) -> Path | None:
    extract_dir = handle_extract_path(base_dir / archive_path.name.split(".", 1)[0])
    try:
        with libarchive.file_reader(str(archive_path)) as archive:
            for entry in archive:
                
                # Only allow files and directories
                if not (entry.isfile or entry.isdir):
                    continue

                target = extract_dir / entry.pathname
                entry_path = target.resolve()

                if not entry_path.is_relative_to(extract_dir.resolve()):
                    raise ValueError("Path traversal detected")
                
                if entry.isdir:
                    entry_path.mkdir(parents=True, exist_ok=True)
                    continue

                # Regular file
                entry_path.parent.mkdir(parents=True, exist_ok=True)

                with open(entry_path, "wb") as f:
                    for block in entry.get_blocks():
                        f.write(block)
                    print(f"Extracted file: {entry_path}")
        
        return extract_dir
    
    except Exception as e:
        shutil.rmtree(extract_dir, ignore_errors=True)
        print(f"Error extracting archive: {e}")
        return None

if __name__ == "__main__":
    good_song = Path("/Volumes/Acasis/Musix/temp.m4a")
    bad_song = Path("/Volumes/Acasis/Musix/bad_temp.m4a")
    movie = Path("/Volumes/Acasis/Movies/Blackened.Mantle.2023.Kurosawa.Edition.HQ.1080p.mp4")
    print(does_music_pass_quick_check(good_song))
    print(does_music_pass_quick_check(bad_song))
    print(does_music_pass_quick_check(movie))