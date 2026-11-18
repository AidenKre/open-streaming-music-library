from __future__ import annotations

import json
import logging
import os
import subprocess
import tarfile
import threading
import zipfile
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

import app.services.ingestion as ingestion
from app.services import import_archive
from tests.archive_builders import rar4 as _rar4, rar5 as _rar5, rar_vint as _rar_vint
from tests.upload_zip_fixtures import tiny_limits
from app.core.media_types import ARCHIVE_EXTENSIONS, AUDIO_EXTENSIONS
from app.services.import_outcome import ImportOutcome
from app.services.ffmpeg_runner import CaptureResult


def _completed(args, returncode, stdout, stderr):
    """What ``run_capture`` returns for a finished probe (U05-A-06: the probes
    run through it, bounded)."""
    return CaptureResult(returncode=returncode, stdout=stdout.encode("utf-8"), stderr=stderr)


class TestDoesMusicPassQuickCheck:
    def test_does_music_pass_quick_check__audio_stream_present__returns_true(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": [{"codec_type": "audio"}]}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is True

    def test_does_music_pass_quick_check__ffprobe_nonzero_exit__returns_false(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=1,
                stdout="",
                stderr="error",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__no_audio_streams__returns_false(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": [{"codec_type": "video"}]}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("video_only.mp4")) is False

    def test_does_music_pass_quick_check__ffprobe_missing__raises_probe_unavailable(self):
        # Review r2 m-R2-01: ffprobe that cannot run is environmental, not a
        # verdict on the file (was: returns False).
        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=FileNotFoundError):
            with pytest.raises(ingestion.ProbeUnavailable):
                ingestion.does_music_pass_quick_check(Path("song.mp3"))

    def test_does_music_pass_quick_check__invalid_json__returns_false(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout="not-json",
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__json_not_an_object__returns_false(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps(["streams"]),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__json_missing_streams_key__returns_false(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"not_streams": []}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__streams_is_none__returns_false(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": None}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__streams_empty__returns_false(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": []}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_does_music_pass_quick_check__non_dict_stream_entries_ignored__still_finds_audio(self):
        with patch("app.services.ingestion.run_capture", autospec=True) as run:
            run.return_value = _completed(
                args=["ffprobe"],
                returncode=0,
                stdout=json.dumps({"streams": [None, 123, {"codec_type": "audio"}]}),
                stderr="",
            )

            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is True


class TestTheQuickCheckReadsExitsLikeTheSharedRule:
    """Review of U05-A-06 (findings 1 and 4): only a SIGKILL (a stop through
    the registry, the OOM killer) says nothing about the file; ffprobe dying
    of another signal (a crafted file crashing it) is the file's own answer,
    as in identity_reasons.reason_for_exit. An OSError while starting the
    probe is "cannot run now"."""

    def test_a_sigkill_is_unavailable_for_now(self):
        import signal

        with patch("app.services.ingestion.run_capture", autospec=True,
                   return_value=_completed([], -signal.SIGKILL, "", "")):
            with pytest.raises(ingestion.ProbeUnavailable):
                ingestion.does_music_pass_quick_check(Path("song.mp3"))

    @pytest.mark.parametrize("sig", ["SIGSEGV", "SIGABRT", "SIGTERM"])
    def test_another_signal_is_the_files_own_answer(self, sig):
        import signal

        with patch("app.services.ingestion.run_capture", autospec=True,
                   return_value=_completed([], -getattr(signal, sig), "", "")):
            assert ingestion.does_music_pass_quick_check(Path("song.mp3")) is False

    def test_an_oserror_while_starting_is_unavailable_for_now(self):
        import errno

        with patch("app.services.ingestion.run_capture", autospec=True,
                   side_effect=OSError(errno.EMFILE, "Too many open files")):
            with pytest.raises(ingestion.ProbeUnavailable):
                ingestion.does_music_pass_quick_check(Path("song.mp3"))


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
    @pytest.mark.parametrize("ext", sorted(ARCHIVE_EXTENSIONS, key=lambda e: (len(e), e)))
    def test_is_archive__supported_extension__returns_true(self, ext: str):
        assert ingestion.is_archive(Path(f"archive{ext}")) is True

    def test_is_archive__supported_extension_with_extra_dots__returns_true(self):
        assert ingestion.is_archive(Path("my.album.v1.zip")) is True
        assert ingestion.is_archive(Path("backup.2025.12.tar.gz")) is True

    def test_is_archive__no_extension__returns_false(self):
        assert ingestion.is_archive(Path("archive")) is False

    def test_is_archive__unsupported_extension__returns_false(self):
        assert ingestion.is_archive(Path("archive.gz")) is False


# The tests of the removed ``extract_archive`` moved (sign-off DEV-7-14 point 1):
# a valid archive and two unpacks of one archive to test_import_archive_unpack.py;
# an invalid, truncated or path-traversing archive is one parametrised wiring
# test in test_import_archive_limits.py (its rules are the shared inspection's,
# tested once in test_upload_zip_inspect.py).


class TestIngestionServiceIngestFile:
    def test_ingest_file__valid_music_file__organizes_and_returns_true(self, tmp_path: Path):
        music_path = tmp_path / "song.mp3"
        music_path.write_bytes(b"fake")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=tmp_path / "workspace", organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            assert svc.ingest_file(music_path) is True
            organize_function.assert_called_once_with(music_path)

    def test_ingest_file__unsupported_extension__returns_false_and_does_not_organize(self, tmp_path: Path):
        path = tmp_path / "note.txt"
        path.write_text("hello")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=tmp_path / "workspace", organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        quick_check = MagicMock(return_value=True)

        with patch("app.services.ingestion.does_music_pass_quick_check", quick_check):
            assert svc.ingest_file(path) is False

            organize_function.assert_not_called()
            quick_check.assert_not_called()

    def test_ingest_file__music_file_fails_quick_check__returns_false_and_does_not_organize(self, tmp_path: Path):
        music_path = tmp_path / "song.mp3"
        music_path.write_bytes(b"fake")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=tmp_path / "workspace", organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=False):
            assert svc.ingest_file(music_path) is False
            organize_function.assert_not_called()

    def test_ingest_file__invalid_archive__returns_false_and_does_not_organize(self, tmp_path: Path):
        archive_path = tmp_path / "bad.zip"
        archive_path.write_bytes(b"not a zip")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=tmp_path / "workspace", organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        assert svc.ingest_file(archive_path) is False
        organize_function.assert_not_called()

    def test_ingest_file__archive_with_music_and_non_music__organizes_only_music(self, tmp_path: Path):
        archive_path = tmp_path / "complex.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("valid_music.mp3", "hello")
            z.writestr("dir1/valid_music.mp3", "world")
            z.writestr("dir1/dir2/valid_music.mp3", "foo")
            z.writestr("not_music.txt", "nope")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=workspace_dir, organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            assert svc.ingest_file(archive_path) is True

        # Review r1 DEV-M-10: the extraction dir is removed after handling, so
        # compare with the archive's audio members, not the workspace. Round 2:
        # each member is unpacked into a folder of its own (its position).
        called = sorted(
            call.args[0].relative_to(workspace_dir).as_posix().split("/", 1)[1]
            for call in organize_function.call_args_list
        )
        assert called == ["0/valid_music.mp3", "1/valid_music.mp3", "2/valid_music.mp3"]

    def test_ingest_file__archive_name_with_extra_dots__still_detected_as_archive(self, tmp_path: Path):
        archive_path = tmp_path / "my.album.v1.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("song.mp3", "hello")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=workspace_dir, organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            assert svc.ingest_file(archive_path) is True

        assert any(call.args[0].suffix.lower() in AUDIO_EXTENSIONS for call in organize_function.call_args_list)

    def test_ingest_file__archive_music_fails_quick_check__skips_bad_tracks(self, tmp_path: Path):
        archive_path = tmp_path / "mix.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("good.mp3", "good")
            z.writestr("bad.mp3", "bad")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=workspace_dir, organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        def quick_check_side_effect(p: Path) -> bool:
            return p.name != "bad.mp3"

        with patch(
            "app.services.ingestion.does_music_pass_quick_check", side_effect=quick_check_side_effect
        ):
            assert svc.ingest_file(archive_path) is True

        called_paths = {call.args[0].name for call in organize_function.call_args_list}
        assert called_paths == {"good.mp3"}

    def test_ingest_file__archive_with_no_music_files__returns_true_and_organizes_nothing(self, tmp_path: Path):
        archive_path = tmp_path / "no_music.zip"
        workspace_dir = tmp_path / "workspace"

        with zipfile.ZipFile(archive_path, "w") as z:
            z.writestr("readme.txt", "no songs here")

        organize_function = MagicMock()
        ctx = ingestion.IngestorContext(
            workspace_dir=workspace_dir, organize_function=organize_function
        )
        svc = ingestion.Ingestor(ctx)

        quick_check = MagicMock(return_value=True)
        with patch("app.services.ingestion.does_music_pass_quick_check", quick_check):
            assert svc.ingest_file(archive_path) is True

        organize_function.assert_not_called()
        quick_check.assert_not_called()



class TestHandledArchiveIsSetAside:
    """Review r1 m-R1-02, decision DEV-M-10: once an archive has been extracted
    and its contents handled, it moves to ``<import folder>/.imported/`` (same
    name, a numeric suffix on a clash) and its extraction directory leaves the
    workspace. An archive whose extraction or handling fails stays put.
    Changed by the sign-off of DEV-M-10 (2026-11-17): an archive whose every
    audio file was imported is deleted instead (test_import_archive_delete.py);
    ``.imported/`` keeps the ones with a refused track or no audio."""

    @staticmethod
    def _zip(path: Path, **members: str) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(path, "w") as z:
            for name, data in members.items():
                z.writestr(name, data)
        return path

    @staticmethod
    def _ingestor(workspace: Path, organize=None) -> ingestion.Ingestor:
        return ingestion.Ingestor(
            ingestion.IngestorContext(
                workspace_dir=workspace, organize_function=organize or MagicMock()
            )
        )

    def test_a_handled_archive_moves_to_imported_and_leaves_no_workspace_copy(self, tmp_path: Path):
        folder = tmp_path / "import-users" / "sam"
        archive = self._zip(folder / "Albums" / "album.zip",
                            **{"song.mp3": "a", "dup.mp3": "d", "notes.txt": "b"})
        workspace = tmp_path / "workspace"
        # One track refused for its own content: set aside, not deleted (DEV-M-10).
        organize = MagicMock(side_effect=lambda p: ImportOutcome.DUPLICATE if Path(p).name == "dup.mp3"
                             else ImportOutcome.IMPORTED)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            assert self._ingestor(workspace, organize).ingest_file(
                archive, imported_dir=folder / ".imported") is True

        assert not archive.exists()
        assert sorted(p.name for p in (folder / ".imported").iterdir()) == ["album.zip"]
        assert zipfile.ZipFile(folder / ".imported" / "album.zip").namelist() == ["song.mp3", "dup.mp3", "notes.txt"]
        assert list(workspace.iterdir()) == []

    def test_an_archive_with_nothing_importable_is_still_set_aside(self, tmp_path: Path):
        folder = tmp_path / "import"
        archive = self._zip(folder / "readme.zip", **{"readme.txt": "no songs"})
        workspace = tmp_path / "workspace"

        assert self._ingestor(workspace).ingest_file(archive, imported_dir=folder / ".imported") is True

        assert [p.name for p in (folder / ".imported").iterdir()] == ["readme.zip"]
        assert list(workspace.iterdir()) == []

    def test_a_name_clash_in_imported_keeps_both_archives(self, tmp_path: Path):
        folder = tmp_path / "import"
        earlier = self._zip(folder / ".imported" / "album.zip", **{"old.mp3": "old"})
        earlier_bytes = earlier.read_bytes()
        archive = self._zip(folder / "album.zip", **{"new.mp3": "new"})
        refused = MagicMock(return_value=ImportOutcome.DUPLICATE)  # set aside, not deleted (DEV-M-10)

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            assert self._ingestor(tmp_path / "ws", refused).ingest_file(
                archive, imported_dir=folder / ".imported") is True

        assert not archive.exists()
        names = sorted(p.name for p in (folder / ".imported").iterdir())
        assert len(names) == 2 and "album.zip" in names
        assert earlier.read_bytes() == earlier_bytes
        (moved,) = [folder / ".imported" / n for n in names if n != "album.zip"]
        assert moved.name.startswith("album") and ingestion.is_archive(moved)
        assert zipfile.ZipFile(moved).namelist() == ["new.mp3"]

    def test_an_archive_that_fails_to_extract_stays_where_it_is(self, tmp_path: Path):
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "broken.zip"
        archive.write_bytes(b"not a zip")
        workspace = tmp_path / "workspace"

        assert self._ingestor(workspace).ingest_file(archive, imported_dir=folder / ".imported") is False

        assert archive.read_bytes() == b"not a zip"
        assert not (folder / ".imported").exists()

    def test_an_archive_whose_handling_raises_stays_and_its_extraction_is_removed(self, tmp_path: Path):
        folder = tmp_path / "import"
        archive = self._zip(folder / "album.zip", **{"song.mp3": "a"})
        workspace = tmp_path / "workspace"
        organize = MagicMock(side_effect=OSError("disk full"))

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            with pytest.raises(OSError):
                self._ingestor(workspace, organize).ingest_file(archive, imported_dir=folder / ".imported")

        assert archive.exists()
        assert not (folder / ".imported").exists()
        assert list(workspace.iterdir()) == []


class TestAnEnvironmentalFailureKeepsTheArchive:
    """Review r2 m-R2-01 (amends DEV-M-10): an archive moves to ``.imported/``
    only when every member was imported or refused for a reason of its own.
    A member that failed for an environmental reason keeps the archive where
    it is (its extraction is still removed) so the next scan retries it, and
    the failure is logged once with the archive's name and the reason."""

    _zip = staticmethod(TestHandledArchiveIsSetAside._zip)
    _ingestor = staticmethod(TestHandledArchiveIsSetAside._ingestor)

    @staticmethod
    def _organize_by_name(outcomes: dict[str, ImportOutcome]):
        return MagicMock(side_effect=lambda p: outcomes[Path(p).name])

    @staticmethod
    def _archive_warnings(caplog, name):
        return [r for r in caplog.records if r.levelno >= logging.WARNING and name in r.getMessage()]

    @pytest.mark.parametrize(
        "failure",
        [ImportOutcome.DATABASE_ERROR, ImportOutcome.MOVE_FAILED, ImportOutcome.TOOL_UNAVAILABLE],
    )
    def test_an_environmental_member_failure_keeps_the_archive(self, tmp_path: Path, caplog, failure):
        folder = tmp_path / "import"
        archive = self._zip(folder / "album.zip", **{"a.mp3": "a", "b.mp3": "b"})
        before = archive.read_bytes()
        workspace = tmp_path / "workspace"
        organize = self._organize_by_name({"a.mp3": ImportOutcome.IMPORTED, "b.mp3": failure})

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            with caplog.at_level(logging.INFO):
                handled = self._ingestor(workspace, organize).ingest_file(
                    archive, imported_dir=folder / ".imported"
                )

        assert handled is False
        assert archive.read_bytes() == before
        assert not (folder / ".imported").exists()
        assert list(workspace.iterdir()) == []
        (warning,) = self._archive_warnings(caplog, "album.zip")
        assert failure.value in warning.getMessage()

    def test_a_member_whose_quick_check_cannot_answer_now_does_not_stop_the_others(
        self, tmp_path: Path, caplog
    ):
        """Review of U05-A-06 (finding 3): a quick check that times out on one
        member is that member's environmental outcome, like a metadata-probe
        time-out; the members after it are still tried and the archive is kept."""
        folder = tmp_path / "import"
        archive = self._zip(folder / "album.zip", **{"a.mp3": "a", "b.mp3": "b"})
        before = archive.read_bytes()
        organize = self._organize_by_name({"b.mp3": ImportOutcome.IMPORTED})

        def quick_check(path):
            if Path(path).name == "a.mp3":
                raise ingestion.ProbeUnavailable("ffprobe timed out")
            return True

        with patch("app.services.ingestion.does_music_pass_quick_check", quick_check):
            with caplog.at_level(logging.INFO):
                outcome = self._ingestor(tmp_path / "workspace", organize).ingest(
                    archive, imported_dir=folder / ".imported"
                )

        assert outcome is ImportOutcome.TOOL_UNAVAILABLE
        assert [Path(c.args[0]).name for c in organize.call_args_list] == ["b.mp3"]
        assert archive.read_bytes() == before
        assert not (folder / ".imported").exists()

    def test_members_refused_for_their_own_reasons_still_set_the_archive_aside(self, tmp_path: Path):
        folder = tmp_path / "import"
        archive = self._zip(folder / "album.zip", **{"a.mp3": "a", "b.mp3": "b", "c.mp3": "c"})
        organize = self._organize_by_name(
            {
                "a.mp3": ImportOutcome.IMPORTED,
                "b.mp3": ImportOutcome.DUPLICATE,
                "c.mp3": ImportOutcome.FAILS_CHECK,
            }
        )

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            assert self._ingestor(tmp_path / "ws", organize).ingest_file(
                archive, imported_dir=folder / ".imported"
            ) is True

        assert not archive.exists()
        assert [p.name for p in (folder / ".imported").iterdir()] == ["album.zip"]

    @pytest.mark.parametrize("error", [FileNotFoundError, PermissionError, BlockingIOError])
    def test_ffprobe_that_cannot_run_keeps_the_archive(self, tmp_path: Path, caplog, error):
        folder = tmp_path / "import"
        archive = self._zip(folder / "album.zip", **{"a.mp3": "a"})
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)

        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=error):
            with caplog.at_level(logging.INFO):
                handled = self._ingestor(tmp_path / "ws", organize).ingest_file(
                    archive, imported_dir=folder / ".imported"
                )

        assert handled is False
        organize.assert_not_called()
        assert archive.exists()
        assert not (folder / ".imported").exists()
        (warning,) = self._archive_warnings(caplog, "album.zip")
        assert ImportOutcome.TOOL_UNAVAILABLE.value in warning.getMessage()

    def test_a_loose_file_is_left_when_ffprobe_cannot_run(self, tmp_path: Path, caplog):
        song = tmp_path / "import" / "song.mp3"
        song.parent.mkdir(parents=True)
        song.write_bytes(b"audio")
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)

        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=FileNotFoundError):
            with caplog.at_level(logging.INFO):
                assert self._ingestor(tmp_path / "ws", organize).ingest_file(song) is False

        organize.assert_not_called()
        assert song.read_bytes() == b"audio"
        (warning,) = self._archive_warnings(caplog, "song.mp3")
        assert ImportOutcome.TOOL_UNAVAILABLE.value in warning.getMessage()


