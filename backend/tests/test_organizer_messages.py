"""Sign-off 2026-11-17, OPEN-8-07 row 3 (live observation O-2): when moving a
file fails, the server no longer writes the full source and destination paths
to its output. The reason is logged through the module logger without any
path component (an OSError's own text names both files, so it is not used)."""

import errno
import logging
from pathlib import Path
from unittest.mock import patch

import pytest

import app.services.organizer as organizer
from app.models.track_meta_data import TrackMetaData

LOGGER = "app.services.organizer"
# Distinctive path components of the fixtures: none may reach the output.
SECRETS = ("private-source-folder", "Hidden Song", "library-root-x", "Secret Artist",
           "Secret Album", "parent-file")


@pytest.fixture
def world(tmp_path):
    source_dir = tmp_path / "private-source-folder"
    source_dir.mkdir()
    source = source_dir / "Hidden Song.flac"
    source.write_bytes(b"audio bytes")
    root = tmp_path / "library-root-x"
    root.mkdir()
    return source, root


def _assert_no_path_in_output(capsys, caplog, tmp_path):
    out, err = capsys.readouterr()
    logged = " ".join(r.getMessage() for r in caplog.records)
    for text in (out, err, logged):
        assert str(tmp_path) not in text
        for secret in SECRETS:
            assert secret not in text, f"{secret!r} leaked: {text!r}"
    assert out == "" and err == ""  # the module logger, not print
    return [r for r in caplog.records if r.name == LOGGER]


def _refusing_replace(*paths):
    """An OSError as the OS raises it: its text names both files."""
    def replace(self, target):
        raise PermissionError(errno.EACCES, "Permission denied", str(self), None, str(target))
    return replace


def test_a_move_onto_an_existing_file_logs_the_reason_without_paths(world, tmp_path, capsys, caplog):
    caplog.set_level(logging.DEBUG)
    source, root = world
    destination = root / "Secret Artist" / "Hidden Song.flac"
    destination.parent.mkdir()
    destination.write_bytes(b"other")

    assert organizer.move_file(file_path=source, destination_path=destination) is False

    records = _assert_no_path_in_output(capsys, caplog, tmp_path)
    assert [r.levelno for r in records] == [logging.WARNING]
    assert "already exists" in records[0].getMessage()


def test_a_destination_parent_that_is_a_file_logs_the_reason_without_paths(
    world, tmp_path, capsys, caplog
):
    caplog.set_level(logging.DEBUG)
    source, root = world
    (root / "parent-file").write_bytes(b"not a folder")
    destination = root / "parent-file" / "Hidden Song.flac"

    assert organizer.move_file(file_path=source, destination_path=destination) is False

    records = _assert_no_path_in_output(capsys, caplog, tmp_path)
    assert [r.levelno for r in records] == [logging.WARNING]
    assert "not a directory" in records[0].getMessage()


def test_a_failed_move_logs_the_reason_without_paths(world, tmp_path, capsys, caplog):
    caplog.set_level(logging.DEBUG)
    source, root = world
    destination = root / "Secret Artist" / "Secret Album" / "Hidden Song.flac"

    with patch.object(Path, "replace", _refusing_replace()):
        assert organizer.move_file(file_path=source, destination_path=destination) is False

    records = _assert_no_path_in_output(capsys, caplog, tmp_path)
    assert [r.levelno for r in records] == [logging.WARNING]
    assert "Permission denied" in records[0].getMessage()  # the reason is kept
    assert source.exists()


def test_a_failed_move_back_logs_the_reason_without_paths(world, tmp_path, capsys, caplog):
    caplog.set_level(logging.DEBUG)
    source, root = world
    placed = root / "Secret Artist" / "Hidden Song.flac"
    placed.parent.mkdir()
    placed.write_bytes(b"audio bytes")

    with patch.object(Path, "replace", _refusing_replace()):
        assert organizer.move_back(placed, source) is False

    records = _assert_no_path_in_output(capsys, caplog, tmp_path)
    assert [r.levelno for r in records] == [logging.WARNING]
    assert "Permission denied" in records[0].getMessage()


def test_an_import_onto_a_taken_destination_logs_the_refusal_without_paths(
    world, tmp_path, capsys, caplog
):
    caplog.set_level(logging.DEBUG)
    source, root = world
    taken = root / "Secret Artist" / "Secret Album" / "Hidden Song.flac"
    taken.parent.mkdir(parents=True)
    # U05-B-01: a taken name refuses only the same content (here the same bytes,
    # no hashes); a different track would get a numbered name.
    taken.write_bytes(b"audio bytes")
    org = organizer.Organizer(organizer.OrganizerContext(
        music_library_dir=root, should_organize_files=True, should_copy_files=False,
        add_to_database=lambda track: True,
    ))
    meta = TrackMetaData(title="Hidden Song", artist="Secret Artist", album="Secret Album",
                         codec="flac", duration=1.0)

    with patch("app.services.organizer.get_track_metadata", return_value=meta):
        assert org.organize(source) == organizer.ImportOutcome.DUPLICATE

    records = _assert_no_path_in_output(capsys, caplog, tmp_path)
    assert [r.levelno for r in records] == [logging.INFO]
    assert "same audio is already in the library" in records[0].getMessage()
    assert source.exists()
