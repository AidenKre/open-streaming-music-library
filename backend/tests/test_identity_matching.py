"""Phase 6.5A.3: the worker's matching step (spec §6.4 "Matching"; review
6.5-U10; live cases L12 and the SC-28 row, here at unit level).

The queue now also holds rows with ``match_state='pending'``. A step whose
row still has a pending exact layer computes it; otherwise it matches the
track against its owner's library and refreshes the candidate store. The
digest oracle is the SHA-256 of the file bytes (``identity_worker_fakes``),
so identical bytes are identical audio.
"""

import sqlite3
from itertools import combinations

import pytest

from app.database.database import Database
from app.services import identity_worker
from tests.identity_worker_fakes import T0, FakeClock, make_worker
from tests.identity_worker_fixtures import add_track, identity, make_db, set_identity, sql
from tests.owned_database import add_test_user

V1 = "matcher-v1"


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def copy(db, music, name, content=b"same-audio", owner_id=None, **identity_values):
    path = music / f"{name}.flac"
    path.write_bytes(content)
    return add_track(db, path, owner_id=owner_id, identity=identity_values or None)


def drain(worker, limit=400) -> list[str]:
    """Run steps until the worker goes idle; fail if it never does."""
    outcomes = []
    for _ in range(limit):
        result = worker.process_one()
        if result.outcome == "idle":
            return outcomes
        outcomes.append(result.outcome)
    raise AssertionError(f"worker never went idle: {outcomes[-10:]}")


def pairs(db, owner_id=None):
    query = "SELECT * FROM track_duplicate_candidates"
    params: tuple = ()
    if owner_id is not None:
        query += " WHERE owner_id = ?"
        params = (owner_id,)
    return {(r["uuid_a"], r["uuid_b"]): r for r in sql(db, query, params)}


def canonical(uuids):
    return {tuple(sorted(p)) for p in combinations(uuids, 2)}


def mark_stale(db, uuid_id, reason):
    conn = sqlite3.connect(db.context.database_path)
    try:
        Database._mark_audio_identity_stale_in(conn, uuid_id, reason)
        conn.commit()
    finally:
        conn.close()


def worker_for(db, **kwargs):
    kwargs.setdefault("matcher_version", V1)
    return make_worker(db, **kwargs)


# --- a library converges -----------------------------------------------------------------------


def test_six_identical_copies_give_fifteen_open_exact_pairs(db, music):
    copies = [copy(db, music, f"c{i}") for i in range(6)]
    copy(db, music, "other", content=b"other-audio")

    drain(worker_for(db))

    stored = pairs(db)
    assert set(stored) == canonical(copies)
    assert {(r["kind"], r["band_rank"], r["sort_score"], r["status"], r["matcher_version"])
            for r in stored.values()} == {("exact", 0, 1.0, "open", V1)}
    for uuid_id in copies:
        assert identity(db, uuid_id)["match_state"] == "current"
        assert identity(db, uuid_id)["matcher_version"] == V1


def test_the_fifteen_pairs_are_stable_under_repeated_rematching(db, music):
    copies = [copy(db, music, f"c{i}") for i in range(6)]
    worker = worker_for(db)
    drain(worker)
    before = pairs(db)

    for _ in range(3):
        sql(db, "UPDATE track_audio_identity SET match_state = 'pending'")
        outcomes = drain(worker)
        assert outcomes.count("matched") == 6
        assert pairs(db) == before


def test_more_than_five_matches_never_flap(db, music):
    copies = [copy(db, music, f"c{i}") for i in range(8)]
    worker = worker_for(db)
    drain(worker)
    expected = canonical(copies)

    for uuid_id in copies:
        set_identity(db, uuid_id, match_state="pending")
        drain(worker)
        assert set(pairs(db)) == expected


def test_a_pair_is_found_when_the_second_track_is_processed(db, music):
    x = copy(db, music, "x")
    worker = worker_for(db)
    drain(worker)
    assert pairs(db) == {}

    y = copy(db, music, "y")
    drain(worker)

    assert set(pairs(db)) == canonical([x, y])


# --- isolation between users (SC-28; DEV-6.5-02) ---------------------------------------------


def test_two_users_with_identical_audio_get_no_cross_user_pair(db, music):
    bob = add_test_user(db, "bob")
    mine = [copy(db, music, f"mine{i}") for i in range(2)]
    his = [copy(db, music, f"his{i}", owner_id=bob) for i in range(2)]

    drain(worker_for(db))

    assert set(pairs(db, db.owner_id)) == canonical(mine)
    assert set(pairs(db, bob)) == canonical(his)
    assert len(pairs(db)) == 2


