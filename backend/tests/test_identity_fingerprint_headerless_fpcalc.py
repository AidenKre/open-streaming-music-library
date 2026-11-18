"""Live-gate fix 6-5-L-03 on real ``fpcalc`` and ``ffmpeg`` (spec §4.1: a print's
duration is the decoded full-track duration; §5 duration window; review
6.5-U09 "a 0.0-duration track is still matched through its fingerprint
duration"; live case L10 "the no-duration file is matched through its
fingerprint duration").

A 30 s melody is written once as a normal FLAC, once as a FLAC written to a
pipe (no duration in its header: ffprobe says N/A and fpcalc prints
``"duration": 0.00``) and once as an MP3. ``add_track`` leaves
``trackmetadata.duration`` NULL, so the only duration source left for the
headerless file is decoding it.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version
from app.services.identity_wakeup import IdentityWakeup
from app.services.identity_worker import AudioIdentityWorker
from tests.audio_fixtures import _ff, _melody
from tests.fingerprint_fixtures import pin_matcher_settings
from tests.identity_worker_fakes import FakeClock
from tests.identity_worker_fixtures import add_track, identity, make_db, sql

pytestmark = [pytest.mark.requires_fpcalc, pytest.mark.requires_ffmpeg]


@pytest.fixture(autouse=True)
def _explicit_matcher_settings(monkeypatch):
    # U09-B-06: these tests prove matching at stated settings, not at the defaults.
    pin_matcher_settings(monkeypatch)


@pytest.fixture
def files(tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    normal, headerless, mp3 = music / "melody.flac", music / "melody_streamed.flac", music / "melody.mp3"
    _ff("-f", "lavfi", "-i", _melody(30), "-c:a", "flac", str(normal))
    with headerless.open("wb") as fh:
        subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(normal), "-f", "flac", "pipe:1"],
                       check=True, stdout=fh)
    _ff("-i", str(normal), "-c:a", "libmp3lame", "-b:a", "128k", str(mp3))
    # Preconditions: neither the container nor fpcalc knows the headerless file's duration.
    probed = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(headerless)],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    assert probed in ("", "N/A")
    fpcalc_out = subprocess.run([shutil.which("fpcalc"), "-json", str(headerless)],
                                check=True, capture_output=True, text=True).stdout
    assert '"duration": 0.00' in fpcalc_out
    return tmp_path, normal, headerless, mp3


def _converge(db, max_steps=300):
    exe = shutil.which("fpcalc")
    fpcalc = FpcalcFingerprinter(exe, probe_fpcalc_version(exe), timeout_s=60)
    clock = FakeClock()
    worker = AudioIdentityWorker(db, wakeup=IdentityWakeup(), registry=FfmpegProcessRegistry(),
                                 clock=clock, fingerprinter=fpcalc)
    for _ in range(max_steps):
        if worker.process_one().outcome == "idle":
            rows = sql(db, "SELECT exact_state, fp_state, match_state FROM track_audio_identity")
            if all("pending" not in r.values() for r in rows):
                return
            clock.advance(86400 + 1)
    raise AssertionError("the worker did not converge")


def _pairs(db, names):
    rows = sql(db, "SELECT * FROM track_duplicate_candidates")
    return {frozenset({names[r["uuid_a"]], names[r["uuid_b"]]}): (r["kind"], r["band_rank"]) for r in rows}


def _print_duration(db, uuid_id):
    [row] = sql(db, "SELECT duration_s FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,))
    return row["duration_s"]


def test_a_headerless_flac_is_printed_with_its_decoded_duration_and_matched(files):
    root, normal, headerless, mp3 = files
    db = make_db(root)
    uuids = {
        "normal": add_track(db, normal, identity={"fp_state": "pending"}),
        "headerless": add_track(db, headerless, identity={"fp_state": "pending"}),
        "mp3": add_track(db, mp3, codec="mp3", identity={"fp_state": "pending"}),
    }

    _converge(db)

    row = identity(db, uuids["headerless"])
    assert (row["exact_state"], row["fp_state"], row["failure_reason"]) == ("current", "current", None)
    assert _print_duration(db, uuids["headerless"]) == pytest.approx(30.0, abs=0.1)
    names = {u: n for n, u in uuids.items()}
    pairs = _pairs(db, names)
    # Identical decoded audio: an exact pair (the strongest kind wins the stored row).
    assert pairs[frozenset({"normal", "headerless"})] == ("exact", 0)
    # The pair the live gate missed: only the fingerprint layer can find it.
    assert pairs[frozenset({"headerless", "mp3"})] == ("fingerprint", 1)
    assert pairs[frozenset({"normal", "mp3"})] == ("fingerprint", 1)


def test_a_headerless_file_whose_exact_layer_is_unsupported_is_still_printed_and_matched(files):
    root, normal, headerless, mp3 = files
    db = make_db(root)
    uuids = {
        "normal": add_track(db, normal, identity={"fp_state": "pending"}),
        # A codec the exact layer does not know: exact 'unsupported', no digest.
        "headerless": add_track(db, headerless, codec="x-unknown", identity={"fp_state": "pending"}),
        "mp3": add_track(db, mp3, codec="mp3", identity={"fp_state": "pending"}),
    }

    _converge(db)

    row = identity(db, uuids["headerless"])
    assert (row["exact_state"], row["fp_state"]) == ("unsupported", "current")
    assert _print_duration(db, uuids["headerless"]) == pytest.approx(30.0, abs=0.1)
    pairs = _pairs(db, {u: n for n, u in uuids.items()})
    assert pairs[frozenset({"normal", "headerless"})] == ("fingerprint", 1)
    assert pairs[frozenset({"headerless", "mp3"})] == ("fingerprint", 1)
