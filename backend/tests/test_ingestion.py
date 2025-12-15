import app.services.ingestion as ingestion
from app.core.media_types import AUDIO_EXTENSIONS, ARCHIVE_EXTENSIONS
from pathlib import Path
import zipfile

# TODO: Make tests for ingestion...

"""
Test does_music_pass_quick_check()

Things to test...
- Returns True when...
A valid music file is provided (correct header, magic number ,etc. things that are checked by ffprobe)

-Returns False when...
- An invalid music file is provided (incorrect header, magic number, etc.) probablly need to manip data to make it invalid
"""
@patch("subprocess.run")
def test_quick_check_valid(mock_run):
    mock_run.return_value = 0
    valid_file = Path("test/data/valid_music.mp3")
    assert ingestion.does_music_pass_quick_check(valid_file)

@patch("subprocess.run")
def test_quick_check_invalid(mock_run):
    mock_run.return_value = 1
    invalid_file = Path("test/data/invalid_music.mp3")
    assert not ingestion.does_music_pass_quick_check(invalid_file)



""" 
Test is_music_file()

Things to test...
- Returns True when...
The file ends with a supported music file extension

-Returns False when...
The file does not end with a supported music file extension
"""
def test_is_music_file_valid():
    for extension in AUDIO_EXTENSIONS:  
        valid_file = Path(f"test/data/valid_music{extension}")
        assert ingestion.is_music_file(valid_file)

def test_is_music_file_invalid():
    for extension in AUDIO_EXTENSIONS:
        invalid_file = Path(f"test/data/invalid_music{extension + "invalid"}")
        assert not ingestion.is_music_file(invalid_file)

""" 
Test is_archive()

Things to test...
- Returns True when...
The file ends with a supported archive file extension

-Returns False when...
The file does not end with a supported archive file extension
"""
def test_is_archive_valid():
    for extension in ARCHIVE_EXTENSIONS:
        assert ingestion.is_archive(f"test/data/valid_archive{extension}")

def test_is_archive_invalid():
    for extension in ARCHIVE_EXTENSIONS:
        assert not ingestion.is_archive(f"test/data/invalid_archive{extension + "invalid"}")


""" 
Test extract_archive()

Things to test...
- Returns the directory path to the extracted archive when the archive is extracted successfully and that the directory path is in the temp directory
Check that the directory path returned contains the files in the archive
Check that calling extract_archive() on the same archive multiple times returns different directory paths (that all contain the files in the archive)

-Returns None when...
The archive is not a valid archive file (incorrect header, magic number, etc.) probablly need to manip data to make it invalid
The archive extraction fails (permissions error, etc.)
"""
def test_extract_archive_returns_input_path(tmp_path):
    archive_path = Path(tmp_path / "valid_archive.zip")
    extract_dir_path = tmp_path / "extracted_dir"
    with zipfile.ZipFile(archive_path, "w") as z:
        z.writestr("valid_music.mp3", "hello")
    assert ingestion.extract_archive(archive_path, extract_dir_path) == archive_path

def test_extract_archive_returns_fresh_directory_path(tmp_path):
    archive_path = Path(tmp_path / "valid_archive.zip")
    extract_dir_path = tmp_path / "extracted_dir"
    with zipfile.ZipFile(archive_path, "w") as z:
        z.writestr("valid_music.mp3", "hello")
    first_extracted_dir = ingestion.extract_archive(archive_path, extract_dir_path)
    second_extracted_dir = ingestion.extract_archive(archive_path, extract_dir_path)
    assert first_extracted_dir != second_extracted_dir
    assert first_extracted_dir.exists()
    assert first_extracted_dir.is_dir()
    assert second_extracted_dir.exists()
    assert second_extracted_dir.is_dir()
    assert (first_extracted_dir / "valid_music.mp3").exists()
    assert (second_extracted_dir / "valid_music.mp3").exists()

