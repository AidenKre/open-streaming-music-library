"""Phase 6.5B.1b exit proof on real ``fpcalc`` and ``ffmpeg``: a scratch library
converges to non-pending fingerprint states (spec §4.2, §6.4; review 6.5-U06,
6.5-U07).

The library is the generated fixture set (tests/audio_fixtures.py; a
time-varying melody, a steady tone, silence, short clips and unreadable
files) in a ``tmp_path`` database. The real worker runs step by step with a
fake clock that jumps a day whenever it idles, so backoffs run out with no
wall-clock wait. Expected states are written by hand from how each file is
made.
"""

from __future__ import annotations

import shutil

import pytest

from app.services.ffmpeg_runner import FfmpegProcessRegistry
from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version
from app.services.identity_wakeup import IdentityWakeup
from app.services.identity_worker import AudioIdentityWorker
from tests.audio_fixtures import FP_SECONDS, build_fingerprint_fixtures
from tests.identity_worker_fakes import FakeClock
from tests.identity_worker_fixtures import add_track, identity, make_db, sql

pytestmark = [pytest.mark.requires_fpcalc, pytest.mark.requires_ffmpeg]

EXPECTED = {
    "melody30.flac": "current",
    # No duration in the header: fpcalc prints 0; the track's known duration is stored (DEV-6.5-08).
    "melody30_streamed.flac": "current",
    "melody10.flac": "too_short",
    "tone30.flac": "low_information",
    "silence30.flac": "low_information",
    "clip2.flac": "too_short",  # fpcalc's "Empty fingerprint"
    "truncated.flac": "failed",
    "notaudio.flac": "failed",
}


@pytest.fixture
def library(tmp_path):
    files = build_fingerprint_fixtures(tmp_path / "music")
    db = make_db(tmp_path)
    uuids = {}
    for name in EXPECTED:
        uuids[name] = add_track(db, files[name].path, codec="flac", identity={"fp_state": "pending"})
    sql(db, "UPDATE trackmetadata SET duration = ? WHERE uuid_id = ?",
        (float(FP_SECONDS), uuids["melody30_streamed.flac"]))
    return db, uuids


def _run_until_settled(worker, clock, db, uuids, max_steps=200):
    for _ in range(max_steps):
        result = worker.process_one()
        if result.outcome == "idle":
            if all(identity(db, u)["fp_state"] != "pending" for u in uuids.values()):
                return
            clock.advance(86400 + 1)
    raise AssertionError("the worker did not converge")


def test_a_scratch_library_converges_to_non_pending_fingerprint_states(library):
    db, uuids = library
    exe = shutil.which("fpcalc")
    fpcalc = FpcalcFingerprinter(exe, probe_fpcalc_version(exe), timeout_s=60)
    clock = FakeClock()
    worker = AudioIdentityWorker(db, wakeup=IdentityWakeup(), registry=FfmpegProcessRegistry(), clock=clock,
                                 fingerprinter=fpcalc)

    _run_until_settled(worker, clock, db, uuids)

    states = {name: identity(db, u)["fp_state"] for name, u in uuids.items()}
    assert states == EXPECTED
    rows = {name: sql(db, "SELECT * FROM track_audio_fingerprint WHERE uuid_id = ?", (u,))
            for name, u in uuids.items()}
    for name, state in EXPECTED.items():
        row = identity(db, uuids[name])
        assert row["fp_algorithm"] == "chromaprint-2", name
        if state in ("current", "low_information"):
            [fp] = rows[name]
            assert (fp["backend"], fp["algorithm"]) == ("fpcalc", "chromaprint-2")
            assert fp["duration_s"] == pytest.approx(FP_SECONDS, abs=0.5), name
            assert fp["item_count"] > 120 and len(fp["data"]) == 4 * fp["item_count"]
        else:
            assert rows[name] == [], name  # too_short and failed store no blob
    melody = identity(db, uuids["melody30.flac"])
    assert melody["exact_state"] == "current" and melody["match_state"] == "current"
    assert f"fpcalc {fpcalc.tool_version}" in melody["tool_versions"]

    # Converged means idle: another day changes nothing and runs nothing.
    before = sql(db, "SELECT * FROM track_audio_identity ORDER BY uuid_id")
    clock.advance(10 * 86400)
    assert worker.process_one().outcome == "idle"
    assert sql(db, "SELECT * FROM track_audio_identity ORDER BY uuid_id") == before