def test_one_copy_per_user_gives_no_pair_at_all(db, music):
    bob = add_test_user(db, "bob")
    copy(db, music, "mine")
    copy(db, music, "his", owner_id=bob)

    drain(worker_for(db))

    assert pairs(db) == {}


# --- unknown is not "no match" ---------------------------------------------------------------


def test_a_pair_survives_its_partner_going_pending_after_a_tag_write(db, music):
    x = copy(db, music, "x")
    y = copy(db, music, "y")
    worker = worker_for(db)
    drain(worker)
    mark_stale(db, y, "tag_write")  # Y: exact pending, digest kept
    set_identity(db, y, next_attempt_at=T0 + 3600)  # Y's recompute is not due yet
    set_identity(db, x, match_state="pending")

    assert drain(worker) == ["matched"]  # only X is processed
    assert identity(db, y)["exact_state"] == "pending"
    assert set(pairs(db)) == canonical([x, y])


def test_a_pair_survives_a_partner_pending_without_a_digest(db, music):
    x = copy(db, music, "x")
    y = copy(db, music, "y")
    worker = worker_for(db)
    drain(worker)
    set_identity(db, y, exact_state="pending", exact_digest=None, exact_kind=None,
                 next_attempt_at=T0 + 3600)
    set_identity(db, x, match_state="pending")

    drain(worker)

    assert set(pairs(db)) == canonical([x, y])


def test_a_partner_reencoded_to_other_audio_drops_the_pair_once_both_are_current(db, music):
    x = copy(db, music, "x")
    y = copy(db, music, "y")
    worker = worker_for(db)
    drain(worker)
    (music / "y.flac").write_bytes(b"re-encoded")
    mark_stale(db, y, "conversion")

    drain(worker)

    assert pairs(db) == {}


def test_a_dismissed_pair_survives_recompute(db, music):
    x = copy(db, music, "x")
    y = copy(db, music, "y")
    worker = worker_for(db)
    drain(worker)
    sql(db, "UPDATE track_duplicate_candidates SET status = 'dismissed', status_changed_at = 5")
    mark_stale(db, x, "conversion")
    mark_stale(db, y, "tag_write")

    drain(worker)

    (stored,) = pairs(db).values()
    assert (stored["status"], stored["status_changed_at"]) == ("dismissed", 5)


# --- the queue -------------------------------------------------------------------------------


def test_a_row_waiting_on_its_exact_layer_is_not_matched_and_does_not_spin(db, music):
    x = copy(db, music, "x", exact_state="pending", next_attempt_at=T0 + 60)

    result = worker_for(db).process_one()

    assert result.outcome == "idle"
    assert identity(db, x)["match_state"] == "pending"


@pytest.mark.parametrize("state", ["failed", "unsupported"])
def test_a_track_without_an_exact_hash_is_still_marked_matched(db, music, state):
    x = copy(db, music, "x", exact_state=state, failure_reason="decode_error")
    worker = worker_for(db)

    assert [worker.process_one().outcome, worker.process_one().outcome] == ["matched", "idle"]
    assert identity(db, x)["match_state"] == "current"
    assert pairs(db) == {}


def test_each_pending_row_takes_one_exact_step_then_one_match_step(db, music):
    for i in range(4):
        copy(db, music, f"c{i}")

    outcomes = drain(worker_for(db))

    assert sorted(outcomes) == ["matched"] * 4 + ["written"] * 4


def test_a_never_retried_row_comes_before_a_due_retry_of_the_same_priority(db, music):
    retry = copy(db, music, "retry", exact_state="pending", next_attempt_at=T0 - 10, attempts=1)
    fresh = copy(db, music, "fresh", exact_state="pending")

    assert worker_for(db, clock=FakeClock(T0)).process_one().uuid_id == fresh
    assert identity(db, retry)["exact_state"] == "pending"


