"""Phase 6.5A.3 regression guards (review 6.5-U09, U10).

- Every statement ``find_duplicates`` runs is served by an index: the exact
  lookup by ``idx_tai_exact`` (never a scan of the identity table) and the
  owner's coverage counts through the owner index on ``tracks``.
- Deleting a track (``delete_track``) cascades its identity row and every
  candidate pair it is in; the other pairs stay.
"""

import sqlite3

import pytest

from app.services.audio_identity import KIND_PCM, AudioIdentity, ExactAudioHash
from app.services.duplicate_detection import find_duplicates
from tests.identity_worker_fakes import make_worker
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, make_db, sql
from tests.owned_database import add_test_user


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


def test_every_finder_statement_uses_an_index_and_never_scans(db):
    bob = add_test_user(db, "bob")
    for i in range(20):
        add_track(db, f"/m/{i}.flac", owner_id=bob if i % 2 else None, identity={
            "exact_state": "current", "exact_kind": KIND_PCM, "exact_digest": f"{i:064x}",
            "sample_rate_hz": 44100, "channels": 2})
    conn = sqlite3.connect(db.context.database_path)  # no ANALYZE, as in production
    statements: list[str] = []
    conn.set_trace_callback(statements.append)
    subject = AudioIdentity(ExactAudioHash(KIND_PCM, DIGEST_A, 44100, 2, 16), None, 0)
    try:
        find_duplicates(conn, subject, owner_id=db.owner_id, exclude=frozenset({"x"}))
        conn.set_trace_callback(None)
        selects = [s for s in statements if s.lstrip().upper().startswith("SELECT")]
        assert len(selects) == 2  # the exact lookup and one coverage aggregate
        plans = [
            [row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + s)] for s in selects
        ]
    finally:
        conn.close()

    lookup, coverage = plans
    assert any("idx_tai_exact" in step for step in lookup), lookup
    for plan in plans:
        assert not any(step.startswith("SCAN") for step in plan), plan
        assert not any("TEMP B-TREE" in step for step in plan), plan
    assert any("owner_id=?" in step for step in coverage), coverage


def test_deleting_a_track_cascades_its_pairs_and_keeps_the_others(db, tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    copies = []
    for name in ("a", "b", "c"):
        path = music / f"{name}.flac"
        path.write_bytes(b"same")
        copies.append(add_track(db, path))
    worker = make_worker(db, matcher_version="v")
    for _ in range(20):
        worker.process_one()
    assert len(sql(db, "SELECT * FROM track_duplicate_candidates")) == 3

    assert db.delete_track(copies[0]) is True

    remaining = sql(db, "SELECT uuid_a, uuid_b FROM track_duplicate_candidates")
    assert [tuple(sorted(r.values())) for r in remaining] == [tuple(sorted(copies[1:]))]
    assert identity(db, copies[0]) is None
