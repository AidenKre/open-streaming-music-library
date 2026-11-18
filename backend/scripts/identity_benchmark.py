"""Fingerprint finder benchmark and storage measurement (Phase 6.5 spec §5, §6.1, §8).

    uv run python scripts/identity_benchmark.py --workdir DIR [--tracks 50000] [--queries 200]

Builds a fresh production-schema database inside an empty --workdir with seeded
synthetic prints and planted near-duplicates, times the real ``find_duplicates``
per query, and measures storage (size, backup, WAL checkpoint, VACUUM). Touches
nothing outside --workdir and the optional --json path.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import random
import shutil
import sqlite3
import sys
import time
import uuid
from dataclasses import asdict
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND))

ALGO = "chromaprint-2"
PLANT_EVERY = 100


def _pct(values: list[float], p: float) -> float:
    s = sorted(values)
    return s[min(len(s) - 1, int(p * len(s)))]


def _timed(fn) -> float:
    t = time.perf_counter()
    fn()
    return time.perf_counter() - t


def _build(db_path: Path, n: int, items: int, seed: int):
    """Insert n tracks (all identity layers current). Returns (uuids, planted {copy: source})."""
    from app.database.database import Database, DatabaseContext, track_path_values
    from app.services.fingerprinter import pack_fingerprint

    Database(DatabaseContext(database_path=db_path, init_sql_path=BACKEND / "app/database/init.sql")).initialize()
    rng = random.Random(seed)
    uuids = [str(uuid.UUID(int=rng.getrandbits(128), version=4)) for _ in range(n)]
    durations = [min(1200.0, max(30.0, rng.gauss(240, 75))) for _ in range(n)]
    prints = [tuple(rng.getrandbits(32) for _ in range(items)) for _ in range(n)]
    planted: dict[int, int] = {}
    for i in (range(PLANT_EVERY - 1, n, PLANT_EVERY) if n >= PLANT_EVERY else [n - 1] if n > 1 else []):
        src = rng.randrange(i)
        prints[i] = tuple(x ^ 3 for x in prints[src])  # 2 low bits flipped: score 0.9375
        durations[i] = max(1.0, durations[src] + rng.uniform(-1, 1))
        planted[i] = src
    conn = sqlite3.connect(db_path)
    try:
        conn.execute("INSERT INTO users (username, username_key, password_hash, library_folder, created_at) "
                     "VALUES ('bench', 'bench', 'unused', 'bench', 0)")
        owner = conn.execute("SELECT id FROM users WHERE username_key = 'bench'").fetchone()[0]
        step = 5000
        for lo in range(0, n, step):
            rows = range(lo, min(n, lo + step))
            conn.executemany(
                "INSERT INTO tracks (id, uuid_id, file_path, file_path_fold, file_folder_fold, owner_id)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                [(i + 1, uuids[i], *track_path_values(f"/bench/{i}.flac"), owner) for i in rows])
            conn.executemany("INSERT INTO trackmetadata (track_id, uuid_id, has_album_art) VALUES (?, ?, 0)",
                             [(i + 1, uuids[i]) for i in rows])
            conn.executemany(
                "INSERT INTO track_audio_identity (uuid_id, generation, exact_state, exact_kind, exact_digest, "
                "fp_state, fp_algorithm, match_state) VALUES (?, 1, 'current', 'pcm_sha256', ?, 'current', ?, 'current')",
                [(uuids[i], f"{rng.getrandbits(256):064x}", ALGO) for i in rows])
            conn.executemany(
                "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
                "VALUES (?, 'bench', ?, ?, ?, ?)",
                [(uuids[i], ALGO, durations[i], items, pack_fingerprint(prints[i])) for i in rows])
            conn.commit()
    finally:
        conn.close()
    return owner, uuids, durations, prints, planted


def _queries(db_path, owner, uuids, durations, prints, planted, n_queries, seed, params):
    from app.services.audio_identity import AudioIdentity, ExactUnavailable, FingerprintIdentity
    from app.services.duplicate_detection import TrackRef, duration_window, find_duplicates

    rng = random.Random(seed + 1)
    copies = sorted(planted)
    chosen = rng.sample(copies, min(len(copies), max(1, n_queries // 4)))
    rest = [i for i in range(len(uuids)) if i not in planted]
    chosen += rng.sample(rest, min(len(rest), n_queries - len(chosen)))
    times, cands, planted_queries, planted_found = [], [], 0, 0
    conn = sqlite3.connect(db_path)
    try:
        for i in chosen:
            fp = FingerprintIdentity("current", "bench", ALGO, durations[i], prints[i])
            identity = AudioIdentity(exact=ExactUnavailable("pending", None), tool_versions=None,
                                     computed_at=0, fingerprint=fp)
            t = time.perf_counter()
            report = find_duplicates(conn, identity, owner_id=owner, exclude=frozenset({uuids[i]}), params=params)
            times.append(time.perf_counter() - t)
            lo, hi = duration_window(durations[i], params)
            cands.append(conn.execute("SELECT COUNT(*) FROM track_audio_fingerprint WHERE duration_s BETWEEN ? AND ?",
                                      (lo, hi)).fetchone()[0])
            if i in planted:
                planted_queries += 1
                planted_found += TrackRef(uuids[planted[i]]) in {m.subject for m in report.matches}
    finally:
        conn.close()
    return {
        "queries": len(chosen), "p50_s": _pct(times, 0.5), "p95_s": _pct(times, 0.95), "max_s": max(times),
        "mean_s": sum(times) / len(times), "candidates_p50": _pct(cands, 0.5),
        "candidates_p95": _pct(cands, 0.95), "candidates_max": max(cands),
        "planted_queries": planted_queries, "planted_found": planted_found,
    }


def _storage(db_path: Path, work: Path) -> dict:
    conn = sqlite3.connect(db_path)
    try:
        rows, blob = conn.execute("SELECT COUNT(*), COALESCE(SUM(length(data)), 0) FROM track_audio_fingerprint").fetchone()
        checkpoint = _timed(lambda: conn.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall())
        db_bytes = os.path.getsize(db_path)
        dest = sqlite3.connect(work / "backup.sqlite")
        backup = _timed(lambda: conn.backup(dest))
        dest.close()
        vacuum = _timed(lambda: conn.execute("VACUUM"))
    finally:
        conn.close()
    shutil.copy(db_path, work / "without_fingerprints.sqlite")
    c2 = sqlite3.connect(work / "without_fingerprints.sqlite")
    try:
        c2.execute("DELETE FROM track_audio_fingerprint")
        c2.commit()
        vacuum_without = _timed(lambda: c2.execute("VACUUM"))
    finally:
        c2.close()
    return {
        "fingerprint_rows": rows, "fingerprint_blob_bytes": blob, "db_bytes": db_bytes,
        "wal_checkpoint_s": checkpoint, "backup_s": backup, "vacuum_s": vacuum,
        "db_bytes_without_fingerprints": os.path.getsize(work / "without_fingerprints.sqlite"),
        "vacuum_without_fingerprints_s": vacuum_without,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--tracks", type=int, default=50000)
    ap.add_argument("--queries", type=int, default=200)
    ap.add_argument("--items", type=int, default=888)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--json")
    ap.add_argument("--skip-storage", action="store_true")
    args = ap.parse_args(argv)
    work = Path(args.workdir)
    if work.exists() and (not work.is_dir() or any(work.iterdir())):
        print("error: --workdir exists and is not empty", file=sys.stderr)
        return 2
    work.mkdir(parents=True, exist_ok=True)

    from app.config import settings
    from app.services.duplicate_detection import MatcherParams

    params = MatcherParams.from_settings(settings)
    db_path = work / "bench.sqlite"
    t0 = time.perf_counter()
    owner, uuids, durations, prints, planted = _build(db_path, args.tracks, args.items, args.seed)
    build_s = time.perf_counter() - t0
    query = _queries(db_path, owner, uuids, durations, prints, planted, args.queries, args.seed, params)
    query.update(tracks=args.tracks, items=args.items, params=asdict(params))
    report = {
        "machine": {"platform": platform.platform(), "processor": platform.processor() or platform.machine(),
                    "cpu_count": os.cpu_count(), "python": platform.python_version()},
        "build_s": build_s, "query": query,
    }
    if not args.skip_storage:
        report["storage"] = _storage(db_path, work)
    print(json.dumps(report, indent=2))
    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