def test_the_queue_read_uses_the_work_index_without_a_sort(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        plan = " | ".join(
            row[3] for row in conn.execute(
                "EXPLAIN QUERY PLAN " + Database._IDENTITY_QUEUE_SQL, (T0,)
            )
        )
    finally:
        conn.close()

    assert "idx_tai_work" in plan
    assert "TEMP B-TREE" not in plan


def test_the_worker_stores_the_matcher_version_it_was_given(db, music):
    x = copy(db, music, "x")
    copy(db, music, "y")

    drain(worker_for(db, matcher_version="custom-v"))

    assert identity(db, x)["matcher_version"] == "custom-v"
    assert {r["matcher_version"] for r in pairs(db).values()} == {"custom-v"}


def test_a_match_raced_by_a_writer_is_discarded_and_redone(db, music, monkeypatch):
    x = copy(db, music, "x")
    y = copy(db, music, "y")
    worker = worker_for(db)
    while worker.process_one().outcome == "written":
        pass  # both exact layers written; the first match step already ran
    sql(db, "DELETE FROM track_duplicate_candidates")
    sql(db, "UPDATE track_audio_identity SET match_state = 'pending'")

    real_find = db.find_duplicates_for_track

    def racing_find(*args, **kwargs):
        found = real_find(*args, **kwargs)
        mark_stale(db, x, "tag_write")  # a writer commits between find and store
        db.find_duplicates_for_track = real_find
        return found

    monkeypatch.setattr(db, "find_duplicates_for_track", racing_find)

    assert worker.process_one().outcome == "discarded"
    assert identity(db, x)["match_state"] == "pending"
    drain(worker)
    assert set(pairs(db)) == canonical([x, y])


# --- review F1: a settled exact layer that comes back is matched again ------------------------


def _converge_with_b_failed(db, music, reason, tools):
    a = copy(db, music, "a")
    b = copy(db, music, "b", exact_state="failed", attempts=3, failure_reason=reason,
             tool_versions=tools)
    worker = worker_for(db)
    drain(worker)  # A is hashed; A and B are matched (B as unknown): no pair yet
    assert identity(db, b)["match_state"] == "current"
    assert pairs(db) == {}
    return a, b, worker


def test_a_failed_track_reset_after_a_tool_change_is_matched_again(db, music):
    from app.services.identity_worker import reconcile_audio_identity

    a, b, worker = _converge_with_b_failed(db, music, "decode_error", "ffmpeg 8.1")

    reconcile_audio_identity(db, tool_versions="ffmpeg 9.0.2", fingerprinter_present=False)
    drain(worker)

    assert set(pairs(db)) == canonical([a, b])


def test_a_missing_master_that_is_back_is_matched_again(db, music):
    from app.services.identity_worker import reconcile_audio_identity
    from tests.identity_worker_fakes import TOOLS

    a, b, worker = _converge_with_b_failed(db, music, "master_missing", TOOLS)

    reconcile_audio_identity(db, tool_versions=TOOLS, fingerprinter_present=False)
    drain(worker)

    assert set(pairs(db)) == canonical([a, b])


# --- review F3, F4: a match step that cannot finish never spins or touches the exact layer -----


def test_a_store_refused_at_an_unchanged_generation_is_set_aside(db, music, monkeypatch):
    x = copy(db, music, "x", exact_state="current", exact_kind="pcm_sha256",
             exact_digest="aa" * 32, sample_rate_hz=44100, channels=2)
    monkeypatch.setattr(db, "store_duplicate_candidates", lambda *a, **k: False)
    worker = worker_for(db)

    assert worker.process_one().outcome == "discarded"
    assert worker.process_one().outcome == "idle"  # not retried in a hot loop
    assert identity(db, x)["match_state"] == "pending"


def test_an_error_in_a_match_step_leaves_the_exact_layer_alone_and_waits(db, music, monkeypatch):
    x = copy(db, music, "x", exact_state="current", exact_kind="pcm_sha256",
             exact_digest="aa" * 32, sample_rate_hz=44100, channels=2)
    before = identity(db, x)

    def boom(*args, **kwargs):
        raise RuntimeError("bad row")

    monkeypatch.setattr(db, "find_duplicates_for_track", boom)
    worker = worker_for(db)

    result = worker.process_one()

    assert result.delay_s > 0
    assert identity(db, x) == before  # no exact attempt, no reset
    assert worker.process_one().outcome == "idle"


def test_the_stores_partner_read_looks_up_this_tracks_pairs_only(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        plan = [row[3] for row in conn.execute(
            "EXPLAIN QUERY PLAN " + Database._CANDIDATE_PARTNERS_SQL, ("u", db.owner_id))]
    finally:
        conn.close()

    assert not any("idx_tdc_list" in step for step in plan), plan
    assert not any(step.startswith("SCAN") for step in plan), plan
