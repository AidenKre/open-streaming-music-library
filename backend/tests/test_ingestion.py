from __future__ import annotations

import json
import subprocess
import zipfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import app.services.ingestion as ingestion
from app.core.media_types import ARCHIVE_EXTENSIONS, AUDIO_EXTENSIONS


class TestDoesMusicPassQuickCheck:
    def test_does_music_pass_quick_check__audio_stream_present__returns_true(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": [{"codec_type": "audio"}]}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is True

    def test_does_music_pass_quick_check__ffprobe_nonzero_exit__returns_false(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=1,
                stdout="",
                stderr="error",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__no_audio_streams__returns_false(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": [{"codec_type": "video"}]}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("video_only.mp4")) is False

    def test_does_music_pass_quick_check__ffprobe_missing__returns_false(self):
        with patch("app.services.ingestion.subprocess.run", side_effect=FileNotFoundError):
            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__invalid_json__returns_false(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout="not-json",
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__json_not_an_object__returns_false(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps(["streams"]),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__json_missing_streams_key__returns_false(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"not_streams": []}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__streams_is_none__returns_false(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": None}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__streams_empty__returns_false(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": []}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__non_dict_stream_entries_ignored__still_finds_audio(self):
        with patch("app.services.ingestion.subprocess.run") as run:
            run.return_value = subprocess.CompletedProcess(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": [None, 123, {"codec_type": "audio"}]}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is True


class TestIsMusicFile:
    @pytest.mark.parametrize("ext", sorted(AUDIO_EXTENSIONS))
    def test_is_music_file__supported_extension__returns_true(self, ext: str):
        assert ingestion.is_music_file(Path(f"song{ext}")) is True

    @pytest.mark.parametrize("ext", sorted(AUDIO_EXTENSIONS))
    def test_is_music_file__supported_extension_uppercase__returns_true(self, ext: str):
        assert ingestion.is_music_file(Path(f"song{ext.upper()}")) is True

    def test_is_music_file__no_extension__returns_false(self):
        assert ingestion.is_music_file(Path("song")) is False

    def test_is_music_file__unsupported_extension__returns_false(self):
        assert ingestion.is_music_file(Path("song.txt")) is False


class TestIsArchive:
    @pytest.mark.parametrize("ext", sorted(ARCHIVE_EXTENSIONS, key=len))
    def test_is_archive__supported_extension__returns_true(self, ext: str):
        assert ingestion.is_archive(Path(f"archive{ext}")) is True

    def test_is_archive__supported_extension_with_extra_dots__returns_true(self):
        assert ingestion.is_archive(Path("my.album.v1.zip")) is True
        assert ingestion.is_archive(Path("backup.2025.12.tar.gz")) is True

    def test_is_archive__no_extension__returns_false(self):
        assert ingestion.is_archive(Path("archive")) is False

    def test_is_archive__unsupported_extension__returns_false(self):
        assert ingestion.is_archive(Path("archive.gz")) is False


class TestExtractArchive:
    def test_extract_archive__valid_zip__extracts_files_under_base_dir(self, tmp_path: Path):
        archive_path = tmp_path / "valid.zip"
        base_dir = tmp_path / "extract_base"

        expected = {
            Path("a.mp3"): b"hello",
            Path("dir1/b.mp3"): b"world",
            Path("dir1/dir2/c.mp3"): b"foo",
        }

        with zipfile.ZipFile(archive_path, "w") as z:
            for rel, content in expected.items():
                z.writestr(rel.as_posix(), content)

        extract_dir = ingestion.extract_archive(archive_path, base_dir)
        assert extract_dir is not None
        assert extract_dir.is_dir()
        assert extract_dir.resolve().is_relative_to(base_dir.resolve())

        for rel, content in expected.items():
            extracted = extract_dir / rel
            assert extracted.is_file()
            assert extracted.read_bytes() == content

    def test_extract_archive__called_twice__returns_different_directories(self, tmp_path: Path):
        archive_path = tmp_path / "valid.zip"
        base_dir = tmp_path / "extract_base"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("song.mp3", "hello")

        first = ingestion.extract_archive(archive_path, base_dir)
        second = ingestion.extract_archive(archive_path, base_dir)

        assert first is not None
        assert second is not None
        assert first != second

        assert (first / "song.mp3").exists()
        assert (second / "song.mp3").exists()

    def test_extract_archive__invalid_archive__returns_none_and_cleans_up(self, tmp_path: Path):
        archive_path = tmp_path / "invalid.zip"
        archive_path.write_bytes(b"not a zip")
        base_dir = tmp_path / "extract_base"

        assert ingestion.extract_archive(archive_path, base_dir) is None

        if base_dir.exists():
            assert list(base_dir.iterdir()) == []

    def test_extract_archive__corrupted_archive__returns_none_and_cleans_up(self, tmp_path: Path):
        archive_path = tmp_path / "corrupted.zip"
        base_dir = tmp_path / "extract_base"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("song.mp3", "hello")

        data = archive_path.read_bytes()
        archive_path.write_bytes(data[:10])  # truncate

        assert ingestion.extract_archive(archive_path, base_dir) is None

        if base_dir.exists():
            assert list(base_dir.iterdir()) == []

    def test_extract_archive__path_traversal_entry__returns_none_and_does_not_write_outside(self, tmp_path: Path):
        archive_path = tmp_path / "traversal.zip"
        base_dir = tmp_path / "extract_base"
        outside_target = tmp_path / "evil.txt"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("../evil.txt", "pwned")
            z.writestr("ok.mp3", "safe")

        assert ingestion.extract_archive(archive_path, base_dir) is None

        assert outside_target.exists() is False
        if base_dir.exists():
            assert list(base_dir.iterdir()) == []


class TestIngestionServiceIngestFile:
    def test_ingest_file__valid_music_file__organizes_and_returns_true(self, tmp_path: Path):
        music_path = tmp_path / "song.mp3"
        music_path.write_bytes(b"fake")

        ctx = ingestion.IngestionContext(workspace_dir=tmp_path / "workspace")
        svc = ingestion.IngestionService(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True), patch(
            "app.services.ingestion.organize_file"
        ) as organize:
            assert svc.ingest_file(music_path) is True
            organize.assert_called_once_with(music_path)

    def test_ingest_file__unsupported_extension__returns_false_and_does_not_organize(self, tmp_path: Path):
        path = tmp_path / "note.txt"
        path.write_text("hello")

        ctx = ingestion.IngestionContext(workspace_dir=tmp_path / "workspace")
        svc = ingestion.IngestionService(ctx)

        quick_check = MagicMock(return_value=True)

        with patch("app.services.ingestion.does_music_pass_quick_check", quick_check), patch(
            "app.services.ingestion.organize_file"
        ) as organize:
            assert svc.ingest_file(path) is False

            organize.assert_not_called()
            quick_check.assert_not_called()

    def test_ingest_file__music_file_fails_quick_check__returns_false_and_does_not_organize(self, tmp_path: Path):
        music_path = tmp_path / "song.mp3"
        music_path.write_bytes(b"fake")

        ctx = ingestion.IngestionContext(workspace_dir=tmp_path / "workspace")
        svc = ingestion.IngestionService(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=False), patch(
            "app.services.ingestion.organize_file"
        ) as organize:
            assert svc.ingest_file(music_path) is False
            organize.assert_not_called()

    def test_ingest_file__invalid_archive__returns_false_and_does_not_organize(self, tmp_path: Path):
        archive_path = tmp_path / "bad.zip"
        archive_path.write_bytes(b"not a zip")

        ctx = ingestion.IngestionContext(workspace_dir=tmp_path / "workspace")
        svc = ingestion.IngestionService(ctx)

        with patch("app.services.ingestion.organize_file") as organize:
            assert svc.ingest_file(archive_path) is False
            organize.assert_not_called()

    def test_ingest_file__archive_with_music_and_non_music__organizes_only_music(self, tmp_path: Path):
        archive_path = tmp_path / "complex.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("valid_music.mp3", "hello")
            z.writestr("dir1/valid_music.mp3", "world")
            z.writestr("dir1/dir2/valid_music.mp3", "foo")
            z.writestr("not_music.txt", "nope")

        ctx = ingestion.IngestionContext(workspace_dir=workspace_dir)
        svc = ingestion.IngestionService(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True), patch(
            "app.services.ingestion.organize_file"
        ) as organize:
            assert svc.ingest_file(archive_path) is True

        extracted_music = {
            p
            for p in workspace_dir.rglob("*")
            if p.is_file() and p.suffix.lower() in AUDIO_EXTENSIONS
        }
        called_paths = {call.args[0] for call in organize.call_args_list}
        assert called_paths == extracted_music

    def test_ingest_file__archive_name_with_extra_dots__still_detected_as_archive(self, tmp_path: Path):
        archive_path = tmp_path / "my.album.v1.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("song.mp3", "hello")

        ctx = ingestion.IngestionContext(workspace_dir=workspace_dir)
        svc = ingestion.IngestionService(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True), patch(
            "app.services.ingestion.organize_file"
        ) as organize:
            assert svc.ingest_file(archive_path) is True

        assert any(call.args[0].suffix.lower() in AUDIO_EXTENSIONS for call in organize.call_args_list)

    def test_ingest_file__archive_music_fails_quick_check__skips_bad_tracks(self, tmp_path: Path):
        archive_path = tmp_path / "mix.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("good.mp3", "good")
            z.writestr("bad.mp3", "bad")

        ctx = ingestion.IngestionContext(workspace_dir=workspace_dir)
        svc = ingestion.IngestionService(ctx)

        def quick_check_side_effect(p: Path) -> bool:
            return p.name != "bad.mp3"

        with patch(
            "app.services.ingestion.does_music_pass_quick_check", side_effect=quick_check_side_effect
        ), patch("app.services.ingestion.organize_file") as organize:
            assert svc.ingest_file(archive_path) is True

        called_paths = {call.args[0].name for call in organize.call_args_list}
        assert called_paths == {"good.mp3"}

    def test_ingest_file__archive_with_no_music_files__returns_true_and_organizes_nothing(self, tmp_path: Path):
        archive_path = tmp_path / "no_music.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("readme.txt", "no songs here")

        ctx = ingestion.IngestionContext(workspace_dir=workspace_dir)
        svc = ingestion.IngestionService(ctx)

        quick_check = MagicMock(return_value=True)
        with patch("app.services.ingestion.does_music_pass_quick_check", quick_check), patch(
            "app.services.ingestion.organize_file"
        ) as organize:
            assert svc.ingest_file(archive_path) is True

        organize.assert_not_called()
        quick_check.assert_not_called()

