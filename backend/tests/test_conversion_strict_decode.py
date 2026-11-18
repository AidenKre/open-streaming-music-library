"""Sign-off 2026-11-17, OPEN-6.5-06 alternative 2: before a lossless conversion
(lossless source, lossless target: where the §6.3 audio check applies) the
original is decoded once in strict mode. Damaged audio refuses the conversion
before any work on the new file; a strict decode that cannot run follows
DEV-6.5-09 (unavailable: logged, the conversion goes ahead; killed: the job
stops and the original is kept). Hashing, uploads, imports and lossy
conversions are unchanged.

ffmpeg conceals damaged FLAC frames by default (the CRC is not even checked)
and exits 0; ``-err_detect crccheck+explode -max_error_rate 0`` makes it verify
the frame CRCs and exit 69 when any decode error occurred (ffmpeg 9.0.2). Only
that exit means damaged audio: review r1 found that ``-xerror`` (the first
choice) also failed a healthy WAV written to a pipe, and that a signal (255) or
an input ffmpeg cannot open (1) is no verdict on the audio.
"""

import shutil
import signal
import subprocess
from pathlib import Path

import pytest

import tests.test_conversion as conv
from app.services import audio_identity
from app.services.audio_identity import ExactAudioHash, check_strict_decode, compute_exact
from app.services.conversion import AUDIO_CHECK_STOPPED_ERROR, SOURCE_DAMAGED_ERROR
from app.services.ffmpeg_runner import CaptureResult, CaptureTimeout, FfmpegError, scaled_timeout
from tests.test_identity_conversion import _identity, _settled, _sql

LOGGER = "app.services.conversion"
DAMAGED_TEXT = "Conversion stopped: the original has damaged audio, so it was not converted."


def _ffmpeg(*args):
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", *args], check=True)


def _default_decode_rc(path):
    """Independent expectation: the lenient decode every other step uses (no strict flag)."""
    return subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-map", "0:a:0", "-f", "null", "-"],
        capture_output=True,
    ).returncode


@pytest.fixture(scope="module")
def audio(tmp_path_factory):
    if shutil.which("ffmpeg") is None:
        pytest.skip("ffmpeg not available")
    root = tmp_path_factory.mktemp("strict-decode")
    good = root / "good.flac"
    _ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "2", "-ar", "44100",
            "-sample_fmt", "s16", str(good))
    data = bytearray(good.read_bytes())
    middle = len(data) // 2  # inside an audio frame, far past the metadata blocks
    for i in range(middle, middle + 4):
        data[i] ^= 0xFF
    damaged = root / "damaged.flac"
    damaged.write_bytes(bytes(data))
    # A healthy WAV written to a pipe: its size fields say "unknown" (0xFFFFFFFF).
    piped_wav = root / "piped.wav"
    piped_wav.write_bytes(subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=2", "-ac", "2", "-ar", "44100", "-f", "wav", "-"],
        capture_output=True, check=True).stdout)
    alac = root / "healthy.m4a"
    _ffmpeg("-i", str(good), "-c:a", "alac", str(alac))
    mp3 = root / "lossy.mp3"
    _ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-c:a", "libmp3lame",
            "-b:a", "192k", str(mp3))
    return {"good": good, "damaged": damaged, "mp3": mp3, "piped_wav": piped_wav, "alac": alac}


# --- the strict decode itself (process-backed) ----------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_healthy_flac_passes_the_default_and_the_strict_decode(audio):
    assert _default_decode_rc(audio["good"]) == 0
    assert check_strict_decode(audio["good"]) is None


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("name", ["piped_wav", "alac"])
def test_healthy_wav_and_alac_pass_the_strict_decode(audio, name):
    assert _default_decode_rc(audio[name]) == 0
    assert check_strict_decode(audio[name]) is None


