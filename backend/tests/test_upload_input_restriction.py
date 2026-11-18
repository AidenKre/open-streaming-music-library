"""Review r1 7-R1-18 (suspected): ffprobe/ffmpeg auto-probe the uploaded bytes,
so a playlist-style upload can make them open a second file (or a URL).

Proof with the real tools, no network: an upload whose bytes are an ffconcat
script naming a file next to it. Unrestricted, ffprobe opens that file and
reports *its* audio stream (the evidence the second file was opened). The
probe of staged upload bytes may open only the one input file: it is limited
to the demuxers of the allow-listed containers and to the ``file`` protocol."""
import subprocess

import pytest

from app.services import ffmpeg_runner
from app.services.upload_validation import ValidationFailed, probe_upload

pytestmark = pytest.mark.requires_ffmpeg


def _audio(path, codec="flac"):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=duration=1",
                    "-c:a", codec, str(path)], check=True)


@pytest.fixture
def playlist(tmp_path):
    """``source`` (the staged upload) names ``other.flac`` beside it."""
    folder = tmp_path / "stage"
    folder.mkdir()
    _audio(folder / "other.flac")
    (folder / "source").write_text("ffconcat version 1.0\nfile other.flac\n")
    return folder / "source"


def test_unrestricted_the_tools_open_the_named_file(playlist):
    """The finding is real on this FFmpeg: the second file's stream shows up."""
    out = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "csv", str(playlist)],
                         capture_output=True, text=True)
    assert "flac" in out.stdout  # other.flac was opened and decoded


def test_the_upload_probe_never_opens_a_second_file(playlist):
    commands = []

    def recording_run(cmd, **kwargs):
        commands.append(cmd)
        return ffmpeg_runner.run_capture(cmd, **kwargs)

    with pytest.raises(ValidationFailed):
        probe_upload(playlist, run=recording_run)

    [cmd] = commands
    # The exact command the probe ran shows nothing of other.flac.
    out = subprocess.run(cmd, capture_output=True, text=True)
    assert "flac" not in out.stdout
    assert "streams" not in out.stdout or '"codec_name"' not in out.stdout


@pytest.mark.parametrize("codec, name", [("flac", "a.flac"), ("libmp3lame", "a.mp3"),
                                         ("pcm_s16le", "a.wav"), ("aac", "a.m4a")])
def test_every_allow_listed_container_still_probes(tmp_path, codec, name):
    path = tmp_path / name
    _audio(path, codec)
    staged = tmp_path / "source"  # staged sources carry no extension
    staged.write_bytes(path.read_bytes())

    detected = probe_upload(staged)

    assert detected["codec"] is not None


# ── every later process on staged upload bytes (validation and commit) ─────

class _Recorder:
    """Records the argv of every media process started while it is installed."""

    def __init__(self, monkeypatch):
        self.argvs = []
        real = subprocess.Popen
        recorder = self

        class Recording(real):
            def __init__(self, args, *a, **kw):
                if isinstance(args, (list, tuple)):
                    recorder.argvs.append([str(x) for x in args])
                super().__init__(args, *a, **kw)

        monkeypatch.setattr(subprocess, "Popen", Recording)

    def on(self, path):
        """The runs whose input is ``path`` (version probes and others excluded)."""
        return [a for a in self.argvs if str(path) in a]


_TOOLS = ("ffmpeg", "ffprobe", "fpcalc")


def _tool(argv) -> str:
    """The media tool of a run (it may be wrapped, e.g. by ``nice``)."""
    return next((a.rsplit("/", 1)[-1] for a in argv if a.rsplit("/", 1)[-1] in _TOOLS), argv[0])


def _restricted(argv, path) -> bool:
    i = argv.index(str(path))
    before = argv[:i]
    tool = _tool(argv)
    if tool == "fpcalc":
        return "-format" in before
    if "-protocol_whitelist" not in before or before[before.index("-protocol_whitelist") + 1] != "file":
        return False
    return "-f" in before or "-format_whitelist" in before


@pytest.mark.requires_fpcalc
def test_every_process_on_staged_bytes_opens_only_its_input(tmp_path, monkeypatch):
    import shutil

    from app.services.audio_identity import compute_exact
    from app.services.ffmpeg_runner import FfmpegProcessRegistry
    from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version
    from app.services.job_runtime import CancelTokens
    from app.services.metadata import extract_cover_art_bytes, write_metadata_tags
    from app.services.upload_validation import UploadValidationWorker
    from tests.identity_worker_fixtures import make_db
    from tests.upload_commit_fixtures import accept, make_commit_worker
    from tests.upload_validation_fixtures import BOOT, item_row, stage_item

    db = make_db(tmp_path)
    music = tmp_path / "music"
    root = music / ".uploads"
    root.mkdir(parents=True)
    clip = tmp_path / "clip.flac"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "anoisesrc=color=pink:seed=5:sample_rate=44100:duration=1",
                    "-metadata", "title=Orig", "-c:a", "flac", str(clip)], check=True)
    staged = stage_item(db, root, content=clip.read_bytes())
    exe = shutil.which("fpcalc")
    recorder = _Recorder(monkeypatch)

    UploadValidationWorker(db, uploads_root=root, boot_id=BOOT, tokens=CancelTokens(),
                           registry=FfmpegProcessRegistry(),
                           fingerprinter=FpcalcFingerprinter(exe, probe_fpcalc_version(exe), timeout_s=30),
                           ).process_one()
    assert item_row(db, staged)["state"] == "review_ready"
    commit = accept(db, {**staged, **item_row(db, staged)} | {"source": staged["source"]},
                    write_tags=True, edits={"title": "Tagged"})
    worker = make_commit_worker(db, music, probe=probe_upload, exact=compute_exact,
                                tag_writer=write_metadata_tags, art=extract_cover_art_bytes,
                                registry=FfmpegProcessRegistry())
    assert worker.process_one() == "prepared"

    runs = recorder.on(staged["source"]) + recorder.on(commit["work"])
    tools = {_tool(a) for a in runs}
    assert {"ffprobe", "ffmpeg", "fpcalc"} <= tools, tools
    unrestricted = [a for a in runs
                    if not _restricted(a, staged["source"] if str(staged["source"]) in a else commit["work"])]
    assert unrestricted == []


def test_a_playlist_header_in_front_of_real_audio_is_refused_not_steered(tmp_path):
    """In-piece review #7: the whitelist refuses a file whose auto-probe picks a
    playlist demuxer; it never falls back to an allowed one, so nothing that
    later code auto-probes differently is ever admitted."""
    mp3 = tmp_path / "a.mp3"
    _audio(mp3, "libmp3lame")
    staged = tmp_path / "source"
    staged.write_bytes(b"ffconcat version 1.0\nfile a.mp3\n" + mp3.read_bytes())

    with pytest.raises(ValidationFailed):
        probe_upload(staged)
