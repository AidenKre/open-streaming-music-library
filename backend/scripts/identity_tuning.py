"""Fingerprint threshold tuning (Phase 6.5 spec §8).

    uv run python scripts/identity_tuning.py <corpus_dir> <labels.csv> [--synthetic] [--fpcalc PATH]

labels.csv has the header ``file_a,file_b,label`` (paths relative to corpus_dir).
Scores each labelled pair with the production comparator and prints the corpus
composition, per-label score distributions, precision/recall per threshold and the
suggested FP_STRONG (lowest step no scored negative reaches) and FP_POSSIBLE (highest
step keeping at least 99% of the positives, capped at FP_STRONG). Pairs are scored
with the finder's duration-aware search. Never prints a file name or the corpus path.
"""

from __future__ import annotations

import argparse
import csv
import shutil
import statistics
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

POSITIVE = ("same_master", "different_rip", "remaster", "compilation")
NEGATIVE = ("live_vs_studio", "edit", "cover", "classical_performance", "mix_segments",
            "shared_intro", "speech", "drone", "unrelated")
GRID = [round(i / 100, 2) for i in range(50, 101)]


class _Refused(Exception):
    pass


def _read_labels(corpus: Path, labels_csv: Path) -> list[tuple[str, str, str]]:
    try:
        with open(labels_csv, newline="", encoding="utf-8") as fh:
            reader = csv.reader(fh)
            if next(reader, None) != ["file_a", "file_b", "label"]:
                raise _Refused("labels.csv must start with the header file_a,file_b,label")
            rows = []
            for n, row in enumerate(reader, start=2):
                if not row:
                    continue
                if len(row) != 3 or not all(c.strip() for c in row):
                    raise _Refused(f"labels.csv line {n}: malformed row")
                a, b, label = (c.strip() for c in row)
                if label not in POSITIVE + NEGATIVE:
                    raise _Refused(f"labels.csv line {n}: unknown label")
                if not (corpus / a).is_file() or not (corpus / b).is_file():
                    raise _Refused(f"labels.csv line {n}: a named file is missing")
                rows.append((a, b, label))
    except (OSError, UnicodeDecodeError, csv.Error):
        raise _Refused("cannot read labels.csv") from None
    if not rows:
        raise _Refused("labels.csv has no pairs")
    return rows


def _fmt_stats(scores: list[float]) -> str:
    s = sorted(scores)
    q = statistics.quantiles(s, n=4, method="inclusive") if len(s) > 1 else [s[0]] * 3
    return "  ".join(f"{k} {v:.3f}" for k, v in zip(("min", "p25", "median", "p75", "max"), [s[0], *q, s[-1]]))


def _build_fingerprinter(fpcalc: str | None):
    from app.config import settings
    from app.services.fingerprinter import FpcalcFingerprinter, probe_fpcalc_version

    path = fpcalc or shutil.which("fpcalc")
    if not path:
        raise _Refused("fpcalc not found; pass --fpcalc PATH")
    return FpcalcFingerprinter(path, probe_fpcalc_version(path) or "unknown", timeout_s=settings.fpcalc_timeout_s)