class TestAnArchiveThatChangesIsNotSetAside:
    """Review r2 m-R2-02 (decision DEV-M-14): the archive's size and
    modification time are re-checked after extraction and right before it is
    set aside. A change abandons the attempt: nothing is organized from a
    snapshot that was still growing, the archive stays, and a later attempt
    imports it whole."""

    _ingestor = staticmethod(TestHandledArchiveIsSetAside._ingestor)

    @staticmethod
    def _tar_bytes(tmp_path: Path, names):
        src = tmp_path / "tar-src"
        src.mkdir()
        path = tmp_path / "full.tar"
        with tarfile.open(path, "w") as tar:
            for name in names:
                member = src / name
                member.write_bytes(name.encode() * 300)
                tar.add(member, arcname=name)
        with tarfile.open(path) as tar:
            boundary = tar.getmembers()[1].offset
        return path.read_bytes(), boundary

    def test_a_tar_cut_at_an_entry_boundary_extracts_without_error(self, tmp_path: Path):
        """Why the re-check is needed: libarchive accepts the cut tar."""
        data, boundary = self._tar_bytes(tmp_path, ["a.mp3", "b.mp3", "c.mp3"])
        cut = tmp_path / "import" / "album.tar"
        cut.parent.mkdir()
        cut.write_bytes(data[:boundary])

        plan = import_archive.inspect(cut, tiny_limits(max_expanded_member_bytes=10**6,
                                                       max_expanded_bytes_per_batch=10**6))

        assert [m.name for m in plan.members] == ["a.mp3"]

    def test_a_tar_still_being_copied_is_neither_imported_from_nor_set_aside(self, tmp_path: Path):
        data, boundary = self._tar_bytes(tmp_path, ["a.mp3", "b.mp3", "c.mp3"])
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "album.tar"
        archive.write_bytes(data[:boundary])
        workspace = tmp_path / "ws"
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)
        real_inspect = import_archive.inspect

        def inspect_while_the_copy_goes_on(source, limits, **kw):
            plan = real_inspect(source, limits, **kw)
            with open(archive, "ab") as f:  # the writer appends the rest
                f.write(data[boundary:])
            return plan

        # The cut tar lacks its end marker (m-L-09); this test is about the
        # re-check after extraction, so the completeness check is passed.
        with (
            patch("app.services.ingestion.does_music_pass_quick_check", return_value=True),
            patch("app.services.ingestion.archive_is_complete", return_value=True),
            patch("app.services.import_archive.inspect", side_effect=inspect_while_the_copy_goes_on),
        ):
            outcome = self._ingestor(workspace, organize).ingest(archive, imported_dir=folder / ".imported")

        assert outcome is ImportOutcome.CHANGED
        organize.assert_not_called()
        assert archive.read_bytes() == data
        assert not (folder / ".imported").exists()
        assert list(workspace.iterdir()) == []

        # The next attempt (the watcher resubmits it) imports every member.
        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            outcome = self._ingestor(workspace, organize).ingest(archive, imported_dir=folder / ".imported")

        assert outcome is ImportOutcome.IMPORTED
        assert sorted(Path(c.args[0]).name for c in organize.call_args_list) == ["a.mp3", "b.mp3", "c.mp3"]
        assert not archive.exists() and not (folder / ".imported").exists()  # all imported: deleted

    def test_an_archive_that_changes_before_it_is_set_aside_stays(self, tmp_path: Path):
        folder = tmp_path / "import"
        archive = TestHandledArchiveIsSetAside._zip(folder / "album.zip", **{"a.mp3": "a"})

        def organize_while_the_archive_is_touched(path):
            with open(archive, "ab") as f:
                f.write(b"more")
            return ImportOutcome.IMPORTED

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            outcome = self._ingestor(tmp_path / "ws", MagicMock(side_effect=organize_while_the_archive_is_touched)).ingest(
                archive, imported_dir=folder / ".imported"
            )

        assert outcome is ImportOutcome.CHANGED
        assert archive.exists()
        assert not (folder / ".imported").exists()


