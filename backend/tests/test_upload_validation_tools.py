"""7A.2c S12 (exit proof: "a retagged copy → exact"; "process tests carry
`-m requires_ffmpeg` / `requires_fpcalc`"): the validation worker with the
real probe and the real identity computation. Tiny generated audio only."""

import shutil
import subprocess

import pytest

from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version
from app.services.job_runtime import CancelTokens
from app.services.upload_validation import UploadValidationWorker
from tests.identity_worker_fixtures import make_db
from tests.upload_validation_fixtures import BOOT, item_row, report_of, stage_item


def _ff(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *args], check=True)


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


def _real_worker(db, root, fingerprinter=None):
    return UploadValidationWorker(db, uploads_root=root, boot_id=BOOT, tokens=CancelTokens(),
                                  registry=FfmpegProcessRegistry(), fingerprinter=fingerprinter)


@pytest.mark.requires_ffmpeg
def test_a_retagged_copy_of_a_staged_flac_is_an_exact_match(db, root, tmp_path):
    original, retagged = tmp_path / "a.flac", tmp_path / "b.flac"
    _ff("-f", "lavfi", "-i", "anoisesrc=color=pink:seed=3:sample_rate=44100:duration=1",
        "-metadata", "title=First", "-c:a", "flac", str(original))
    _ff("-i", str(original), "-metadata", "title=Retagged", "-c", "copy", str(retagged))
    assert original.read_bytes() != retagged.read_bytes()  # different files, same audio
    first = stage_item(db, root, content=original.read_bytes(), progress_at=1)
    later = stage_item(db, root, content=retagged.read_bytes(), progress_at=2)
    worker = _real_worker(db, root)

    worker.process_one()
    worker.process_one()

    assert item_row(db, later)["state"] == "review_ready"
    assert [(m["ref"], m["id"], m["kind"]) for m in report_of(db, later)["matches"]] == [
        ("staged_item", first["item_uuid"], "exact"),
    ]
    assert report_of(db, later)["fingerprint"]["subject_state"] == "unavailable"


@pytest.mark.requires_ffmpeg
def test_bytes_that_are_not_audio_fail_as_invalid_audio(db, root):
    staged = stage_item(db, root, content=b"definitely not audio" * 64)

    _real_worker(db, root).process_one()

    assert (item_row(db, staged)["state"], item_row(db, staged)["error_code"]) == ("failed", "upload_invalid_audio")


@pytest.mark.requires_ffmpeg
@pytest.mark.requires_fpcalc
def test_with_the_fingerprint_tool_the_layer_is_computed(db, root, tmp_path):
    clip = tmp_path / "clip.flac"
    _ff("-f", "lavfi", "-i", "anoisesrc=color=pink:seed=5:sample_rate=44100:duration=1", "-c:a", "flac", str(clip))
    staged = stage_item(db, root, content=clip.read_bytes())
    exe = shutil.which("fpcalc")
    fingerprinter = FpcalcFingerprinter(exe, probe_fpcalc_version(exe), timeout_s=30)

    _real_worker(db, root, fingerprinter=fingerprinter).process_one()

    assert item_row(db, staged)["state"] == "review_ready"
    # The tool ran: a computed class (a 1 s clip is too short), never "unavailable".
    assert report_of(db, staged)["fingerprint"]["subject_state"] in ("current", "too_short", "low_information")