@pytest.mark.requires_ffmpeg
def test_a_damaged_flac_passes_the_default_decode_and_the_hash_but_fails_the_strict_one(audio):
    # The finding: the lenient decode (and so the exact hash) sees nothing wrong.
    assert _default_decode_rc(audio["damaged"]) == 0
    assert isinstance(compute_exact(audio["damaged"], "flac"), ExactAudioHash)
    # The strict decode reports it as a decode error (= damaged audio).
    assert check_strict_decode(audio["damaged"]) == "decode_error"


# --- the strict decode's command and outcome mapping (no process) ---------------------


class _FakeCapture:
    def __init__(self, result=None, raises=None):
        self.result, self.raises, self.calls = result, raises, []

    def __call__(self, cmd, **kwargs):
        self.calls.append((cmd, kwargs))
        if self.raises is not None:
            raise self.raises
        return self.result


def _file(tmp_path):
    path = tmp_path / "song.flac"
    path.write_bytes(b"x" * 2048)
    return path


def test_the_strict_decode_runs_low_priority_on_the_shared_runner_with_strict_flags(
    tmp_path, monkeypatch
):
    path = _file(tmp_path)
    fake = _FakeCapture(CaptureResult(returncode=0, stdout=b"", stderr=""))
    monkeypatch.setattr(audio_identity, "run_capture", fake)
    registry = object()

    assert check_strict_decode(path, registry=registry, job_id=7, low_priority=True) is None

    [(cmd, kwargs)] = fake.calls
    assert cmd[0] == "ffmpeg"
    before_input = cmd[: cmd.index("-i")]
    assert "-xerror" not in cmd  # it also fails healthy files (review r1)
    assert before_input[before_input.index("-err_detect") + 1] == "crccheck+explode"
    assert cmd[cmd.index("-max_error_rate") + 1] == "0"
    assert cmd[cmd.index("-i") + 1] == str(path)
    assert cmd[cmd.index("-map") + 1] == "0:a:0"  # the stream the hash and transcoder read
    assert cmd[-3:] == ["-f", "null", "-"]
    assert kwargs["timeout_s"] == scaled_timeout(path)
    assert (kwargs["registry"], kwargs["job_id"], kwargs["low_priority"]) == (registry, 7, True)


@pytest.mark.parametrize("fake, reason", [
    (_FakeCapture(CaptureResult(returncode=69, stdout=b"", stderr="CRC error")), "decode_error"),
    # Any other exit is no verdict on the audio: the input could not be opened (1),
    # a SIGTERM (255), a crash, an -xerror style stop (183).
    (_FakeCapture(CaptureResult(returncode=1, stdout=b"", stderr="")), "internal_error"),
    (_FakeCapture(CaptureResult(returncode=255, stdout=b"", stderr="")), "internal_error"),
    (_FakeCapture(CaptureResult(returncode=183, stdout=b"", stderr="")), "internal_error"),
    (_FakeCapture(CaptureResult(returncode=-signal.SIGSEGV, stdout=b"", stderr="")),
     "internal_error"),
    (_FakeCapture(CaptureResult(returncode=-signal.SIGKILL, stdout=b"", stderr="")), "killed"),
    (_FakeCapture(CaptureResult(returncode=127, stdout=b"", stderr="")), "tool_missing"),
    (_FakeCapture(raises=FfmpegError("ffmpeg not found")), "tool_missing"),
    (_FakeCapture(raises=CaptureTimeout("ffmpeg timed out after 30s")), "timeout"),
    (_FakeCapture(raises=RuntimeError("boom")), "internal_error"),
])
def test_the_strict_decode_names_why_it_did_not_pass(tmp_path, monkeypatch, fake, reason):
    monkeypatch.setattr(audio_identity, "run_capture", fake)
    assert check_strict_decode(_file(tmp_path)) == reason


def test_a_missing_original_is_not_called_damaged(tmp_path, monkeypatch):
    fake = _FakeCapture(CaptureResult(returncode=0, stdout=b"", stderr=""))
    monkeypatch.setattr(audio_identity, "run_capture", fake)
    assert check_strict_decode(tmp_path / "gone.flac") == "master_missing"
    assert fake.calls == []


# --- the conversion (process-backed: real transcoder) ---------------------------------