def test_two_same_named_archives_set_aside_at_once_are_both_kept(tmp_path: Path):
    """Review r2 m-R2-06: ``Sam/A/album.zip`` and ``Sam/B/album.zip`` finish
    on two workers together. The probe for a free name and the move are one
    step, so neither replaces the other ("nothing is ever deleted")."""
    folder = tmp_path / "import-users" / "sam"
    first = TestHandledArchiveIsSetAside._zip(folder / "A" / "album.zip", **{"a.mp3": "A"})
    second = TestHandledArchiveIsSetAside._zip(folder / "B" / "album.zip", **{"b.mp3": "B"})
    imported = folder / ".imported"
    # Both moves wait at a barrier so, WITHOUT the product's lock, both would
    # have probed a free name before either moves (the race). With the lock the
    # second set-aside cannot reach its move; a spy lock sees it fail to take
    # the lock and breaks the barrier at once, so nothing waits out a timeout.
    both_probed = threading.Barrier(2, timeout=5)  # guard only
    real_rename = os.rename  # the set-aside's move (into the opened folder)
    real_lock = ingestion._imported_lock

    class SpyLock:
        def __enter__(self):
            if not real_lock.acquire(blocking=False):
                both_probed.abort()  # contended: serialized, release the holder
                real_lock.acquire()
            return self

        def __exit__(self, *exc):
            real_lock.release()

    def move_after_both_probed(src, dst, **kwargs):
        try:
            both_probed.wait()
        except threading.BrokenBarrierError:
            pass  # serialized: the other set-aside waits for this one
        return real_rename(src, dst, **kwargs)

    with patch.object(ingestion, "_imported_lock", SpyLock()), \
            patch("app.services.ingestion.os.rename", side_effect=move_after_both_probed):
        threads = [
            threading.Thread(target=ingestion.move_to_imported, args=(archive, imported))
            for archive in (first, second)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(10)

    kept = sorted(imported.iterdir())
    assert len(kept) == 2
    assert sorted(zipfile.ZipFile(p).namelist()[0] for p in kept) == ["a.mp3", "b.mp3"]


class TestAnIncompleteArchiveIsKept:
    """Live gate m-L-09: a tar copied with a pause exactly at an entry boundary
    looks like a whole, shorter tar to libarchive. A tar (plain, or inside a
    gzip) is complete only when it ends with its end-of-archive marker (two
    zero blocks); without it the archive is not extracted and not set aside
    (``archive kept (incomplete)``) and a later attempt imports it whole.
    Deterministic: no timing is involved."""

    _ingestor = staticmethod(TestHandledArchiveIsSetAside._ingestor)

    @staticmethod
    def _tar(tmp_path: Path, names):
        """(bytes of a complete tar, offset of the second member's header)."""
        import io

        path = tmp_path / "full.tar"
        with tarfile.open(path, "w") as tar:
            for name in names:
                data = name.encode() * 300
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        with tarfile.open(path) as tar:
            boundary = tar.getmembers()[1].offset
        return path.read_bytes(), boundary

    @staticmethod
    def _members_seen(organize):
        return sorted(Path(c.args[0]).name for c in organize.call_args_list)

    def _attempt(self, archive: Path, workspace: Path, organize, caplog):
        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            with caplog.at_level(logging.INFO):
                return self._ingestor(workspace, organize).ingest(
                    archive, imported_dir=archive.parent / ".imported"
                )

    @pytest.mark.parametrize(
        "cut",
        ["at_entry_boundary", "after_one_end_block", "mid_header", "mid_data"],
    )
    def test_a_tar_without_its_end_marker_is_kept_and_later_imported_whole(
        self, tmp_path: Path, caplog, cut
    ):
        data, boundary = self._tar(tmp_path, ["a.mp3", "b.mp3"])
        end = len(data.rstrip(b"\0"))
        end += -end % 512  # first end-of-archive block
        offset = {
            "at_entry_boundary": boundary,
            "after_one_end_block": end + 512,  # one zero block of the two
            "mid_header": boundary + 100,
            "mid_data": boundary + 512 + 100,
        }[cut]
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "album.tar"
        archive.write_bytes(data[:offset])
        workspace = tmp_path / "ws"
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)
        extract = MagicMock(side_effect=import_archive.inspect)

        with patch("app.services.import_archive.inspect", extract):
            outcome = self._attempt(archive, workspace, organize, caplog)

        assert outcome is ImportOutcome.INCOMPLETE
        assert outcome.value == "incomplete"
        assert not outcome.belongs_to_file
        extract.assert_not_called()
        organize.assert_not_called()
        assert archive.read_bytes() == data[:offset]
        assert not (folder / ".imported").exists()
        assert not workspace.exists() or list(workspace.iterdir()) == []
        kept = [r.getMessage() for r in caplog.records if "album.tar" in r.getMessage()]
        assert kept == [f"archive kept: {archive} (incomplete)"]

        # The writer resumes; the next attempt (modify event or scan) imports it whole.
        with open(archive, "ab") as f:
            f.write(data[offset:])
        assert self._attempt(archive, workspace, organize, caplog) is ImportOutcome.IMPORTED
        assert self._members_seen(organize) == ["a.mp3", "b.mp3"]
        assert not archive.exists() and not (folder / ".imported").exists()  # all imported: deleted

    def test_a_tar_with_its_end_marker_but_no_record_padding_is_complete(self, tmp_path: Path, caplog):
        data, _ = self._tar(tmp_path, ["a.mp3", "b.mp3"])
        end = len(data.rstrip(b"\0"))
        end += -end % 512
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "album.tar"
        archive.write_bytes(data[: end + 1024])  # two zero blocks, no padding to 10 KiB
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)

        assert self._attempt(archive, tmp_path / "ws", organize, caplog) is ImportOutcome.IMPORTED
        assert self._members_seen(organize) == ["a.mp3", "b.mp3"]

    def test_a_gzip_of_a_tar_cut_at_an_entry_boundary_is_kept(self, tmp_path: Path, caplog):
        import gzip

        data, boundary = self._tar(tmp_path, ["a.mp3", "b.mp3"])
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "album.tar.gz"
        archive.write_bytes(gzip.compress(data[:boundary]))
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)

        assert self._attempt(archive, tmp_path / "ws", organize, caplog) is ImportOutcome.INCOMPLETE
        organize.assert_not_called()
        assert archive.exists() and not (folder / ".imported").exists()

        archive.write_bytes(gzip.compress(data))
        assert self._attempt(archive, tmp_path / "ws", organize, caplog) is ImportOutcome.IMPORTED
        assert self._members_seen(organize) == ["a.mp3", "b.mp3"]

    def test_a_truncated_gzip_fails_on_its_trailer(self, tmp_path: Path):
        """Why a cut .tar.gz copy can't pass as complete: the gzip stream
        itself is short (no trailer), so libarchive refuses it."""
        import gzip

        data, _ = self._tar(tmp_path, ["a.mp3", "b.mp3"])
        whole = gzip.compress(data)
        for cut in (len(whole) - 1, len(whole) - 8, len(whole) // 2):
            archive = tmp_path / f"cut{cut}.tar.gz"
            archive.write_bytes(whole[:cut])
            organize = MagicMock(return_value=ImportOutcome.IMPORTED)
            assert self._ingestor(tmp_path / "ws", organize).ingest(archive) is ImportOutcome.REFUSED
            organize.assert_not_called()

    def test_a_zip_cut_at_a_member_boundary_fails_without_its_central_directory(self, tmp_path: Path):
        """Why a cut .zip copy can't pass as complete: libarchive reads a zip
        through its central directory, written last; without it the zip fails
        to extract (refused, kept). A zip whose central directory is whole
        lists every member, so nothing can be lost. (Since sign-off DEV-7-14 the
        shared ZIP inspection reads it, and refuses it as invalid.)"""
        whole = tmp_path / "whole.zip"
        with zipfile.ZipFile(whole, "w") as z:
            z.writestr("a.mp3", "a" * 3000)
            z.writestr("b.mp3", "b" * 3000)
        with zipfile.ZipFile(whole) as z:
            boundary = z.infolist()[1].header_offset
        data = whole.read_bytes()
        central = data.find(b"PK\x01\x02")
        for cut in (boundary, central):
            archive = tmp_path / f"cut{cut}.zip"
            archive.write_bytes(data[:cut])
            organize = MagicMock(return_value=ImportOutcome.IMPORTED)
            assert self._ingestor(tmp_path / "ws", organize).ingest(archive) is ImportOutcome.REFUSED
            organize.assert_not_called()


class TestAnIncompleteRarIsKept:
    """Live gate m-L-09, the same rule for RAR: libarchive reads a RAR (RAR5
    and RAR 2.9-4.x) cut at a member boundary as a shorter archive, and one
    without its end-of-archive header as complete. A RAR is complete only
    when its headers walk to the end-of-archive header."""

    _attempt = TestAnIncompleteArchiveIsKept._attempt
    _members_seen = staticmethod(TestAnIncompleteArchiveIsKept._members_seen)
    _ingestor = staticmethod(TestHandledArchiveIsSetAside._ingestor)

    _MEMBERS = [("a.mp3", b"a" * 3000), ("b.mp3", b"b" * 3000)]

    @pytest.mark.parametrize("build", [_rar5, _rar4], ids=["rar5", "rar4"])
    def test_libarchive_takes_a_rar_cut_at_a_member_boundary_as_whole(self, tmp_path: Path, build):
        """Why the check is needed."""
        data, offsets, _ = build(self._MEMBERS)
        cut = tmp_path / "cut.rar"
        cut.write_bytes(data[: offsets[1]])

        plan = import_archive.inspect(cut, tiny_limits(max_expanded_member_bytes=10**6,
                                                       max_expanded_bytes_per_batch=10**6))

        assert [m.name for m in plan.members] == ["a.mp3"]

    @pytest.mark.parametrize("build", [_rar5, _rar4], ids=["rar5", "rar4"])
    @pytest.mark.parametrize("cut", ["at_member_boundary", "without_end_header", "mid_member"])
    def test_a_rar_without_its_end_header_is_kept_and_later_imported_whole(
        self, tmp_path: Path, caplog, build, cut
    ):
        data, offsets, end = build(self._MEMBERS)
        offset = {
            "at_member_boundary": offsets[1],
            "without_end_header": end,
            "mid_member": offsets[1] + 100,
        }[cut]
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "album.rar"
        archive.write_bytes(data[:offset])
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)
        extract = MagicMock(side_effect=import_archive.inspect)

        with patch("app.services.import_archive.inspect", extract):
            outcome = self._attempt(archive, tmp_path / "ws", organize, caplog)

        assert outcome is ImportOutcome.INCOMPLETE
        extract.assert_not_called()
        organize.assert_not_called()
        assert archive.read_bytes() == data[:offset]
        assert not (folder / ".imported").exists()

        with open(archive, "ab") as f:
            f.write(data[offset:])
        assert self._attempt(archive, tmp_path / "ws", organize, caplog) is ImportOutcome.IMPORTED
        assert self._members_seen(organize) == ["a.mp3", "b.mp3"]
        assert not archive.exists() and not (folder / ".imported").exists()  # all imported: deleted

    def test_a_file_named_rar_that_is_not_one_is_refused(self, tmp_path: Path, caplog):
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "album.rar"
        archive.write_bytes(b"not a rar at all" * 10)
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)

        assert self._attempt(archive, tmp_path / "ws", organize, caplog) is ImportOutcome.REFUSED
        assert archive.exists()


