"""The building blocks startup recovery uses to settle a journal row's files.

Sign-off OPEN-6.5-05 (decision of 2026-11-16), Part 2. Recovery reads a file it
cannot prove by the ownership rules, compares its decoded audio with the track's
own file (the exact audio hash of Phase 6.5, computed now), and either deletes a
redundant copy or makes the file a track of the row's owner. These tests pin the
pieces on their own:

- ``read_audio``: one timed probe (codec, technical columns, a new track's
  metadata) and the exact hash; it tells a file ffprobe *refuses* from one whose
  reading is *unknown* (timeout, missing tool).
- ``leftover_verdict``: the content rule's decision table, with the
  coordinator's decisions D1 (an unreadable leftover is deleted only when ffprobe
  refuses it and the track's own file hashed) and D2 (nothing readable: leave it).
- ``Organizer.register_in_place``: a file already inside the library becomes a
  track without moving.
- ``refresh_track_audio_properties(file_path=...)``: the technical columns and
  the path describe the file that is actually there.
- ``ffprobe_for_metadata(timeout=...)``: recovery passes its own bound; other
  callers get the shared probe bound (bug row U05-A-06), never an untimed call.
"""

import subprocess
from pathlib import Path

import pytest

from app.database import ANY_OWNER
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import audio_identity
from app.services import metadata as metadata_mod
from app.services.ffmpeg_runner import CaptureOverflow, CaptureResult, CaptureTimeout
from app.services import organizer
from app.services.audio_identity import ExactAudioHash, ExactUnavailable
from app.services.metadata import ProbeUnavailable, probe_unavailable_raises
from app.services.recovery_audio import (
    LEAVE,
    MAKE_TRACK,
    PROBE_OK,
    PROBE_REFUSED,
    PROBE_UNKNOWN,
    RECOVERY_PROBE_TIMEOUT_S,
    REDUNDANT,
    UNREADABLE,
    AudioReading,
    leftover_verdict,
    read_audio,
)
from tests.test_track_editor import _add_track, _db

META = TrackMetaData(codec="aac", duration=1.0, bitrate_kbps=192.0, sample_rate_hz=44100,
                     channels=2, title="T")


def _sine(path: Path, freq: int = 440, codec: str = "flac", **tags) -> None:
    """A tiny real file: a sine of ``freq`` Hz, flac (lossless) or aac."""
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
           "-f", "lavfi", "-i", f"sine=frequency={freq}:duration=0.3", "-c:a", codec]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    subprocess.run([*cmd, str(path)], check=True)


def _hash(digest, kind="packets_sha256"):
    return ExactAudioHash(kind, digest, 44100, 2, None)


def _reading(probe=PROBE_OK, exact=None):
    return AudioReading(probe=probe, metadata=META if probe == PROBE_OK else None, exact=exact)


OK_A = _reading(exact=_hash("a"))
OK_B = _reading(exact=_hash("b"))
OK_A_PCM = _reading(exact=_hash("a", kind="pcm_sha256"))
HASH_TIMEOUT = _reading(exact=ExactUnavailable("failed", "timeout"))
HASH_DECODE = _reading(exact=ExactUnavailable("failed", "decode_error"))
HASH_UNSUPPORTED = _reading(exact=ExactUnavailable("unsupported", None))
REFUSED = _reading(probe=PROBE_REFUSED)
UNKNOWN = _reading(probe=PROBE_UNKNOWN)


# --- the content rule's decision table -------------------------------------------------------------


@pytest.mark.parametrize(
    "leftover,track,verdict",
    [
        (OK_A, OK_A, REDUNDANT),  # same audio: a redundant copy
        (OK_B, OK_A, MAKE_TRACK),  # different audio
        (OK_A_PCM, OK_A, MAKE_TRACK),  # a lossless original vs a lossy result never match (D6)
        (HASH_TIMEOUT, OK_A, MAKE_TRACK),  # unknown is never "same"
        (HASH_DECODE, OK_A, MAKE_TRACK),  # probes, but the hash failed: it may be audio
        (HASH_UNSUPPORTED, OK_A, MAKE_TRACK),
        (REFUSED, OK_A, UNREADABLE),  # D1: ffprobe refuses it, the track's file hashed
        (OK_A, HASH_TIMEOUT, MAKE_TRACK),  # the track's file proves nothing: keep the leftover
        (OK_A, REFUSED, MAKE_TRACK),
        (OK_A, UNKNOWN, MAKE_TRACK),
        (REFUSED, HASH_DECODE, LEAVE),  # D2: nothing readable
        (REFUSED, UNKNOWN, LEAVE),
        (REFUSED, REFUSED, LEAVE),
        (UNKNOWN, OK_A, LEAVE),  # D2: the leftover's probe timed out; never deleted on a guess
        (UNKNOWN, HASH_TIMEOUT, LEAVE),
    ],
)
def test_the_content_rule_decides_from_both_readings(leftover, track, verdict):
    assert leftover_verdict(leftover, track) == verdict