class _Order:
    """Records the order of the strict decode, the source hash and the transcode."""

    def __init__(self, monkeypatch, orch, strict=None):
        self.events, self.strict_calls = [], []
        real_transcode = conv.conversion_module.transcode
        real_compute = orch.compute_identity

        def transcode(*args, **kwargs):
            self.events.append("transcode")
            return real_transcode(*args, **kwargs)

        def compute(path, codec_hint, **kwargs):
            if ".tagged." not in Path(path).name:
                self.events.append("source hash")
            return real_compute(path, codec_hint, **kwargs)

        def check(path, **kwargs):
            self.events.append("strict decode")
            self.strict_calls.append((Path(path), kwargs))
            return check_strict_decode(path, **kwargs) if strict is None else strict(path, kwargs)

        monkeypatch.setattr(conv.conversion_module, "transcode", transcode)
        orch.compute_identity = compute
        orch.check_strict_decode = check


def _world(tmp_path, monkeypatch, fixture, codec, target, bitrate=None, *, strict=None):
    db, orch, coordinator = conv._make_orchestrator(tmp_path)
    source = conv._root(tmp_path) / f"song{fixture.suffix}"
    shutil.copyfile(fixture, source)
    track = conv._add_track(db, source, codec=codec)
    _settled(db, track.uuid_id)
    # The stored digest is stale, so the job hashes the source itself.
    _sql(db, "UPDATE track_audio_identity SET exact_state = 'pending' WHERE uuid_id = ?",
         (track.uuid_id,))
    before = _identity(db, track.uuid_id)
    order = _Order(monkeypatch, orch, strict)
    job_id = orch.enqueue(conv._lib(orch), track.uuid_id, target, bitrate, track.revision)
    return db, orch, coordinator, track, source, before, order, job_id


def _assert_nothing_changed(db, track, source, original, before, tmp_path):
    conv._assert_track_untouched(db, track, source, original)
    assert db.get_track_by_uuid(track.uuid_id).metadata == track.metadata
    assert not source.with_suffix(".m4a").exists()
    assert db.list_journal_entries() == []
    assert conv._staging_files(tmp_path) == []
    assert _identity(db, track.uuid_id) == before


@pytest.mark.requires_ffmpeg
def test_a_damaged_original_refuses_a_lossless_conversion_before_any_work(
    tmp_path, monkeypatch, audio
):
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, audio["damaged"], "flac", "alac")
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", DAMAGED_TEXT)
    assert SOURCE_DAMAGED_ERROR == DAMAGED_TEXT
    assert order.events == ["strict decode"]  # no source hash, no transcode
    _assert_nothing_changed(db, track, source, original, before, tmp_path)


@pytest.mark.requires_ffmpeg
def test_a_healthy_original_is_decoded_strictly_once_before_the_hash_and_the_transcode(
    tmp_path, monkeypatch, audio
):
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, audio["good"], "flac", "alac")

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    assert order.events == ["strict decode", "source hash", "transcode"]
    [(path, kwargs)] = order.strict_calls
    assert path == source
    assert (kwargs["registry"], kwargs["job_id"], kwargs["low_priority"]) \
        == (orch._registry, job_id, True)
    # The audio check itself is unchanged: verified, so the fingerprint is kept.
    assert _identity(db, track.uuid_id)["fp_state"] == "current"


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("name, codec, target, bitrate", [
    ("damaged", "flac", "aac", 256),   # lossy target: converts as before, damage and all
    ("mp3", "mp3", "flac", None),      # lossy source
])
def test_a_conversion_outside_the_lossless_check_never_decodes_strictly(
    tmp_path, monkeypatch, audio, name, codec, target, bitrate
):
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, audio[name], codec, target, bitrate)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert order.strict_calls == []


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("reason", ["tool_missing", "timeout", "internal_error", "output_error"])
def test_a_strict_decode_that_cannot_run_lets_the_checked_conversion_go_ahead(
    tmp_path, monkeypatch, audio, caplog, reason
):
    caplog.set_level("INFO", logger=LOGGER)
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, audio["good"], "flac", "alac", strict=lambda p, k: reason)

    conv._run_submitted(coordinator)

    assert (db.get_conversion_job(job_id)["status"],
            db.get_conversion_job(job_id)["error_text"]) == ("done", None)
    assert any(r.name == LOGGER and "audio check unavailable" in r.getMessage()
               and reason in r.getMessage() for r in caplog.records)
    # The hash check still ran and passed (fingerprint kept as verified unchanged).
    assert order.events == ["strict decode", "source hash", "transcode"]
    assert _identity(db, track.uuid_id)["fp_state"] == "current"