class TestTheCompletenessCheckOnMalformedArchives:
    """Review r3 m-R3-04: the check reads sizes from a file that may be
    corrupt or crafted (a friend can drop anything into their import folder).
    It never allocates what a header claims beyond a small fixed bound, and it
    never raises: a malformed archive is answered like any invalid one, kept
    where it is (not imported, not set aside) with an outcome."""

    _attempt = TestAnIncompleteArchiveIsKept._attempt
    _ingestor = staticmethod(TestHandledArchiveIsSetAside._ingestor)

    @staticmethod
    def _rar5_with_first_header_size(size_vint: bytes) -> bytes:
        return b"Rar!\x1a\x07\x01\x00" + b"\0\0\0\0" + size_vint

    @staticmethod
    def _assert_kept(archive: Path, before: bytes, outcome: ImportOutcome):
        assert outcome is not ImportOutcome.IMPORTED
        assert archive.read_bytes() == before
        assert not (archive.parent / ".imported").exists()

    def test_a_rar_header_claiming_a_huge_size_is_not_read_into_memory(self, tmp_path: Path, caplog):
        import tracemalloc

        claimed = 64 * 1024 * 1024
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "huge.rar"
        archive.write_bytes(self._rar5_with_first_header_size(_rar_vint(claimed)))
        with open(archive, "r+b") as f:
            f.truncate(claimed + 4096)  # sparse: the claimed bytes "exist"

        tracemalloc.start()
        try:
            ingestion.archive_is_complete(archive)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()
        assert peak < 8 * 1024 * 1024, f"the check allocated {peak} bytes"

        organize = MagicMock(return_value=ImportOutcome.IMPORTED)
        outcome = self._attempt(archive, tmp_path / "ws", organize, caplog)
        organize.assert_not_called()
        assert outcome is not ImportOutcome.IMPORTED
        assert archive.exists()
        assert not (folder / ".imported").exists()

    def test_a_rar_header_size_beyond_any_integer_does_not_raise(self, tmp_path: Path, caplog):
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "vint.rar"
        archive.write_bytes(self._rar5_with_first_header_size(b"\xff" * 9 + b"\x01") + b"x" * 64)
        before = archive.read_bytes()

        assert isinstance(ingestion.archive_is_complete(archive), bool)
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)
        self._assert_kept(archive, before, self._attempt(archive, tmp_path / "ws", organize, caplog))
        organize.assert_not_called()

    @pytest.mark.parametrize("flip", [20, 25, 30, 35])
    def test_a_gzip_with_corrupt_data_does_not_raise(self, tmp_path: Path, caplog, flip):
        import gzip
        import io

        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            data = (b"abcdefgh" * 3 + bytes(range(256))) * 800
            info = tarfile.TarInfo("a.mp3")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        raw = bytearray(gzip.compress(buf.getvalue(), mtime=0))
        raw[flip] ^= 0xFF
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "corrupt.tar.gz"
        archive.write_bytes(bytes(raw))

        assert isinstance(ingestion.archive_is_complete(archive), bool)
        organize = MagicMock(return_value=ImportOutcome.IMPORTED)
        self._assert_kept(archive, bytes(raw), self._attempt(archive, tmp_path / "ws", organize, caplog))
        organize.assert_not_called()

    def test_any_error_while_walking_the_archive_is_not_raised(self, tmp_path: Path):
        archive = tmp_path / "odd.tar"
        archive.write_bytes(bytes(1024))
        with patch.object(ingestion, "_tar_is_complete", side_effect=ValueError("odd")):
            assert isinstance(ingestion.archive_is_complete(archive), bool)



