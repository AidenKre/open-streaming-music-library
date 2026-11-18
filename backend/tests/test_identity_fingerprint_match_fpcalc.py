"""Phase 6.5B.2b exit proof on real ``fpcalc`` and ``ffmpeg`` (spec §5 fingerprint
layer; review 6.5-U09, live cases L03 fingerprint half and L10, here in-process).

A scratch library of generated audio is run through the real worker (real
exact hash, real fpcalc). Expected pairs are written by hand from how each
file is made:

- a 30 s melody as FLAC and as a 128 kbit/s MP3: different exact kinds, so
  only a **strong fingerprint** pair;
- an unrelated 30 s melody (other pitches and step rates, same length, so it
  is inside the duration window and really compared): no pair;
- 30 s of silence as FLAC and MP3: ``low_information``, never paired;
- a 10 s clip as FLAC and MP3: ``too_short``, never paired.

``add_track`` leaves ``trackmetadata.duration`` NULL for every track, so every
fingerprint pair here is found through the print's own duration.
"""

from __future__ import annotations

import shutil

import pytest

from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version
from app.services.identity_wakeup import IdentityWakeup
from app.services.identity_worker import AudioIdentityWorker
from tests.audio_fixtures import RATE, _ff, _melody
from tests.fingerprint_fixtures import pin_matcher_settings
from tests.identity_worker_fakes import FakeClock
from tests.identity_worker_fixtures import add_track, identity, make_db, sql

pytestmark = [pytest.mark.requires_fpcalc, pytest.mark.requires_ffmpeg]


@pytest.fixture(autouse=True)
def _explicit_matcher_settings(monkeypatch):
    # U09-B-06: these tests prove matching at stated settings, not at the defaults.
    pin_matcher_settings(monkeypatch)


def _other_melody(seconds: int) -> str:
    return (
        "aevalsrc=0.4*sin(2*PI*t*261*pow(2\\,floor(mod(t*4\\,19))/12))"
        "+0.3*sin(2*PI*t*392*pow(2\\,floor(mod(t*7\\,13))/12))"
        f":s={RATE}:d={seconds}"
    )


@pytest.fixture
def library(tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    p = lambda name: music / name  # noqa: E731
    _ff("-f", "lavfi", "-i", _melody(30), "-c:a", "flac", str(p("melody.flac")))
    _ff("-i", str(p("melody.flac")), "-c:a", "libmp3lame", "-b:a", "128k", str(p("melody.mp3")))
    _ff("-f", "lavfi", "-i", _other_melody(30), "-c:a", "flac", str(p("other.flac")))
    _ff("-f", "lavfi", "-i", f"anullsrc=r={RATE}:cl=stereo:d=30", "-c:a", "flac", str(p("silence.flac")))
    _ff("-i", str(p("silence.flac")), "-c:a", "libmp3lame", "-b:a", "128k", str(p("silence.mp3")))
    _ff("-f", "lavfi", "-i", _melody(10), "-c:a", "flac", str(p("clip.flac")))
    _ff("-i", str(p("clip.flac")), "-c:a", "libmp3lame", "-b:a", "128k", str(p("clip.mp3")))
    db = make_db(tmp_path)
    uuids = {
        name: add_track(db, p(name), codec="mp3" if name.endswith(".mp3") else "flac",
                        identity={"fp_state": "pending"})
        for name in ("melody.flac", "melody.mp3", "other.flac", "silence.flac", "silence.mp3",
                     "clip.flac", "clip.mp3")
    }
    return db, uuids


def _converge(worker, clock, db, max_steps=300):
    for _ in range(max_steps):
        if worker.process_one().outcome == "idle":
            rows = sql(db, "SELECT exact_state, fp_state, match_state FROM track_audio_identity")
            if all("pending" not in r.values() for r in rows):
                return
            clock.advance(86400 + 1)
    raise AssertionError("the worker did not converge")


def test_flac_and_mp3_of_one_melody_are_a_strong_fingerprint_pair_and_nothing_else_pairs(library):
    db, uuids = library
    exe = shutil.which("fpcalc")
    fpcalc = FpcalcFingerprinter(exe, probe_fpcalc_version(exe), timeout_s=60)
    clock = FakeClock()
    worker = AudioIdentityWorker(db, wakeup=IdentityWakeup(), registry=FfmpegProcessRegistry(),
                                 clock=clock, fingerprinter=fpcalc)

    _converge(worker, clock, db)

    states = {name: identity(db, u)["fp_state"] for name, u in uuids.items()}
    assert states == {
        "melody.flac": "current", "melody.mp3": "current", "other.flac": "current",
        "silence.flac": "low_information", "silence.mp3": "low_information",
        "clip.flac": "too_short", "clip.mp3": "too_short",
    }
    rows = sql(db, "SELECT * FROM track_duplicate_candidates")
    names = {u: n for n, u in uuids.items()}
    assert [{names[r["uuid_a"]], names[r["uuid_b"]]} for r in rows] == [{"melody.flac", "melody.mp3"}]
    [row] = rows
    assert (row["kind"], row["band_rank"], row["status"]) == ("fingerprint", 1, "open")
    assert 0.90 <= row["sort_score"] <= 1.0
