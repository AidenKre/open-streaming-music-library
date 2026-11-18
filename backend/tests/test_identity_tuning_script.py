"""Phase 6.5B.2b: ``backend/scripts/identity_tuning.py`` (spec §8 "Threshold tuning";
review 6.5-U12, tuning half PARTIAL: only synthetic data here, DEV-6.5-04).

``identity_tuning.py <corpus_dir> <labels.csv> [--synthetic]`` fingerprints every
file the labels name, scores each labelled pair with the production comparator,
and prints: the corpus composition (counts per label, never a file name), each
label's score distribution, precision/recall per candidate threshold, and the
suggested ``FP_STRONG`` (spec §8: no scored negative at or above) and ``FP_POSSIBLE``
(s7-fingerprint-search: by recall, at most FP_STRONG). With
``--synthetic`` it says plainly that the result is not a threshold validation.

Unit tests inject a scripted fingerprinter (no fpcalc); one ``requires_fpcalc``
test runs the script on a small generated corpus.
"""

from __future__ import annotations

import importlib.util
import shutil
from pathlib import Path

import pytest

from app.services.fingerprinter import RawFingerprint
from tests.fingerprint_fixtures import noisy, pin_matcher_settings, random_print

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "identity_tuning.py"
SYNTHETIC_BANNER = "synthetic; not a threshold validation"


@pytest.fixture(autouse=True)
def _explicit_matcher_settings(monkeypatch):
    # U09-B-06: these tests prove matching at stated settings, not at the defaults.
    pin_matcher_settings(monkeypatch)