class TestMetadataProbeThatCannotStart:
    """Review r3 m-R3-05 (the open part of m-R2-01): the organizer's own
    ffprobe (the metadata read) failing to start is environmental, like the
    quick check's: ``tool_unavailable``, never the file's own refusal. An
    archive with such a member is kept for the next attempt, not set aside."""

    _zip = staticmethod(TestHandledArchiveIsSetAside._zip)
    _ingestor = staticmethod(TestHandledArchiveIsSetAside._ingestor)

    @staticmethod
    def _organizer(library: Path):
        from app.services import organizer

        add = MagicMock(return_value=True)
        return organizer.Organizer(
            organizer.OrganizerContext(
                music_library_dir=library,
                should_organize_files=True,
                should_copy_files=False,
                add_to_database=add,
            )
        ), add

    @pytest.mark.parametrize("error", [BlockingIOError, PermissionError, FileNotFoundError])
    def test_the_organizer_reports_tool_unavailable(self, tmp_path: Path, error):
        song = tmp_path / "import" / "song.mp3"
        song.parent.mkdir(parents=True)
        song.write_bytes(b"audio")
        org, add = self._organizer(tmp_path / "library")

        with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=error):
            outcome = org.organize(song)

        assert outcome is ImportOutcome.TOOL_UNAVAILABLE
        assert song.read_bytes() == b"audio"
        add.assert_not_called()

    def test_an_archive_whose_member_cannot_be_probed_is_kept(self, tmp_path: Path, caplog):
        folder = tmp_path / "import"
        archive = self._zip(folder / "album.zip", **{"a.mp3": "a"})
        before = archive.read_bytes()
        org, add = self._organizer(tmp_path / "library")

        with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
            with patch("app.services.ffmpeg_runner.subprocess.Popen", side_effect=BlockingIOError):
                with caplog.at_level(logging.INFO):
                    outcome = self._ingestor(tmp_path / "ws", org.organize).ingest(
                        archive, imported_dir=folder / ".imported"
                    )

        assert outcome is ImportOutcome.TOOL_UNAVAILABLE
        assert archive.read_bytes() == before
        assert not (folder / ".imported").exists()
        add.assert_not_called()
        warnings = [r.getMessage() for r in caplog.records if "album.zip" in r.getMessage()]
        assert warnings == [f"archive kept: {archive} (tool_unavailable)"]


