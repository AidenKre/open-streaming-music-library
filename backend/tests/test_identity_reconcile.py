"""Phase 6.5A.2d: the startup identity reconcile (spec §6.4 "Startup reconcile
step"; review 6.5-U06). Idempotent, non-fatal, bounded on a large library.

In this piece it:
- inserts a pending row (priority 0) for every track that lacks one;
- resets a ``failed`` exact layer whose ``tool_versions`` differ from the
  current ones (a missing tool is not a version change);
- resets a ``master_missing`` row (failed or still backing off) whose master
  now exists.
The fingerprint transitions belong to 6.5B.1b, the matcher re-match to 6.5A.3.
"""

import pytest

from app.services.identity_worker import reconcile_audio_identity
from tests.identity_worker_fakes import TOOLS
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, make_db, sql
from tests.owned_database import add_test_user


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _reconcile(db, tools=TOOLS, fingerprinter_present=False, **kwargs):
    reconcile_audio_identity(db, tool_versions=tools, fingerprinter_present=fingerprinter_present, **kwargs)


def _table(db):
    return sql(db, "SELECT * FROM track_audio_identity ORDER BY uuid_id")


FAILED = {"exact_state": "failed", "attempts": 3, "failure_reason": "decode_error",
          "exact_digest": DIGEST_A, "exact_kind": "pcm_sha256"}
RESET = {"exact_state": "pending", "attempts": 0, "next_attempt_at": None, "failure_reason": None}


def _pick(row, keys):
    return {k: row[k] for k in keys}


@pytest.mark.parametrize("present, fp_state", [(False, "unavailable"), (True, "pending")])
def test_a_track_without_a_row_gets_a_pending_one_first_in_line(db, present, fp_state):
    other_owner = add_test_user(db, "alex")
    mine = add_track(db, "/m/a.flac", identity={"_none": True})
    theirs = add_track(db, "/m/b.flac", owner_id=other_owner, identity={"_none": True})

    _reconcile(db, fingerprinter_present=present)

    for uuid_id in (mine, theirs):
        row = identity(db, uuid_id)
        assert _pick(row, ("exact_state", "fp_state", "match_state", "priority", "attempts",
                           "next_attempt_at", "exact_digest")) == {
            "exact_state": "pending", "fp_state": fp_state, "match_state": "pending",
            "priority": 0, "attempts": 0, "next_attempt_at": None, "exact_digest": None,
        }


def test_existing_rows_are_left_alone(db, music):
    (music / "a.flac").write_bytes(b"x")
    rows = [
        add_track(db, music / "a.flac", identity={"exact_state": "current", "exact_digest": DIGEST_A,
                                                  "exact_kind": "pcm_sha256", "tool_versions": "old"}),
        add_track(db, "/m/b.flac", identity={"exact_state": "unsupported", "tool_versions": "old"}),
        add_track(db, "/m/c.flac", identity={"attempts": 1, "next_attempt_at": 5,
                                             "failure_reason": "decode_error"}),
        add_track(db, "/m/d.flac", identity={**FAILED, "tool_versions": TOOLS}),
    ]
    before = _table(db)
    _reconcile(db)
    assert _table(db) == before
    assert len(rows) == 4


def test_a_failed_row_is_retried_after_a_tool_version_change(db):
    old_tools = add_track(db, "/m/a.flac", identity={**FAILED, "tool_versions": "ffmpeg 8.1"})
    no_tools = add_track(db, "/m/b.flac", identity={**FAILED, "tool_versions": None})
    same = add_track(db, "/m/c.flac", identity={**FAILED, "tool_versions": TOOLS})

    _reconcile(db)

    for uuid_id in (old_tools, no_tools):
        row = identity(db, uuid_id)
        assert _pick(row, RESET) == RESET
        assert row["exact_digest"] == DIGEST_A  # stale-but-safe digest kept
    assert identity(db, same)["exact_state"] == "failed"


def test_a_missing_tool_is_not_a_version_change(db):
    uuid_id = add_track(db, "/m/a.flac", identity={**FAILED, "tool_versions": "ffmpeg 8.1"})
    _reconcile(db, tools=None)
    assert identity(db, uuid_id)["exact_state"] == "failed"


def test_a_missing_master_that_is_back_is_retried(db, music):
    back = music / "back.flac"
    back.write_bytes(b"x")
    failed_back = add_track(db, back, identity={
        **FAILED, "failure_reason": "master_missing", "tool_versions": TOOLS})
    still_gone = add_track(db, music / "gone.flac", identity={
        **FAILED, "failure_reason": "master_missing", "tool_versions": TOOLS})
    backing_off = add_track(db, back, identity={
        "attempts": 2, "next_attempt_at": 9_999_999_999, "failure_reason": "master_missing"})
    other_failure = add_track(db, back, identity={**FAILED, "tool_versions": TOOLS})

    _reconcile(db)

    assert _pick(identity(db, failed_back), RESET) == RESET
    assert _pick(identity(db, backing_off), RESET) == RESET
    assert identity(db, still_gone)["exact_state"] == "failed"
    assert identity(db, other_failure)["exact_state"] == "failed"


def test_reconcile_run_twice_gives_the_same_rows(db, music):
    back = music / "back.flac"
    back.write_bytes(b"x")
    add_track(db, "/m/a.flac", identity={"_none": True})
    add_track(db, "/m/b.flac", identity={**FAILED, "tool_versions": "ffmpeg 8.1"})
    add_track(db, back, identity={**FAILED, "failure_reason": "master_missing", "tool_versions": TOOLS})
    add_track(db, music / "gone.flac", identity={
        **FAILED, "failure_reason": "master_missing", "tool_versions": TOOLS})

    _reconcile(db)
    once = _table(db)
    _reconcile(db)
    assert _table(db) == once


def test_the_missing_master_sweep_works_in_batches(db, music):
    rows = []
    for i in range(7):
        path = music / f"{i}.flac"
        path.write_bytes(b"x")
        rows.append(add_track(db, path, identity={
            **FAILED, "failure_reason": "master_missing", "tool_versions": TOOLS}))

    _reconcile(db, batch_size=3)

    assert all(identity(db, u)["exact_state"] == "pending" for u in rows)


def test_a_reconcile_failure_never_stops_startup(db, monkeypatch, caplog):
    add_track(db, "/m/a.flac", identity={"_none": True})

    def boom(*args, **kwargs):
        raise RuntimeError("disk on fire")

    for name in ("insert_missing_identity_rows", "reset_failed_identity_rows",
                 "list_master_missing_identity", "reset_master_missing_identity"):
        monkeypatch.setattr(db, name, boom)

    _reconcile(db)  # does not raise
    assert caplog.records


@pytest.mark.parametrize("name", [
    "insert_missing_identity_rows", "reset_failed_identity_rows",
    "list_master_missing_identity", "reset_master_missing_identity",
])
def test_the_reconcile_primitives_take_any_owner_only(db, name):
    import inspect

    method = getattr(db, name)
    params = inspect.signature(method).parameters
    assert params["owner_id"].kind is inspect.Parameter.KEYWORD_ONLY
    args = {"insert_missing_identity_rows": dict(fingerprinter_present=False),
            "reset_failed_identity_rows": dict(tool_versions=TOOLS),
            "list_master_missing_identity": {},
            "reset_master_missing_identity": dict(uuids=[])}[name]
    with pytest.raises(TypeError):
        method(**args, owner_id=db.owner_id)