@pytest.mark.requires_ffmpeg
def test_a_killed_strict_decode_stops_the_job_and_keeps_the_original(tmp_path, monkeypatch, audio):
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, audio["good"], "flac", "alac", strict=lambda p, k: "killed")
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", AUDIO_CHECK_STOPPED_ERROR)
    assert order.events == ["strict decode"]
    _assert_nothing_changed(db, track, source, original, before, tmp_path)


@pytest.mark.requires_ffmpeg
def test_a_cancel_during_the_strict_decode_ends_cancelled_with_the_original_kept(
    tmp_path, monkeypatch, audio
):
    holder = {}

    def cancel_then_killed(path, kwargs):
        assert holder["orch"].cancel(conv._lib(holder["orch"]), kwargs["job_id"])
        return "killed"

    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, audio["good"], "flac", "alac", strict=cancel_then_killed)
    holder["orch"] = orch
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "cancelled"
    assert order.events == ["strict decode"]
    _assert_nothing_changed(db, track, source, original, before, tmp_path)


# --- OPEN-6.5-06 "Retry": a FLAC whose only fault is a trailing tag or padding -------------
#
# The owner's answer (2026-11-17): when the strict check fails, try once more with a
# recognised trailing tag or padding stripped; the file is damaged only if that also
# fails. ffmpeg's FLAC reader runs to the end of the file, so an ID3v1 tag, an APEv2
# tag or zero padding after the last frame is an "invalid sync code" (exit 69).

ID3V1 = b"TAG" + b"Title".ljust(30, b"\0") + b"Artist".ljust(30, b"\0") \
    + b"Album".ljust(30, b"\0") + b"2020" + b"comment".ljust(30, b"\0") + b"\x00"


def _ape(header: bool) -> bytes:
    """An APEv2 tag with one item; footer always, header when asked."""
    item = (5).to_bytes(4, "little") + b"\0\0\0\0" + b"Title\0" + b"Hello"
    size = len(item) + 32  # items + footer, the header not counted
    flags = 0x80000000 if header else 0  # "this tag has a header"
    footer = b"APETAGEX" + (2000).to_bytes(4, "little") + size.to_bytes(4, "little") \
        + (1).to_bytes(4, "little") + flags.to_bytes(4, "little") + b"\0" * 8
    head = b"APETAGEX" + (2000).to_bytes(4, "little") + size.to_bytes(4, "little") \
        + (1).to_bytes(4, "little") + (flags | 0x20000000).to_bytes(4, "little") + b"\0" * 8
    return (head if header else b"") + item + footer


@pytest.fixture(scope="module")
def trailed(audio, tmp_path_factory):
    root = tmp_path_factory.mktemp("trailers")
    good = audio["good"].read_bytes()
    damaged = audio["damaged"].read_bytes()
    files = {
        "id3v1": good + ID3V1,
        "zeros": good + b"\0" * 4096,
        "damaged_id3v1": damaged + ID3V1,
        "garbage": good + bytes(range(1, 129)),  # 128 bytes, not a recognised tag
    }
    paths = {}
    for name, data in files.items():
        paths[name] = root / f"{name}.flac"
        paths[name].write_bytes(data)
    # A WAV cut in the middle of its last sample: the header promises one more byte.
    wav = root / "whole.wav"
    _ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-ac", "2", "-ar", "44100",
            "-c:a", "pcm_s16le", str(wav))
    paths["wav_cut_mid_sample"] = root / "cut.wav"
    paths["wav_cut_mid_sample"].write_bytes(wav.read_bytes()[:-1])
    paths["good_size"] = len(good)
    return paths