class TestTheCompletenessCheckIsBounded:
    """Review r1 #3 (s7-import-archives): the tar completeness check runs
    before the inspection. It must not decompress more than the ratio allows,
    it stops when the server stops, and an archive refused before (unchanged)
    is not checked again."""

    @staticmethod
    def _tar_of_zeros(size: int, *, end_marker: bool) -> bytes:
        import io

        info = tarfile.TarInfo("zeros.txt")
        info.size = size
        data = info.tobuf(format=tarfile.USTAR_FORMAT) + bytes(size) + bytes(-size % 512)
        return data + (bytes(1024) if end_marker else b"")

    class _Counting:
        def __init__(self, data: bytes):
            import io

            self._f = io.BytesIO(data)
            self.read_bytes = 0

        def read(self, n=-1):
            block = self._f.read(n)
            self.read_bytes += len(block)
            return block

    def test_the_walk_stops_at_the_byte_budget_and_lets_the_inspection_decide(self):
        f = self._Counting(self._tar_of_zeros(8 * 1024 * 1024, end_marker=False))

        assert ingestion._tar_is_complete(f, max_bytes=1024 * 1024) is True
        assert f.read_bytes <= 2 * 1024 * 1024 + 512

    def test_without_a_budget_the_walk_reads_to_the_end(self):
        f = self._Counting(self._tar_of_zeros(3 * 1024 * 1024, end_marker=False))

        assert ingestion._tar_is_complete(f) is False
        assert f.read_bytes >= 3 * 1024 * 1024

    def test_the_walk_stops_when_the_server_stops(self):
        f = self._Counting(self._tar_of_zeros(8 * 1024 * 1024, end_marker=True))

        assert ingestion._tar_is_complete(f, should_stop=lambda: True) is False
        assert f.read_bytes <= 1024 * 1024 + 512

    @staticmethod
    def _ingestor(workspace: Path, organize=None):
        from app.services.import_archive import ArchiveUnpacker

        return ingestion.Ingestor(ingestion.IngestorContext(
            workspace_dir=workspace, organize_function=organize or MagicMock(),
            archives=ArchiveUnpacker(owner_id=1, ledger=None, limits=lambda: tiny_limits())))

    def test_a_gzip_bomb_still_being_copied_is_refused_by_its_ratio(self, tmp_path: Path):
        """Without the budget the walk would inflate it all and call it
        incomplete (kept, and inflated again at every start)."""
        import gzip

        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "bomb.tar.gz"
        archive.write_bytes(gzip.compress(self._tar_of_zeros(4 * 1024 * 1024, end_marker=False)))

        assert self._ingestor(tmp_path / "ws").ingest(archive) is ImportOutcome.REFUSED

    def test_an_unchanged_refused_archive_is_not_checked_for_completeness_again(self, tmp_path: Path):
        folder = tmp_path / "import"
        folder.mkdir()
        archive = folder / "five.tar"
        with tarfile.open(archive, "w") as t:
            import io

            for i in range(5):  # tiny_limits: at most 4 audio files
                info = tarfile.TarInfo(f"{i}.mp3")
                info.size = 3
                t.addfile(info, io.BytesIO(b"abc"))
        ingestor = self._ingestor(tmp_path / "ws")
        check = MagicMock(side_effect=ingestion.archive_is_complete)

        with patch("app.services.ingestion.archive_is_complete", check):
            assert ingestor.ingest(archive) is ImportOutcome.REFUSED
            assert ingestor.ingest(archive) is ImportOutcome.REFUSED

        assert check.call_count == 1