def test_extract_archive_extracts_all_files(tmp_path):
    archive_path = Path(tmp_path / "valid_archive.zip")
    extract_dir_path = tmp_path / "extracted_dir"
    with zipfile.ZipFile(archive_path, "w") as z:
        z.writestr("valid_music.mp3", "hello")
        z.writestr("dir1/valid_music.mp3", "world")
        z.writestr("dir1/dir2/valid_music.mp3", "foo")
    ingestion.extract_archive(archive_path, extract_dir_path)
    assert extract_dir_path.exists()
    assert extract_dir_path.is_dir()
    assert (extract_dir_path / "valid_music.mp3").exists()
    assert (extract_dir_path / "dir1" / "valid_music.mp3").exists()
    assert (extract_dir_path / "dir1" / "dir2" / "valid_music.mp3").exists()

def test_extract_invalid_archive_returns_none(tmp_path):
    bad_archive = Path(tmp_path / "invalid_archive.zip")
    bad_archive.write_bytes(b"invalid")
    extract_dir_path = tmp_path / "extracted_dir"
    assert ingestion.extract_archive(bad_archive, extract_dir_path) is None

def test_extract_corrupted_archive_returns_none(tmp_path):
    corrupted_archive = Path(tmp_path / "corrupted_archive.zip")
    
    with zipfile.ZipFile(corrupted_archive, "w") as z:
        z.writestr("valid_music.mp3", "hello")

    data = corrupted_archive.read_bytes()
    corrupted_archive.write_bytes(data[:10])

    extract_dir_path = tmp_path / "extracted_dir"
    assert ingestion.extract_archive(corrupted_archive, extract_dir_path) is None






"""
Test ingest_file()

Things to test...
Calls organizer.organize_file() for a valid music file
Calls organizer.organize_file() for each valid music file in an archive
    - Ensure archive has at least: one invalid music file, one non-music file
    - Ensure archive has multiple valid music files
    - Ensure that archive has a nested directory structure that leads to a valid music file
Does not call organizer.organize_file() for an invalid music file (incorrect header, magic number, etc.) probablly need to manip data to make it invalid
Does not call organizer.organize_file() for a non-music file (not a valid music file extension)
"""

def test_ingest_file_valid_music_file():
    with patch("app.services.organizer.organize_file") as mock_organize_file:
        with patch("app.services.ingestion.is_music_file", return_value=True):
            with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
                    valid_file = Path("test/data/valid_music.mp3")
                    assert ingestion.ingest_file(valid_file) is True
                    mock_organize_file.assert_called_once_with(valid_file)

def test_ingest_file_invalid_music_file():
    with patch("app.services.organizer.organize_file") as mock_organize_file:
        with patch("app.services.ingestion.is_music_file", return_value=True):
            with patch("app.services.ingestion.does_music_pass_quick_check", return_value=False):
                invalid_file = Path("test/data/invalid_music.mp3")
                assert ingestion.ingest_file(invalid_file) is False
                mock_organize_file.assert_not_called()

def test_ingest_file_non_music_file():
    with patch("app.services.organizer.organize_file") as mock_organize_file:
        with patch("app.services.ingestion.is_music_file", return_value=False):
            non_music_file = Path("test/data/non_music_file.txt")
            assert ingestion.ingest_file(non_music_file) is False
            mock_organize_file.assert_not_called()


def test_ingest_file_complex_archive(tmp_path):
    with patch("app.services.organizer.organize_file") as mock_organize_file:
        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            archive_path = Path(tmp_path / "complex_archive.zip")
            with zipfile.ZipFile(archive_path, "w") as z:
                z.writestr("valid_music.mp3", "hello")
                z.writestr("dir1/valid_music.mp3", "world")
                z.writestr("dir1/dir2/valid_music.mp3", "foo")
                z.writestr("invalid_file.txt", "invalid")
            ingestion.ingest_file(archive_path)
            mock_organize_file.assert_called_once_with(archive_path)
            mock_organize_file.assert_called_with(Path(archive_path / "valid_music.mp3"))
            mock_organize_file.assert_called_with(Path(archive_path / "dir1" / "valid_music.mp3"))
            mock_organize_file.assert_called_with(Path(archive_path / "dir1" / "dir2" / "valid_music.mp3"))
            mock_organize_file.assert_not_called_with(Path(archive_path / "invalid_file.txt"))