# The trailer reader (no process).

@pytest.mark.parametrize("tail, stripped", [
    (ID3V1, 128),
    (b"\0" * 4096, 4096),
    (_ape(header=False), len(_ape(header=False))),
    (_ape(header=True), len(_ape(header=True))),
    (_ape(header=True) + ID3V1, len(_ape(header=True)) + 128),
    (b"\0" * 300 + ID3V1, 428),
], ids=["id3v1", "zeros", "ape", "ape-with-header", "ape-then-id3v1", "zeros-then-id3v1"])
def test_a_recognised_trailer_is_found_and_measured(tmp_path, tail, stripped):
    path = tmp_path / "song.flac"
    audio_bytes = b"fLaC" + b"\x11" * 5000
    path.write_bytes(audio_bytes + tail)

    assert audio_identity.audio_end_without_trailer(path) == len(audio_bytes + tail) - stripped


@pytest.mark.parametrize("tail", [
    b"",                              # nothing after the audio
    bytes(range(1, 129)),             # 128 bytes of something else
    b"TAG"[:2] + b"\x11" * 126,       # not "TAG"
    b"APETAGEX" + b"\xff" * 24,       # an APE footer whose size is nonsense
    b"\0" * (1024 * 1024 + 1),        # a zero run longer than any padding (1 MiB)
], ids=["none", "other-bytes", "not-tag", "bad-ape-size", "zeros-over-1mib"])
def test_anything_else_is_no_trailer(tmp_path, tail):
    path = tmp_path / "song.flac"
    path.write_bytes(b"fLaC" + b"\x11" * 5000 + tail)

    assert audio_identity.audio_end_without_trailer(path) is None


def test_a_file_that_is_only_padding_has_no_audio_end(tmp_path):
    path = tmp_path / "song.flac"
    path.write_bytes(b"\0" * 4096)
    assert audio_identity.audio_end_without_trailer(path) is None
    assert audio_identity.audio_end_without_trailer(tmp_path / "gone.flac") is None


def test_the_retry_reads_the_original_up_to_the_audio_end_and_writes_nothing(
    tmp_path, monkeypatch
):
    path = _file(tmp_path)
    fake = _FakeCapture(CaptureResult(returncode=0, stdout=b"", stderr=""))
    monkeypatch.setattr(audio_identity, "run_capture", fake)

    assert check_strict_decode(path, job_id=7, audio_end=2000, low_priority=True) is None

    [(cmd, kwargs)] = fake.calls
    assert cmd[cmd.index("-i") + 1] == f"subfile,,start,0,end,2000,,:file:{path.resolve()}"
    assert cmd[cmd.index("-err_detect") + 1] == "crccheck+explode"  # the same strict flags
    assert kwargs["timeout_s"] == scaled_timeout(path)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["song.flac"]


# The strict decode of the stripped bytes (process-backed).

@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("name, verdict", [
    ("id3v1", None), ("zeros", None), ("damaged_id3v1", "decode_error"),
])
def test_the_strict_decode_of_the_audio_before_the_trailer(trailed, name, verdict):
    path = trailed[name]
    assert check_strict_decode(path) == "decode_error"  # the false "damaged", or real damage
    end = audio_identity.audio_end_without_trailer(path)
    assert end == trailed["good_size"]
    assert check_strict_decode(path, audio_end=end) == verdict


# The conversion.