def test_the_completeness_walk_caps_the_number_of_headers():
    """Review re-check r1 #2: 2M empty headers took 7.8 s here."""
    raw = b"".join(tarfile.TarInfo(f"{i}.txt").tobuf(format=tarfile.USTAR_FORMAT) for i in range(100))
    f = TestTheCompletenessCheckIsBounded._Counting(raw)

    assert ingestion._tar_is_complete(f, max_headers=10) is True
    assert f.read_bytes <= 11 * 512


# --- U05-A-06: the two ingest probes are bounded, and a stop ends them ----------


@pytest.mark.integration
class TestTheIngestProbesAreBounded:
    """A fake ffprobe that never answers: each ingest probe comes back within
    the bound as "unreadable for now" (TOOL_UNAVAILABLE, environmental: the
    file stays for the next scan), never as the file's own refusal. The
    pipeline hands both probes the identity registry, so closing it at
    shutdown ends a probe without waiting out the bound."""

    @pytest.fixture(autouse=True)
    def _hanging(self, monkeypatch, tmp_path):
        from tests import hanging_ffprobe

        hanging_ffprobe.install(monkeypatch, tmp_path)
        self.monkeypatch = monkeypatch
        self.song = tmp_path / "import" / "song.mp3"
        self.song.parent.mkdir(parents=True)
        self.song.write_bytes(b"audio")

    def _pipeline(self, tmp_path, registry=None):
        from app.database import DatabaseContext
        from app.services.cover_art_manager import CoverArtContext, CoverArtManager
        from app.services.pipeline import make_pipeline
        from tests.owned_database import OwnedTestDatabase
        from tests.schema_fixtures import INIT_SQL

        db = OwnedTestDatabase(
            DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
        )
        assert db.initialize()
        manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
        organizer, ingestor = make_pipeline(
            db.get_user(db.owner_id), database=db, cover_art_manager=manager,
            music_library_dir=tmp_path / "music", workspace_root=tmp_path / "workspace",
            identity_registry=registry,
        )
        return db, organizer, ingestor

    def test_a_hung_quick_check_is_unavailable_for_now_within_the_bound(self):
        from tests.hanging_ffprobe import WITHIN_S, shorten_bound, timed

        shorten_bound(self.monkeypatch)
        with timed() as elapsed:
            with pytest.raises(ingestion.ProbeUnavailable) as raised:
                ingestion.does_music_pass_quick_check(self.song)

        assert elapsed() < WITHIN_S
        assert "not found" not in str(raised.value)

    def test_a_hung_metadata_probe_leaves_the_file_for_the_next_scan(self, tmp_path):
        from tests.hanging_ffprobe import WITHIN_S, shorten_bound, timed

        shorten_bound(self.monkeypatch)
        db, organizer, _ = self._pipeline(tmp_path)
        with timed() as elapsed:
            outcome = organizer.organize(self.song)

        assert elapsed() < WITHIN_S
        assert outcome is ImportOutcome.TOOL_UNAVAILABLE
        assert self.song.read_bytes() == b"audio"
        assert db.get_tracks(owner_id=db.owner_id) == []

    def test_a_closed_registry_ends_the_quick_check_without_waiting_out_the_bound(self, tmp_path):
        from app.services.ffmpeg_runner import FfmpegProcessRegistry
        from tests.hanging_ffprobe import WITHIN_S, timed

        registry = FfmpegProcessRegistry()
        registry.close()  # shutdown: every probe started from now on is killed
        _, _, ingestor = self._pipeline(tmp_path, registry)
        with timed() as elapsed:
            outcome = ingestor.ingest(self.song)

        assert elapsed() < WITHIN_S
        assert outcome is ImportOutcome.TOOL_UNAVAILABLE
        assert self.song.read_bytes() == b"audio"

    def test_a_closed_registry_ends_the_metadata_probe_without_waiting_out_the_bound(self, tmp_path):
        from app.services.ffmpeg_runner import FfmpegProcessRegistry
        from tests.hanging_ffprobe import WITHIN_S, timed

        registry = FfmpegProcessRegistry()
        registry.close()
        db, organizer, _ = self._pipeline(tmp_path, registry)
        with timed() as elapsed:
            outcome = organizer.organize(self.song)

        assert elapsed() < WITHIN_S
        assert outcome is ImportOutcome.TOOL_UNAVAILABLE
        assert self.song.read_bytes() == b"audio"
        assert db.get_tracks(owner_id=db.owner_id) == []