# --- read_audio: real files ------------------------------------------------------------------------


@pytest.mark.requires_ffmpeg
def test_a_decodable_file_reads_with_its_metadata_and_exact_hash(tmp_path):
    path = tmp_path / "a.flac"
    _sine(path, title="Song", artist="Art")

    reading = read_audio(path)

    assert reading.probe == PROBE_OK
    assert reading.metadata.codec == "flac" and reading.metadata.title == "Song"
    assert isinstance(reading.exact, ExactAudioHash)


@pytest.mark.requires_ffmpeg
def test_two_tag_versions_of_the_same_audio_hash_equal_and_other_audio_does_not(tmp_path):
    a = tmp_path / "a.flac"
    b = tmp_path / "b.flac"
    c = tmp_path / "c.flac"
    _sine(a, title="One", artist="Art")
    _sine(b, title="Two", artist="Other")  # the same audio with other tags
    _sine(c, freq=880, title="One", artist="Art")  # other audio, same tags

    assert leftover_verdict(read_audio(b), read_audio(a)) == REDUNDANT
    assert leftover_verdict(read_audio(c), read_audio(a)) == MAKE_TRACK


@pytest.mark.requires_ffmpeg
def test_a_file_ffprobe_refuses_reads_as_refused(tmp_path):
    path = tmp_path / "junk.m4a"
    path.write_bytes(b"this is not audio at all" * 10)

    assert read_audio(path).probe == PROBE_REFUSED


def test_a_probe_that_times_out_reads_as_unknown_never_refused(tmp_path, monkeypatch):
    path = tmp_path / "slow.m4a"
    path.write_bytes(b"x")
    seen = {}

    def slow(cmd, *args, timeout_s, **kwargs):
        seen["timeout"] = timeout_s
        raise CaptureTimeout(f"ffprobe timed out after {timeout_s}s")

    monkeypatch.setattr(metadata_mod, "run_capture", slow)

    reading = read_audio(path)

    assert reading.probe == PROBE_UNKNOWN
    assert seen["timeout"] == RECOVERY_PROBE_TIMEOUT_S


def test_a_missing_ffprobe_reads_as_unknown(tmp_path, monkeypatch):
    path = tmp_path / "a.m4a"
    path.write_bytes(b"x")

    def missing(*args, **kwargs):
        raise FileNotFoundError("ffprobe")

    # The process start inside run_capture (the probes run through it, U05-A-06).
    monkeypatch.setattr("app.services.ffmpeg_runner.subprocess.Popen", missing)

    assert read_audio(path).probe == PROBE_UNKNOWN


def test_the_probe_timeout_is_bounded():
    assert 0 < RECOVERY_PROBE_TIMEOUT_S <= 60


# --- ffprobe_for_metadata: always bounded; recovery passes its own bound ---------------------------


def _capture_run(monkeypatch):
    seen = {}

    def fake(cmd, *args, **kwargs):
        seen.update(kwargs)
        return CaptureResult(returncode=0, stdout=b"{}", stderr="")

    monkeypatch.setattr(metadata_mod, "run_capture", fake)
    return seen


def test_other_callers_get_the_shared_probe_bound(tmp_path, monkeypatch):
    """Reversed by bug row U05-A-06 (was: other callers keep an untimed probe)."""
    seen = _capture_run(monkeypatch)

    metadata_mod.ffprobe_for_metadata(tmp_path / "a.m4a")

    assert seen["timeout_s"] == audio_identity.PROBE_TIMEOUT_S


def test_a_timed_out_probe_answers_none_or_raises_unavailable_when_asked(tmp_path, monkeypatch):
    def slow(cmd, *args, timeout_s, **kwargs):
        raise CaptureTimeout(f"ffprobe timed out after {timeout_s}s")

    monkeypatch.setattr(metadata_mod, "run_capture", slow)

    assert metadata_mod.ffprobe_for_metadata(tmp_path / "a.m4a", timeout=5) is None
    with probe_unavailable_raises(), pytest.raises(ProbeUnavailable):
        metadata_mod.ffprobe_for_metadata(tmp_path / "a.m4a", timeout=5)
    with probe_unavailable_raises(), pytest.raises(ProbeUnavailable):
        metadata_mod.get_track_metadata(tmp_path / "a.m4a", timeout=5)


# --- a file inside the library becomes a track in place -------------------------------------------


def _organizer(db, root):
    added = []

    def add(track):
        ok = db.add_track(track)
        if ok:
            added.append(track)
        return ok

    org = organizer.Organizer(
        organizer.OrganizerContext(
            music_library_dir=root, should_organize_files=True, should_copy_files=False,
            add_to_database=add,
            path_in_use=lambda path: db.track_path_in_use(str(path), owner_id=ANY_OWNER),
        )
    )
    return org, added