@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("name", ["id3v1", "zeros"])
def test_a_healthy_flac_with_a_trailing_tag_or_padding_converts(
    tmp_path, monkeypatch, trailed, name
):
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, trailed[name], "flac", "alac")
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("done", None)
    assert order.events == ["strict decode", "strict decode", "source hash", "transcode"]
    assert order.strict_calls[1][1]["audio_end"] == trailed["good_size"]
    assert order.strict_calls[1][0] == source  # the original, read in place
    # The audio check passed: the trailer is not audio.
    assert _identity(db, track.uuid_id)["fp_state"] == "current"
    converted = source.with_suffix(".m4a")
    assert converted.is_file() and not source.exists()
    assert ID3V1 not in converted.read_bytes()  # the trailer is not carried over
    assert original == trailed[name].read_bytes()  # the job read it; nothing wrote to it


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("name, strict_runs", [
    ("damaged_id3v1", 2),  # the retry runs and fails: damaged
    ("garbage", 1),        # nothing recognised: no retry
])
def test_damaged_audio_or_an_unknown_trailer_is_still_refused(
    tmp_path, monkeypatch, trailed, name, strict_runs
):
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, trailed[name], "flac", "alac")
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", DAMAGED_TEXT)
    assert order.events == ["strict decode"] * strict_runs
    _assert_nothing_changed(db, track, source, original, before, tmp_path)


@pytest.mark.requires_ffmpeg
def test_a_wav_cut_mid_sample_is_refused_as_damaged(tmp_path, monkeypatch, trailed):
    """Decision (BE-B round 2): an incomplete last sample is no trailer; the file is
    incomplete, so it stays refused. No retry runs for a WAV (its data chunk bounds
    the audio; a WAV with an ID3v1 after it already passes)."""
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, trailed["wav_cut_mid_sample"], "pcm_s16le", "flac")
    original = source.read_bytes()

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", DAMAGED_TEXT)
    assert order.events == ["strict decode"]
    _assert_nothing_changed(db, track, source, original, before, tmp_path)


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("second, outcome", [
    # Review r1 of round 2, finding 1: the first attempt already said damaged; a
    # retry that cannot run gives no verdict, so the first one stands.
    ("timeout", ("failed", DAMAGED_TEXT)),
    ("internal_error", ("failed", DAMAGED_TEXT)),
    ("tool_missing", ("failed", DAMAGED_TEXT)),
    ("output_error", ("failed", DAMAGED_TEXT)),
    ("master_missing", ("failed", DAMAGED_TEXT)),
    ("killed", ("failed", AUDIO_CHECK_STOPPED_ERROR)),  # a stop is still a stop
    (None, ("done", None)),
])
def test_a_retry_that_cannot_run_keeps_the_first_verdict(
    tmp_path, monkeypatch, trailed, second, outcome
):
    verdicts = iter(["decode_error", second])
    db, orch, coordinator, track, source, before, order, job_id = _world(
        tmp_path, monkeypatch, trailed["id3v1"], "flac", "alac",
        strict=lambda p, k: next(verdicts))

    conv._run_submitted(coordinator)

    job = db.get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == outcome
    assert [k.get("audio_end") for _, k in order.strict_calls] == [None, trailed["good_size"]]


# --- review r1 of round 2, findings 5 and 9: the bytes before the trailer must be the
# whole stream the header announces, and a tag is only a well-formed one --------------


def _frame_positions(path: Path) -> list[int]:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_packets",
         "-show_entries", "packet=pos", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    import json
    return [int(p["pos"]) for p in json.loads(out)["packets"] if p.get("pos") not in (None, "N/A")]


