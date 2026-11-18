"""Refactor BE-TOOLS, characterization: what the tool runners receive.

One representative call per module that starts ffmpeg, ffprobe or fpcalc,
with the real tools. Each test pins the command, the time limit, the stdout
cap or output file, the kill registry, the job id and the low-priority flag of
every runner call, in the order made (``tests/tool_call_capture.py`` reads the
options from whichever form they travel in). Written green on the code before
the options became one value; the refactor must leave every record as it is.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

import tests.conversion_fixtures as conv
from app.services import audio_identity, metadata, transcoder, upload_recovery
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version
from app.services.ingestion import does_music_pass_quick_check
from app.services.job_runtime import CancelTokens
from app.services.upload_validation import UploadValidationWorker, probe_upload
from tests.identity_worker_fakes import make_worker as make_identity_worker
from tests.identity_worker_fixtures import add_track, make_db
from tests.sqlite_helpers import sql_dicts
from tests.identity_conversion_fixtures import _settled
from tests.tool_call_capture import ToolCalls, choices

pytestmark = pytest.mark.requires_ffmpeg

PROBE_STREAM_FIELDS = "stream=sample_rate,channels,bits_per_raw_sample,bits_per_sample"
WHITELIST_FLAC = ["-protocol_whitelist", "file", "-f", "flac"]


def _flac(path, title="Orig", seconds=1):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
         f"anoisesrc=color=pink:seed=5:sample_rate=22050:duration={seconds}",
         "-metadata", f"title={title}", "-c:a", "flac", str(path)],
        check=True,
    )
    return path


def _fpcalc():
    exe = shutil.which("fpcalc")
    return FpcalcFingerprinter(exe, probe_fpcalc_version(exe), timeout_s=30)


def _probe(path_text, *, registry=None, job_id=None, low_priority=False, forced=()):
    return ("audio_identity.run_capture",
            ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", PROBE_STREAM_FIELDS,
             "-of", "json", *forced, path_text],
            ("timeout_s", 30, "max_stdout_bytes", 65536), registry, job_id, low_priority)


def _hash(path_text, *, registry=None, job_id=None, low_priority=False, forced=()):
    return ("audio_identity.run_capture",
            ["ffmpeg", "-v", "error", *forced, "-i", path_text, "-map", "0:a:0",
             "-c:a", "pcm_s32le", "-f", "hash", "-hash", "sha256", "-"],
            ("timeout_s", 30, "max_stdout_bytes", 4096), registry, job_id, low_priority)


def _version(*, registry=None, job_id=None, low_priority=False):
    return ("audio_identity.run_capture", ["ffmpeg", "-version"],
            ("timeout_s", 10, "max_stdout_bytes", 16384), registry, job_id, low_priority)


def _fpcalc_run(path_text, *, registry=None, job_id=None, low_priority=False, forced=()):
    return ("fingerprinter.run_capture",
            ["fpcalc", "-raw", "-json", "-algorithm", "2", "-length", "120", *forced, path_text],
            ("timeout_s", 30, "max_stdout_bytes", 24064), registry, job_id, low_priority)


def _metadata_probe(path_text, *, registry=None, job_id=None, forced=()):
    return ("metadata.run_capture",
            ["ffprobe", "-v", "error", "-hide_banner", "-show_streams", "-show_format", "-of", "json",
             *forced, path_text],
            ("timeout_s", 30, "max_stdout_bytes", 16777216), registry, job_id, False)


# --- audio_identity, fingerprinter -----------------------------------------------------


@pytest.mark.requires_fpcalc
def test_audio_identity_compute_identity(tmp_path, monkeypatch):
    path = _flac(tmp_path / "a.flac", seconds=10)
    tool = _fpcalc()
    registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})

    audio_identity.compute_identity(
        path, "flac", fingerprinter=tool,
        **choices(registry=registry, job_id="j1", low_priority=True, input_format="flac"))

    run = dict(registry="R", job_id="j1", low_priority=True)
    assert calls.records == [
        _probe("<tmp>/a.flac", forced=WHITELIST_FLAC, **run),
        _hash("<tmp>/a.flac", forced=WHITELIST_FLAC, **run),
        _fpcalc_run("<tmp>/a.flac", forced=["-format", "flac"], **run),
        _version(**run),
    ]


def test_audio_identity_strict_decode_and_its_retry(tmp_path, monkeypatch):
    path = _flac(tmp_path / "a.flac")
    registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})
    size = path.stat().st_size

    audio_identity.check_strict_decode(path, **choices(registry=registry, job_id=4, low_priority=True))
    audio_identity.check_strict_decode(
        path, audio_end=size, **choices(registry=registry, job_id=4, low_priority=True))

    strict = ["ffmpeg", "-v", "error", "-nostdin", "-err_detect", "crccheck+explode",
              "-max_error_rate", "0"]
    tail = ["-map", "0:a:0", "-f", "null", "-"]
    assert calls.records == [
        ("audio_identity.run_capture", [*strict, "-i", "<tmp>/a.flac", *tail],
         ("timeout_s", 30, "max_stdout_bytes", 4096), "R", 4, True),
        ("audio_identity.run_capture",
         [*strict, "-progress", "pipe:1", "-nostats", "-i",
          f"subfile,,start,0,end,{size},,:file:<tmp>/a.flac", *tail],
         ("timeout_s", 30, "max_stdout_bytes", 1048576), "R", 4, True),
    ]


def test_audio_identity_decoded_duration(tmp_path, monkeypatch):
    path = _flac(tmp_path / "a.flac")
    calls = ToolCalls(monkeypatch, tmp_path)

    audio_identity.measure_decoded_duration(path, **choices(job_id=2, input_format="flac"))

    assert calls.records == [
        ("audio_identity.run_capture",
         ["ffmpeg", "-v", "error", "-nostdin", "-progress", "pipe:1", "-nostats", *WHITELIST_FLAC,
          "-i", "<tmp>/a.flac", "-map", "0:a:0", "-f", "null", "-"],
         ("timeout_s", 30, "max_stdout_bytes", 1048576), None, 2, False),
    ]


@pytest.mark.requires_fpcalc
def test_fingerprinter_fingerprint(tmp_path, monkeypatch):
    path = _flac(tmp_path / "a.flac", seconds=10)
    tool = _fpcalc()
    registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})

    tool.fingerprint(path, **choices(registry=registry, job_id="f", low_priority=True))

    assert calls.records == [_fpcalc_run("<tmp>/a.flac", registry="R", job_id="f", low_priority=True)]


# --- metadata, transcoder, ingestion ---------------------------------------------------


def test_metadata_tag_write_and_registered_probe(tmp_path, monkeypatch):
    source = _flac(tmp_path / "a.flac")
    registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})

    metadata.write_metadata_tags(
        source, tmp_path / "b.flac", {"title": "New"},
        **choices(registry=registry, job_id=5, input_format="flac"))
    with metadata.probes_killed_by(registry):
        metadata.ffprobe_for_metadata(source)

    assert calls.records == [
        ("metadata.run_ffmpeg",
         ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *WHITELIST_FLAC, "-i", "<tmp>/a.flac",
          "-map", "0", "-c", "copy", "-map_metadata", "0", "-metadata", "title=New", "<tmp>/b.flac"],
         ("timeout", 30, "output", "<tmp>/b.flac"), "R", 5, False),
        _metadata_probe("<tmp>/b.flac", forced=WHITELIST_FLAC),
        _metadata_probe("<tmp>/a.flac", registry="R", job_id="<object>"),
    ]


def test_transcoder_transcode(tmp_path, monkeypatch):
    source = _flac(tmp_path / "a.flac")
    registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})

    result = transcoder.transcode(
        source, tmp_path / "b.m4a", "aac", 128, strip_video=True, **choices(registry=registry, job_id=9))

    assert result.ok
    assert calls.records == [
        ("transcoder.run_ffmpeg",
         ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", "<tmp>/a.flac", "-vn",
          "-c:a", "aac", "-f", "mp4", "-movflags", "+faststart", "-b:a", "128k", "<tmp>/b.m4a.partial"],
         ("timeout", 30, "output", "<tmp>/b.m4a.partial"), "R", 9, False),
    ]


def test_ingestion_quick_check(tmp_path, monkeypatch):
    source = _flac(tmp_path / "a.flac")
    registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})

    with metadata.probes_killed_by(registry):
        assert does_music_pass_quick_check(source)

    assert calls.records == [
        ("ingestion.run_capture",
         ["ffprobe", "-v", "error", "-select_streams", "a", "-hide_banner", "-show_entries",
          "stream=codec_type", "-read_intervals", "0%+#20", "-of", "json", "<tmp>/a.flac"],
         ("timeout_s", 30, "max_stdout_bytes", 65536), "R", "<object>", False),
    ]


# --- pipeline, identity worker ----------------------------------------------------------


def test_pipeline_ingest(tmp_path, monkeypatch):
    from app.database.database import DatabaseContext
    from app.services.cover_art_manager import CoverArtContext, CoverArtManager
    from tests.owned_database import OwnedTestDatabase
    from tests.test_identity_ingest import INIT_SQL, _pipeline

    db = OwnedTestDatabase(DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    source = _flac(tmp_path / "import" / "lucky.flac")
    registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})

    _pipeline((db, manager, tmp_path), identity_registry=registry).organize(source)

    run = dict(registry="R", job_id="<object>")
    assert calls.records == [
        _metadata_probe("<tmp>/import/lucky.flac", **run),
        _probe("<tmp>/import/lucky.flac", **run),
        _hash("<tmp>/import/lucky.flac", **run),
        _version(**run),
    ]


@pytest.mark.requires_fpcalc
def test_identity_worker_exact_then_fingerprint_step(tmp_path, monkeypatch):
    db = make_db(tmp_path)
    path = _flac(tmp_path / "music" / "a.flac", seconds=10)
    add_track(db, path, codec="flac", identity={"fp_state": "pending"})
    registry = FfmpegProcessRegistry()
    worker = make_identity_worker(db, registry=registry, compute=audio_identity.compute_exact,
                                  fingerprinter=_fpcalc())
    calls = ToolCalls(monkeypatch, tmp_path, {"R": registry})

    worker.process_one()
    worker.process_one()

    assert calls.records == [
        _probe("<tmp>/music/a.flac", registry="R", job_id=("identity", 1), low_priority=True),
        _hash("<tmp>/music/a.flac", registry="R", job_id=("identity", 1), low_priority=True),
        _fpcalc_run("<tmp>/music/a.flac", registry="R", job_id=("identity", 2), low_priority=True),
    ]


# --- uploads: validation, commit, recovery --------------------------------------------


@pytest.mark.requires_fpcalc
def test_upload_validation_and_commit(tmp_path, monkeypatch):
    from tests.upload_commit_fixtures import accept, make_commit_worker
    from tests.upload_validation_fixtures import BOOT, item_row, stage_item

    db = make_db(tmp_path)
    music = tmp_path / "music"
    root = music / ".uploads"
    root.mkdir(parents=True)
    clip = _flac(tmp_path / "clip.flac", seconds=10)
    tool = _fpcalc()
    staged = stage_item(db, root, content=clip.read_bytes())
    validation = FfmpegProcessRegistry()
    commit_registry = FfmpegProcessRegistry()
    calls = ToolCalls(monkeypatch, tmp_path, {"V": validation, "C": commit_registry})

    UploadValidationWorker(db, uploads_root=root, boot_id=BOOT, tokens=CancelTokens(),
                           registry=validation, fingerprinter=tool).process_one()
    assert item_row(db, staged)["state"] == "review_ready"
    validated = len(calls.records)
    commit = accept(db, {**staged, **item_row(db, staged)} | {"source": staged["source"]},
                    write_tags=True, edits={"title": "Tagged"})
    worker = make_commit_worker(db, music, probe=probe_upload, exact=audio_identity.compute_exact,
                                tag_writer=metadata.write_metadata_tags, registry=commit_registry)
    assert worker.process_one() == "prepared"

    source = str(staged["source"]).replace(str(tmp_path), "<tmp>")
    work = str(commit["work"]).replace(str(tmp_path), "<tmp>")
    v_job, c_job = ("upload-validation", 1), ("upload-commit", 1)
    upload_probe = ["ffprobe", "-v", "error", "-hide_banner", "-show_streams", "-show_format", "-of",
                    "json", "-protocol_whitelist", "file",
                    "-format_whitelist", "flac,mp3,wav,mov"]
    assert calls.records[:validated] == [
        ("upload_validation.run_capture", [*upload_probe, source],
         ("timeout_s", 30, "max_stdout_bytes", 1048576), "V", v_job, True),
        _probe(source, forced=WHITELIST_FLAC, registry="V", job_id=v_job, low_priority=True),
        _hash(source, forced=WHITELIST_FLAC, registry="V", job_id=v_job, low_priority=True),
        _fpcalc_run(source, forced=["-format", "flac"], registry="V", job_id=v_job, low_priority=True),
        _version(registry="V", job_id=v_job, low_priority=True),
    ]
    assert calls.records[validated:] == [
        ("metadata.run_ffmpeg",
         ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *WHITELIST_FLAC, "-i", source,
          "-map", "0", "-c", "copy", "-map_metadata", "0", "-metadata", "title=Tagged", work],
         ("timeout", 30, "output", work), "C", c_job, False),
        _metadata_probe(work, forced=WHITELIST_FLAC),
        ("upload_validation.run_capture", [*upload_probe, work],
         ("timeout_s", 30, "max_stdout_bytes", 1048576), "C", c_job, True),
        _probe(work, forced=WHITELIST_FLAC, registry="C", job_id=c_job, low_priority=True),
        _hash(work, forced=WHITELIST_FLAC, registry="C", job_id=c_job, low_priority=True),
    ]


def test_upload_recovery_digest_verdict(tmp_path, monkeypatch):
    path = _flac(tmp_path / "final.flac")
    expected = audio_identity.compute_exact(path, "flac")
    calls = ToolCalls(monkeypatch, tmp_path)

    assert upload_recovery._digest_verdict(audio_identity.compute_exact, path, "flac", expected, "flac") \
        == (True, None)

    assert calls.records == [
        _probe("<tmp>/final.flac", forced=WHITELIST_FLAC, low_priority=True),
        _hash("<tmp>/final.flac", forced=WHITELIST_FLAC, low_priority=True),
    ]


# --- conversion ------------------------------------------------------------------------


def test_conversion_lossless_job(tmp_path, monkeypatch):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = _flac(conv._root(tmp_path) / "song.flac")
    track = conv._add_track(db, source, codec="flac")
    _settled(db, track.uuid_id)
    # The stored digest is stale, so the job hashes the source itself.
    sql_dicts(db, "UPDATE track_audio_identity SET exact_state = 'pending' WHERE uuid_id = ?",
         (track.uuid_id,))
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, "alac", None, track.revision)
    calls = ToolCalls(monkeypatch, tmp_path, {"orch": orch._registry})

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    src = "<tmp>/owner/song.flac"
    converted = f"<tmp>/.staging/{track.uuid_id}.{job_id}.convert.m4a"
    tagged = f"<tmp>/.staging/{track.uuid_id}.{job_id}.tagged.m4a"
    run = dict(registry="orch", job_id=job_id)
    assert calls.records == [
        _metadata_probe(src),
        ("audio_identity.run_capture",
         ["ffmpeg", "-v", "error", "-nostdin", "-err_detect", "crccheck+explode", "-max_error_rate", "0",
          "-i", src, "-map", "0:a:0", "-f", "null", "-"],
         ("timeout_s", 30, "max_stdout_bytes", 4096), "orch", job_id, True),
        _probe(src, **run),
        _hash(src, **run),
        _version(**run),
        ("transcoder.run_ffmpeg",
         ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-c:v", "copy",
          "-disposition:v:0", "attached_pic", "-c:a", "alac", "-f", "mp4", "-movflags", "+faststart",
          "-sample_fmt", "s32p", "-ar", "22050", "-ac", "1", f"{converted}.partial"],
         ("timeout", 30, "output", f"{converted}.partial"), "orch", job_id, False),
        ("metadata.run_ffmpeg",
         ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", converted, "-map", "0", "-c", "copy",
          "-map_metadata", "0", "-metadata", "title=T", "-metadata", "artist=Art", tagged],
         ("timeout", 30, "output", tagged), "orch", job_id, False),
        _metadata_probe(tagged),
        _metadata_probe(tagged),
        _probe(tagged, **run),
        _hash(tagged, **run),
    ]