def _load():
    spec = importlib.util.spec_from_file_location("identity_tuning", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ScriptedFingerprinter:
    """Returns the print registered for a file's name (900 items, 120 s)."""

    name = "fakeprint"
    algorithm = "chromaprint-2"
    tool_version = "1.6.2"

    def __init__(self, prints, durations=None):
        self.prints = prints
        self.durations = durations or {}

    def fingerprint(self, path, *, max_seconds=120, registry=None, job_id=None, low_priority=False):
        name = Path(path).name
        return RawFingerprint(self.prints[name], self.durations.get(name, 120.0))


BASE = random_print(11, 900)
PRINTS = {
    "zq_a.flac": BASE,
    "zq_a_320.mp3": noisy(BASE, 1),        # 0.96875
    "zq_a_128.mp3": noisy(BASE, 3),        # 0.90625
    "zq_remaster.flac": noisy(BASE, 5),    # 0.84375
    "zq_radio_edit.flac": noisy(BASE, 4),  # 0.875 (negative, edit family)
    "zq_live.flac": noisy(BASE, 7),        # 0.78125 (negative)
    "zq_other.flac": random_print(12, 900),
    "zq_drone_1.flac": (0x12345678,) * 900,  # low_information
    "zq_drone_2.flac": (0x12345678,) * 900,
}
LABELS = """file_a,file_b,label
zq_a.flac,zq_a_320.mp3,same_master
zq_a.flac,zq_a_128.mp3,same_master
zq_a.flac,zq_remaster.flac,remaster
zq_a.flac,zq_radio_edit.flac,edit
zq_a.flac,zq_live.flac,live_vs_studio
zq_a.flac,zq_other.flac,unrelated
zq_drone_1.flac,zq_drone_2.flac,drone
"""


@pytest.fixture
def corpus(tmp_path):
    root = tmp_path / "corpus-private-names"
    root.mkdir()
    for name in PRINTS:
        (root / name).write_bytes(b"x")
    labels = tmp_path / "labels.csv"
    labels.write_text(LABELS)
    return root, labels


def run(capsys, corpus, *extra, prints=PRINTS, durations=None):
    module = _load()
    root, labels = corpus
    code = module.main([str(root), str(labels), *extra],
                       fingerprinter=ScriptedFingerprinter(prints, durations))
    return code, capsys.readouterr().out


def test_it_prints_the_composition_and_per_label_distributions(capsys, corpus):
    code, out = run(capsys, corpus)

    assert code == 0
    for label, count in [("same_master", 2), ("remaster", 1), ("edit", 1), ("live_vs_studio", 1),
                         ("unrelated", 1), ("drone", 1)]:
        assert f"{label}: {count}" in out
    assert "0.969" in out and "0.906" in out  # the same_master scores
    assert "low_information" in out           # the drone pair is not comparable by design


def test_it_suggests_thresholds_by_the_selection_rule(capsys, corpus):
    _, out = run(capsys, corpus)

    # FP_STRONG: lowest 0.01 step with no negative at or above it (max negative 0.875 -> 0.88).
    assert "suggested FP_STRONG: 0.88" in out
    # FP_POSSIBLE (s7-fingerprint-search: by recall, no longer precision-first): the
    # highest step that keeps at least 99% of the positives; all three here, so the
    # remaster's 0.844 sets it -> 0.84. The old rule gave 0.79.
    assert "suggested FP_POSSIBLE: 0.84" in out
    # The negatives that would still be suggested at it, by label only.
    assert "negatives at or above FP_POSSIBLE 0.84: edit 1" in out


def test_a_pair_outside_the_finders_duration_window_is_never_matched(capsys, corpus):
    # The radio edit is 80 s against 120 s: the finder never compares it, so it is
    # reported as outside the window, not scored, and cannot limit the suggestions.
    _, out = run(capsys, corpus, durations={"zq_radio_edit.flac": 80.0})

    line = next(l for l in out.splitlines() if l.strip().startswith("edit:") and "n " in l)
    assert "n 0" in line and "outside_duration_window 1" in line
    assert "suggested FP_STRONG: 0.79" in out  # max scored negative is now live (0.781)


def test_a_pair_just_inside_the_symmetric_window_is_scored(capsys, corpus):
    # 4.05 s apart at ~200 s: inside 2% of the longer track (the finder's rule).
    _, out = run(capsys, corpus, durations={"zq_a.flac": 200.0, "zq_radio_edit.flac": 204.05})

    assert "suggested FP_STRONG: 0.88" in out


def _corpus_of(tmp_path, prints, rows):
    root = tmp_path / "corpus-private-names"
    root.mkdir()
    for name in prints:
        (root / name).write_bytes(b"x")
    labels = tmp_path / "labels.csv"
    labels.write_text("file_a,file_b,label\n" + "".join(f"{a},{b},{label}\n" for a, b, label in rows))
    return root, labels


@pytest.mark.parametrize("low, suggested", [
    # 0.96 keeps 99%, but without a scored negative there is no FP_STRONG suggestion, so
    # it is capped at the configured FP_STRONG (0.90): the server refuses possible > strong.
    (1, "0.90 (capped at FP_STRONG; 99% of positives kept up to 0.96)"),
    (2, "0.84"),
])
def test_fp_possible_keeps_at_least_99_percent_of_the_positives(capsys, tmp_path, low, suggested):
    # 100 positive pairs: 100 - low score 0.969 and low score 0.844. One miss in 100
    # still keeps 99%; two do not. No negative pair at all: FP_POSSIBLE is still suggested.
    prints = {"zq_a.flac": BASE}
    rows = []
    for i in range(100):
        name = f"zq_p{i}.flac"
        prints[name] = noisy(BASE, 5 if i < low else 1)
        rows.append(("zq_a.flac", name, "same_master"))

    _, out = run(capsys, _corpus_of(tmp_path, prints, rows), prints=prints)

    assert f"suggested FP_POSSIBLE: {suggested}" in out
    assert "suggested FP_STRONG: none" in out


def test_an_unscored_positive_counts_as_missed(capsys, corpus):
    # The remaster is outside the duration window: 2 of 3 positives is under 99% at
    # every threshold, so nothing on the grid is suggested for FP_POSSIBLE.
    _, out = run(capsys, corpus, durations={"zq_remaster.flac": 80.0})

    assert "suggested FP_POSSIBLE: none on the grid (1 of 3 positive pairs not scored)" in out


def test_fp_possible_is_never_suggested_above_fp_strong(capsys, tmp_path):
    # Positives all at 0.969, the only negative at 0.781: strong 0.79, and the recall
    # rule's 0.96 is capped to it (FP_POSSIBLE must not exceed FP_STRONG).
    prints = {"zq_a.flac": BASE, "zq_b.flac": noisy(BASE, 1), "zq_live.flac": noisy(BASE, 7)}
    rows = [("zq_a.flac", "zq_b.flac", "same_master"), ("zq_a.flac", "zq_live.flac", "live_vs_studio")]

    _, out = run(capsys, _corpus_of(tmp_path, prints, rows), prints=prints)

    assert "suggested FP_STRONG: 0.79" in out
    assert "suggested FP_POSSIBLE: 0.79 (capped at FP_STRONG; 99% of positives kept up to 0.96)" in out


def test_a_positive_with_a_longer_lead_in_is_scored_with_the_finders_search(capsys, tmp_path):
    # 30 extra items of lead-in, 30 * 1365 / 11025 s longer: inside the window, and
    # found by the duration-aware search as the finder would (score 1.000).
    prints = {"zq_a.flac": BASE, "zq_lead.flac": random_print(13, 30) + BASE}
    rows = [("zq_a.flac", "zq_lead.flac", "compilation")]

    _, out = run(capsys, _corpus_of(tmp_path, prints, rows), prints=prints,
                 durations={"zq_a.flac": 200.0, "zq_lead.flac": 200.0 + 30 * 1365 / 11025})

    line = next(l for l in out.splitlines() if l.strip().startswith("compilation:") and "n " in l)
    assert "n 1" in line and "min 1.000" in line
    assert "suggested FP_POSSIBLE: 0.90 (capped at FP_STRONG; 99% of positives kept up to 1.00)" in out


def test_it_prints_precision_and_recall_per_threshold(capsys, corpus):
    _, out = run(capsys, corpus)

    # At 0.90: positives 0.969, 0.906 pass, 0.844 misses -> recall 2/3; no negative -> precision 1.
    line = next(l for l in out.splitlines() if l.lstrip().startswith("0.90"))
    assert "precision 1.000" in line and "recall 0.667" in line


def test_it_never_prints_a_file_name_or_the_corpus_path(capsys, corpus):
    _, out = run(capsys, corpus)

    assert "corpus-private-names" not in out
    assert "zq_" not in out  # every corpus file name starts with it


def test_the_synthetic_flag_labels_the_output(capsys, corpus):
    _, plain = run(capsys, corpus)
    _, synthetic = run(capsys, corpus, "--synthetic")

    assert SYNTHETIC_BANNER not in plain
    assert synthetic.splitlines()[0].startswith("SYNTHETIC")
    assert SYNTHETIC_BANNER in synthetic


def test_an_unknown_label_is_refused(capsys, tmp_path, corpus):
    root, labels = corpus
    labels.write_text("file_a,file_b,label\nzq_a.flac,zq_a_320.mp3,probably_same\n")

    code, _ = run(capsys, corpus)

    assert code == 2


def test_a_missing_file_is_refused(capsys, corpus):
    root, _ = corpus
    (root / "zq_live.flac").unlink()

    code, _ = run(capsys, corpus)

    assert code == 2


@pytest.mark.requires_fpcalc
@pytest.mark.requires_ffmpeg
def test_it_runs_on_a_generated_synthetic_corpus_with_real_fpcalc(capsys, tmp_path):
    from tests.audio_fixtures import RATE, _ff, _melody

    root = tmp_path / "corpus"
    root.mkdir()
    _ff("-f", "lavfi", "-i", _melody(30), "-c:a", "flac", str(root / "m.flac"))
    _ff("-i", str(root / "m.flac"), "-c:a", "libmp3lame", "-b:a", "128k", str(root / "m.mp3"))
    _ff("-f", "lavfi", "-i", f"anullsrc=r={RATE}:cl=stereo:d=30", "-c:a", "flac", str(root / "s.flac"))
    labels = tmp_path / "labels.csv"
    labels.write_text("file_a,file_b,label\nm.flac,m.mp3,same_master\nm.flac,s.flac,unrelated\n")

    code = _load().main([str(root), str(labels), "--synthetic", "--fpcalc", shutil.which("fpcalc")])
    out = capsys.readouterr().out

    assert code == 0
    assert SYNTHETIC_BANNER in out
    assert "same_master: 1" in out and "unrelated: 1" in out


def test_without_positives_fp_possible_says_why(capsys, tmp_path):
    prints = {"zq_a.flac": BASE, "zq_o.flac": random_print(12, 900)}

    _, out = run(capsys, _corpus_of(tmp_path, prints, [("zq_a.flac", "zq_o.flac", "unrelated")]), prints=prints)

    assert "suggested FP_POSSIBLE: none on the grid (no positive pair)" in out
