from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

import app.services.organizer as organizer

class TestMoveFile:
    def test_move_file__source_does_not_exist__returns_false(self, tmp_path: Path):
        file_path = tmp_path / "does_not_exist.mp3"
        destination_path = tmp_path / "dest/does_not_exist.mp3"
        
        result = organizer.move_file(file_path, destination_path)
        
        assert result is False
        assert not destination_path.is_file()

    
    def test_move_file__source_does_exist__moves_files(self, tmp_path: Path):
        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"fake")

        destination_path = Path(tmp_path / "music/file.mp3")

        result = organizer.move_file(file_path, destination_path)
        assert result is True

        
        assert destinaton_path.is_file()