@pytest.fixture(scope="module")
def cut_on_a_frame(audio, tmp_path_factory):
    """The good FLAC cut exactly where a frame starts, halfway through."""
    good = audio["good"].read_bytes()
    positions = _frame_positions(audio["good"])
    assert len(positions) > 4
    return good[:positions[len(positions) // 2]]


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("tail", [b"\0" * 4096, ID3V1], ids=["zeros", "id3v1"])
def test_a_flac_missing_its_last_frames_is_still_refused(tmp_path, cut_on_a_frame, tail):
    """Probe P4: before the retry existed this file was refused; it still is."""
    path = tmp_path / "half.flac"
    path.write_bytes(cut_on_a_frame + tail)

    assert check_strict_decode(path) == "decode_error"
    end = audio_identity.audio_end_without_trailer(path)
    assert end == len(cut_on_a_frame)
    assert check_strict_decode(path, audio_end=end) == "decode_error"


@pytest.mark.requires_ffmpeg
def test_a_forged_apev2_footer_cannot_hide_damage(tmp_path, audio, cut_on_a_frame):
    """Probe P9: a footer whose size covers damaged frames is no well-formed tag."""
    rest = bytearray(audio["good"].read_bytes()[len(cut_on_a_frame):])
    for i in range(200, len(rest), 997):
        rest[i] ^= 0xFF
    size = len(rest) + 32
    footer = b"APETAGEX" + (2000).to_bytes(4, "little") + size.to_bytes(4, "little") \
        + (0).to_bytes(4, "little") + (0).to_bytes(4, "little") + b"\0" * 8
    path = tmp_path / "forged.flac"
    path.write_bytes(cut_on_a_frame + bytes(rest) + footer)

    assert check_strict_decode(path) == "decode_error"
    end = audio_identity.audio_end_without_trailer(path)
    # Zero bytes inside the 32-byte footer may count as padding; the "tag" never does.
    assert end is None or end > len(path.read_bytes()) - 32
    assert end is None or check_strict_decode(path, audio_end=end) == "decode_error"


@pytest.mark.parametrize("tail", [
    # Item count says 1, the items area holds garbage.
    b"\x99" * 40 + b"APETAGEX" + (2000).to_bytes(4, "little") + (72).to_bytes(4, "little")
    + (1).to_bytes(4, "little") + (0).to_bytes(4, "little") + b"\0" * 8,
    # The header flag is set but no header sits where it says.
    _ape(header=False)[:-32] + b"APETAGEX" + (2000).to_bytes(4, "little")
    + (len(_ape(header=False))).to_bytes(4, "little") + (1).to_bytes(4, "little")
    + (0x80000000).to_bytes(4, "little") + b"\0" * 8,
    # A size beyond any real tag (16 MiB + 1).
    b"APETAGEX" + (2000).to_bytes(4, "little") + (16 * 1024 * 1024 + 1).to_bytes(4, "little")
    + (1).to_bytes(4, "little") + (0).to_bytes(4, "little") + b"\0" * 8,
], ids=["items-do-not-parse", "header-missing", "oversized"])
def test_a_malformed_apev2_tag_is_no_trailer(tmp_path, tail):
    path = tmp_path / "song.flac"
    path.write_bytes(b"fLaC" + b"\x11" * 5000 + tail)

    end = audio_identity.audio_end_without_trailer(path)
    # Zero bytes inside the 32-byte footer may count as padding; the "tag" never does.
    assert end is None or end > len(path.read_bytes()) - 32


def _flac_header(total_samples: int, rate: int = 44100) -> bytes:
    """fLaC + a last-block STREAMINFO with ``total_samples`` (36 bits) at ``rate``."""
    info = bytearray(34)
    packed = (rate << 44) | (1 << 41) | (15 << 36) | total_samples  # 2 ch, 16 bit
    info[10:18] = packed.to_bytes(8, "big")
    return b"fLaC" + bytes([0x80, 0, 0, 34]) + bytes(info)


@pytest.mark.parametrize("out_us, total, verdict", [
    (2_000_000, 88_200, None),             # the whole announced stream
    (1_973_696, 88_200, "decode_error"),   # frames missing at the end
    (None, 88_200, "output_error"),        # no progress report: no verdict
    (1_973_696, 0, None),                  # the header does not say (unknown): no check
], ids=["complete", "frames-missing", "no-report", "total-unknown"])
def test_the_retry_compares_the_decoded_length_with_the_header(
    tmp_path, monkeypatch, out_us, total, verdict
):
    path = tmp_path / "song.flac"
    path.write_bytes(_flac_header(total) + b"\x11" * 4000)
    report = b"" if out_us is None else f"out_time_us={out_us}\nprogress=end\n".encode()
    fake = _FakeCapture(CaptureResult(returncode=0, stdout=report, stderr=""))
    monkeypatch.setattr(audio_identity, "run_capture", fake)

    assert check_strict_decode(path, audio_end=3000) == verdict

    [(cmd, kwargs)] = fake.calls
    assert cmd[cmd.index("-progress") + 1] == "pipe:1"
