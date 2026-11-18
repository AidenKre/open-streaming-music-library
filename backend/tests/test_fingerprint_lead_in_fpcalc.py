"""s7-fingerprint-search on real ``fpcalc`` and ``ffmpeg``: a copy with 3.5, 4, 5 or 6 s
more lead-in silence is a duplicate the finder must suggest; 7.5 s is outside the window.

Report temp/audits/fingerprint-threshold-research.md §1 and §5: two tracks are
compared when their lengths differ by up to max(3 s, 2%), but the alignment
search tried only +-24 items (about 3 s) around offset 0, so such a copy scored
0.24-0.33 and was missed. The comparator now also searches around the offset
the two measured durations imply.

The audio is a 200 s two-voice tone sequence (mono, 11025 Hz, the rate fpcalc
resamples to anyway). The copies are the same file behind 3500, 4000, 5000, 6000
and 7500 ms of digital silence (ffmpeg ``adelay``). Round 2 (owner, 2026-11-17,
after temp/audits/fingerprint-validation-jamendo.md) widened the window to
max(7 s, 2%) and lowered possible to 0.70; the test states those settings
explicitly (U09-B-06) rather than reading the defaults. Each file goes through
``compute_fingerprint`` with the real ``FpcalcFingerprinter``, exactly as the
identity worker and the upload check do, and the prints are matched by
``find_duplicates``. Measured on fpcalc 1.6.2 (2026-11-17): best alignments 28,
32, 40 and 48 items, scores 0.951, 0.944, 0.930 and 0.917; the search around 0
alone gives 0.685-0.700: the 5 s copy reaches 0.7001 there, so at 0.70 it would
be "possible" even without the length-implied range. This tone sequence repeats,
so a wrong offset still scores about 0.70 (real unrelated music stayed below 0.60
in the validation). The search is therefore proven by the 0.15+ gain to strong,
not by a miss around 0.
"""

from __future__ import annotations

import shutil
import sqlite3

import pytest

from app.services.audio_identity import KIND_PCM, AudioIdentity, ExactAudioHash, compute_fingerprint
from app.services.duplicate_detection import (
    MatcherParams,
    StagedIdentity,
    StagedRef,
    band_for,
    compare_fingerprints,
    find_duplicates,
)
from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version
from tests.audio_fixtures import _ff
from tests.identity_worker_fixtures import make_db

pytestmark = [pytest.mark.requires_fpcalc, pytest.mark.requires_ffmpeg]

PARAMS = MatcherParams(
    max_offset=24, min_overlap=120, min_items=120, min_diversity=0.15,
    strong=0.90, possible=0.70, duration_tolerance_s=7.0, duration_tolerance_frac=0.02,
)
LEAD_INS_MS = (3500, 4000, 5000, 6000, 7500)
TONES = (
    "aevalsrc=0.4*sin(2*PI*t*220*pow(2\\,floor(mod(t*3\\,24))/12))"
    "+0.3*sin(2*PI*t*330*pow(2\\,floor(mod(t*5\\,17))/12))"
    ":s=11025:d=200"
)


@pytest.fixture(scope="module")
def prints(tmp_path_factory):
    root = tmp_path_factory.mktemp("lead-in")
    _ff("-f", "lavfi", "-i", TONES, "-c:a", "flac", str(root / "plain.flac"))
    for ms in LEAD_INS_MS:
        _ff("-i", str(root / "plain.flac"), "-af", f"adelay={ms}", "-c:a", "flac", str(root / f"lead{ms}.flac"))
    exe = shutil.which("fpcalc")
    fpcalc = FpcalcFingerprinter(exe, probe_fpcalc_version(exe), timeout_s=60)
    return {name: compute_fingerprint(root / f"{name}.flac", fpcalc, params=PARAMS)
            for name in ("plain", *(f"lead{ms}" for ms in LEAD_INS_MS))}


def _identity(fingerprint, digest):
    return AudioIdentity(exact=ExactAudioHash(KIND_PCM, digest, 11025, 1, 16),
                         tool_versions="test", computed_at=1, fingerprint=fingerprint)


def test_the_prints_are_current_and_carry_the_measured_lengths(prints):
    assert {name: fp.state for name, fp in prints.items()} == dict.fromkeys(prints, "current")
    assert prints["plain"].duration_s == pytest.approx(200.0, abs=0.05)
    assert prints["lead3500"].duration_s == pytest.approx(203.5, abs=0.05)
    assert prints["lead4000"].duration_s == pytest.approx(204.0, abs=0.05)
    assert prints["lead7500"].duration_s == pytest.approx(207.5, abs=0.05)


def test_copies_with_3_5_to_6_s_more_lead_in_are_suggested_and_7_5_s_is_not_compared(prints, tmp_path):
    db = make_db(tmp_path)
    conn = sqlite3.connect(db.context.database_path)
    try:
        report = find_duplicates(
            conn, _identity(prints["plain"], "aa" * 32), owner_id=db.owner_id, params=PARAMS,
            extra_subjects=tuple(
                StagedIdentity(StagedRef(f"lead{ms}"), _identity(prints[f"lead{ms}"], f"{i:02x}" * 32))
                for i, ms in enumerate(LEAD_INS_MS, start=1)
            ),
        )
    finally:
        conn.close()

    found = {m.subject.item_uuid: (m.kind, m.band) for m in report.matches}
    # 7.5 s is beyond max(7 s, 2% of 207.5 s): never compared.
    assert set(found) == {"lead3500", "lead4000", "lead5000", "lead6000"}
    assert found["lead3500"] == found["lead4000"] == ("fingerprint", "strong")  # 0.951, 0.944
    assert all(m.kind == "fingerprint" and m.score >= 0.85 for m in report.matches)  # 0.930, 0.917


@pytest.mark.parametrize("name, items", [("lead3500", 28), ("lead4000", 32), ("lead5000", 40), ("lead6000", 48)])
def test_the_best_alignment_is_where_the_lengths_point(prints, name, items):
    plain, copy = prints["plain"], prints[name]

    result = compare_fingerprints(plain.items, copy.items, PARAMS,
                                  duration_a_s=plain.duration_s, duration_b_s=copy.duration_s)
    without_lengths = compare_fingerprints(plain.items, copy.items, PARAMS)

    assert abs(result.offset - items) <= 1
    # The search around 0 alone does not see it as the same recording.
    assert band_for(without_lengths.score, PARAMS) != "strong"
    assert result.score > without_lengths.score + 0.15
