"""Phase 6.5B.2b: ``backend/scripts/identity_benchmark.py`` (spec §5 "Cost", §6.1
storage note, §8 6.5B.2 row; review 6.5-U12 performance half).

The script builds a fresh database in an empty work directory (production
schema), fills it with N synthetic tracks with stored prints (seeded), plants
known near-duplicates, times ``find_duplicates`` per query (p50/p95/max), and
measures storage: database size, the fingerprint blobs' share, an online
backup, a WAL checkpoint and VACUUM. The full run (50k) is made by hand; this
test runs a small version and checks the report's shape and its correctness
oracle (every planted duplicate is found).
"""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "identity_benchmark.py"


def _load():
    spec = importlib.util.spec_from_file_location("identity_benchmark", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def small_run(tmp_path):
    work = tmp_path / "bench"
    out = tmp_path / "report.json"
    code = _load().main(["--workdir", str(work), "--tracks", "300", "--queries", "6",
                         "--items", "300", "--seed", "7", "--json", str(out)])
    return code, json.loads(out.read_text()), work


def test_a_small_run_reports_query_latency(small_run):
    code, report, _ = small_run

    assert code == 0
    q = report["query"]
    assert q["tracks"] == 300 and q["queries"] == 6
    assert 0 < q["p50_s"] <= q["p95_s"] <= q["max_s"]
    assert q["candidates_p50"] >= 0 and q["candidates_max"] >= q["candidates_p50"]
    assert report["machine"]  # the named machine the numbers came from


def test_every_planted_duplicate_is_found(small_run):
    _, report, _ = small_run

    q = report["query"]
    assert q["planted_queries"] >= 1
    assert q["planted_found"] == q["planted_queries"]


def test_storage_is_measured(small_run):
    _, report, _ = small_run

    s = report["storage"]
    assert s["fingerprint_rows"] == 300
    assert s["fingerprint_blob_bytes"] == 300 * 300 * 4
    assert s["db_bytes"] > s["fingerprint_blob_bytes"]
    assert s["db_bytes_without_fingerprints"] < s["db_bytes"]
    for key in ("backup_s", "vacuum_s", "wal_checkpoint_s"):
        assert s[key] >= 0


def test_it_refuses_a_work_directory_that_is_not_empty(tmp_path):
    work = tmp_path / "bench"
    work.mkdir()
    (work / "something.sqlite").write_bytes(b"keep me")

    code = _load().main(["--workdir", str(work), "--tracks", "10", "--queries", "1"])

    assert code == 2
    assert (work / "something.sqlite").read_bytes() == b"keep me"