def test_a_library_file_becomes_a_track_where_it_lies(tmp_path):
    db = _db(tmp_path)
    root = tmp_path / "owner"
    path = root / "Old" / "song.flac"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"leftover")
    meta = TrackMetaData(codec="flac", duration=2.0, bitrate_kbps=900.0, sample_rate_hz=44100,
                         channels=2, title="Leftover", artist="Art")
    org, added = _organizer(db, root)

    new_uuid = org.register_in_place(path, meta, identity=None)

    assert path.read_bytes() == b"leftover"  # never moved
    track = db.get_track_by_uuid(new_uuid)
    assert str(track.file_path) == str(path)
    assert track.metadata.title == "Leftover" and track.metadata.codec == "flac"


def test_a_path_another_track_uses_never_becomes_a_second_track(tmp_path):
    db = _db(tmp_path)
    root = tmp_path / "owner"
    path = root / "song.m4a"
    root.mkdir()
    path.write_bytes(b"x")
    _add_track(db, path, "Existing", "Art")
    org, added = _organizer(db, root)

    assert org.register_in_place(path, META, identity=None) is None
    assert added == []


def test_a_file_outside_the_root_or_in_an_internal_folder_never_becomes_a_track(tmp_path):
    db = _db(tmp_path)
    root = tmp_path / "owner"
    (root / ".staging").mkdir(parents=True)
    inside_internal = root / ".staging" / "x.m4a"
    inside_internal.write_bytes(b"x")
    outside = tmp_path / "elsewhere.m4a"
    outside.write_bytes(b"x")
    org, added = _organizer(db, root)

    for path in (inside_internal, outside):
        assert org.register_in_place(path, META, identity=None) is None
    assert added == []


# --- technical columns follow the file ------------------------------------------------------------


def test_refreshing_the_columns_can_point_the_track_at_another_file(tmp_path):
    db = _db(tmp_path)
    old = tmp_path / "owner" / "song.m4a"
    new = tmp_path / "owner" / "song.flac"
    track = _add_track(db, old, "T", "Art")
    before = db.get_track_by_uuid(track.uuid_id).revision

    revision = db.refresh_track_audio_properties(
        track.uuid_id, codec="flac", bitrate_kbps=900.0, sample_rate_hz=48000, channels=1,
        duration=None, file_path=str(new), owner_id=db.owner_id,
    )

    after = db.get_track_by_uuid(track.uuid_id)
    assert revision > before
    assert str(after.file_path) == str(new)
    assert (after.metadata.codec, after.metadata.bitrate_kbps, after.metadata.sample_rate_hz,
            after.metadata.channels) == ("flac", 900.0, 48000, 1)
    assert after.metadata.duration == 1.0  # unknown (None) never overwrites a known value


def test_unknown_columns_are_stored_as_unknown(tmp_path):
    db = _db(tmp_path)
    track = _add_track(db, tmp_path / "owner" / "song.m4a", "T", "Art")

    db.refresh_track_audio_properties(
        track.uuid_id, codec=None, bitrate_kbps=None, sample_rate_hz=None, channels=None,
        duration=None, owner_id=db.owner_id,
    )

    after = db.get_track_by_uuid(track.uuid_id)
    assert (after.metadata.codec, after.metadata.bitrate_kbps, after.metadata.sample_rate_hz,
            after.metadata.channels) == (None, None, None, None)


@pytest.mark.parametrize(
    "returncode,stdout", [(-9, "{}"), (-11, ""), (0, "not json")],
    ids=["killed", "crashed", "garbled"],
)
def test_a_killed_or_garbled_probe_reads_as_unknown_never_refused(tmp_path, monkeypatch, returncode, stdout):
    """Review #3: D1 deletes only a file ffprobe itself refuses; a probe killed by a
    signal or answering garbage says nothing about the file."""
    path = tmp_path / "a.m4a"
    path.write_bytes(b"x")

    def fake(cmd, *args, **kwargs):
        return CaptureResult(returncode=returncode, stdout=stdout.encode(), stderr="")

    monkeypatch.setattr(metadata_mod, "run_capture", fake)

    reading = read_audio(path)

    assert reading.probe == PROBE_UNKNOWN
    assert leftover_verdict(reading, OK_A) == LEAVE


def test_a_probe_whose_answer_overflows_its_bound_reads_as_unknown_never_refused(tmp_path, monkeypatch):
    """The probes' stdout is bounded since U05-A-06: an answer past the bound
    says nothing ffprobe refused, so D1 must not delete on it."""
    path = tmp_path / "a.m4a"
    path.write_bytes(b"x")

    def flood(cmd, *args, max_stdout_bytes, **kwargs):
        raise CaptureOverflow(f"ffprobe stdout exceeded {max_stdout_bytes} bytes")

    monkeypatch.setattr(metadata_mod, "run_capture", flood)

    reading = read_audio(path)

    assert reading.probe == PROBE_UNKNOWN
    assert leftover_verdict(reading, OK_A) == LEAVE