def main(argv=None, *, fingerprinter=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("corpus_dir")
    ap.add_argument("labels_csv")
    ap.add_argument("--synthetic", action="store_true")
    ap.add_argument("--fpcalc")
    args = ap.parse_args(argv)

    from app.config import settings
    from app.services.audio_identity import FingerprintIdentity, FingerprintUnavailable, compute_fingerprint
    from app.services.duplicate_detection import MatcherParams, compare_fingerprints, within_duration_window

    corpus = Path(args.corpus_dir)
    try:
        pairs = _read_labels(corpus, Path(args.labels_csv))
        fingerprinter = fingerprinter or _build_fingerprinter(args.fpcalc)
    except _Refused as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    params = MatcherParams.from_settings(settings)

    prints: dict[str, str | FingerprintIdentity] = {}
    for name in sorted({n for a, b, _ in pairs for n in (a, b)}):
        fp = compute_fingerprint(corpus / name, fingerprinter, params=params)
        if isinstance(fp, FingerprintUnavailable):
            prints[name] = "failed"
        else:
            prints[name] = fp if fp.state == "current" else fp.state

    scores: dict[str, list[float]] = {}
    unscored: dict[str, Counter] = {}
    results = []  # (label, score or None)
    for a, b, label in pairs:
        pa, pb = prints[a], prints[b]
        score = None
        if isinstance(pa, FingerprintIdentity) and isinstance(pb, FingerprintIdentity):
            if not within_duration_window(pa.duration_s, pb.duration_s, params):
                unscored.setdefault(label, Counter())["outside_duration_window"] += 1
            elif (cmp := compare_fingerprints(pa.items, pb.items, params, duration_a_s=pa.duration_s,
                                              duration_b_s=pb.duration_s)) is None:
                unscored.setdefault(label, Counter())["not_comparable"] += 1
            else:
                score = cmp.score
                scores.setdefault(label, []).append(score)
        else:
            for p in (pa, pb):
                if not isinstance(p, FingerprintIdentity):
                    unscored.setdefault(label, Counter())[p] += 1
        results.append((label, score))

    out = print
    if args.synthetic:
        out("SYNTHETIC corpus: synthetic; not a threshold validation")
    out(f"fingerprinter: {fingerprinter.name} {fingerprinter.tool_version} ({fingerprinter.algorithm})")
    out(f"current FP_STRONG {params.strong}  FP_POSSIBLE {params.possible}")
    out("\ncorpus composition (pairs per label):")
    counts = Counter(label for _, _, label in pairs)
    for label in POSITIVE + NEGATIVE:
        if label in counts:
            out(f"  {label}: {counts[label]} ({'positive' if label in POSITIVE else 'negative'})")
    out("\nprint states (distinct files): " + ", ".join(f"{k} {v}" for k, v in sorted(
        Counter(p if isinstance(p, str) else "current" for p in prints.values()).items())))
    out("\nper-label scores:")
    for label in POSITIVE + NEGATIVE:
        if label not in counts:
            continue
        extra = ", ".join(f"{k} {v}" for k, v in sorted(unscored.get(label, {}).items()))
        stats = _fmt_stats(scores[label]) if label in scores else "no scored pairs"
        out(f"  {label}: n {len(scores.get(label, []))}  {stats}" + (f"  not scored: {extra}" if extra else ""))

    positives = [s for l, s in results if l in POSITIVE]
    negatives = [(l, s) for l, s in results if l in NEGATIVE and s is not None]
    out("\nthreshold  (matched = score >= threshold; the finder's duration window is applied; unscored positives are FN)")
    for t in GRID:
        tp = sum(1 for s in positives if s is not None and s >= t)
        fp = sum(1 for _, s in negatives if s >= t)
        fn = len(positives) - tp
        prec = f"{tp / (tp + fp):.3f}" if tp + fp else "n/a"
        rec = f"{tp / len(positives):.3f}" if positives else "n/a"
        out(f"{t:.2f}  TP {tp}  FP {fp}  FN {fn}  precision {prec}  recall {rec}")

    strong = None
    if negatives:
        strong = next((t for t in GRID if not any(s >= t for _, s in negatives)), None)
        out(f"\nsuggested FP_STRONG: {strong:.2f}" if strong is not None else "\nsuggested FP_STRONG: none on the grid")
    else:
        out("\nsuggested FP_STRONG: none (no negative pair was scored)")
    # Highest step keeping at least 99% of the positives (unscored ones are misses).
    def keeps_99_percent(t):
        tp = sum(1 for s in positives if s is not None and s >= t)
        return 100 * tp >= 99 * len(positives)

    recall = next((t for t in reversed(GRID) if keeps_99_percent(t)), None) if positives else None
    # FP_POSSIBLE may not exceed FP_STRONG: the suggested one, else the configured one.
    cap = strong if strong is not None else params.strong
    if not positives:
        out("suggested FP_POSSIBLE: none on the grid (no positive pair)")
    elif recall is None:
        unscored_n = sum(1 for s in positives if s is None)
        why = f" ({unscored_n} of {len(positives)} positive pairs not scored)" if unscored_n else ""
        out(f"suggested FP_POSSIBLE: none on the grid{why}")
    if recall is not None:
        possible = min(recall, cap)
        if recall > cap:
            out(f"suggested FP_POSSIBLE: {possible:.2f} (capped at FP_STRONG; "
                f"99% of positives kept up to {recall:.2f})")
        else:
            out(f"suggested FP_POSSIBLE: {possible:.2f}")
        above = Counter(l for l, s in negatives if s >= possible)
        listed = ", ".join(f"{l} {above[l]}" for l in NEGATIVE if l in above)
        out(f"negatives at or above FP_POSSIBLE {possible:.2f}: {listed or 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
