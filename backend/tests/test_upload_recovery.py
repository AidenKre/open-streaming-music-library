"""7A.3c S2 (spec §6 "Restart before accepting new commit work", SC-16e,
7-U07): the startup commit-journal step resumes a ``prepared`` or ``moved``
journal from its frozen metadata by running the publisher again, so a crash at
any boundary between the prepared journal and the DB commit ends in exactly one
imported track, at the journaled final path, with its art. A ``committing``
journal is left to the commit worker, which re-claims it."""

import os
import sqlite3

import pytest
from fastapi.testclient import TestClient

from tests.identity_worker_fixtures import make_db, sql
from tests.upload_commit_fixtures import journal
from tests.upload_publish_fixtures import track_row
from tests.upload_recovery_fixtures import World, art_ids
from tests.upload_validation_fixtures import item_row

# Every boundary after which a prepared/moved journal exists and nothing is inserted.
RESUME_POINTS = ["after_prepared_journal", "before_link", "after_link", "after_moved_journal",
                 "after_work_unlink", "before_insert_commit"]


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def tracks_named(db, track_uuid: str, path: str) -> list:
    return sql(db, "SELECT uuid_id FROM tracks WHERE uuid_id = ? OR file_path = ?", (track_uuid, path))


def assert_imported_once(world, commit, final: str):
    db = world.db
    assert item_row(db, commit)["state"] == "imported"
    assert item_row(db, commit)["result_track_uuid"] == commit["track"]
    assert tracks_named(db, commit["track"], final) == [{"uuid_id": commit["track"]}]
    assert track_row(db, commit["track"])["file_path"] == final
    with open(final, "rb") as f:
        assert f.read() == commit["content"]
    assert not commit["work"].exists()
    [meta] = sql(db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (commit["track"],))
    assert meta["cover_art_id"] is not None
    assert meta["cover_art_id"] in art_ids(db)


@pytest.mark.parametrize("point", RESUME_POINTS)
def test_a_crash_before_the_insert_resumes_into_exactly_one_import(world, point):
    commit = world.crash_at(point)
    final = journal(world.db, commit)["final_path"]
    assert journal(world.db, commit)["state"] in ("prepared", "moved")

    world.recover()

    assert_imported_once(world, commit, final)


@pytest.mark.parametrize("point", RESUME_POINTS)
def test_restarting_twice_changes_nothing_more(world, point):
    commit = world.crash_at(point)
    final = journal(world.db, commit)["final_path"]

    world.restart()
    world.restart()

    assert_imported_once(world, commit, final)
    assert len(art_ids(world.db)) == 1


def test_a_committing_journal_is_left_to_the_worker(world):
    commit = world.crash_at("after_work_fsync")

    world.recover()

    assert journal(world.db, commit)["state"] == "committing"
    assert item_row(world.db, commit)["state"] == "committing"
    assert commit["work"].exists()

    world.restart()

    final = track_row(world.db, commit["track"])["file_path"]
    assert_imported_once(world, commit, final)


@pytest.mark.parametrize("point", ["after_prepared_journal", "after_moved_journal", "before_insert_commit"])
def test_art_released_meanwhile_is_resolved_again_from_the_file(world, point):
    commit = world.crash_at(point)
    old = journal(world.db, commit)["cover_art_id"]
    assert old is not None
    world.cover_art.release_if_unreferenced(old)  # released meanwhile (SC-16h)
    assert art_ids(world.db) == []

    world.restart()

    [meta] = sql(world.db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (commit["track"],))
    assert meta["cover_art_id"] is not None and meta["cover_art_id"] != old
    assert art_ids(world.db) == [meta["cover_art_id"]]


def test_the_step_skips_a_journal_of_another_state_and_survives_a_bad_row(world, monkeypatch):
    """One unreadable row is logged and the rest still recover."""
    bad = world.crash_at("before_link")
    good = world.crash_at("before_link")
    sql(world.db, "UPDATE upload_commit_journal SET final_metadata = 'not json'"
                  " WHERE owner_id = ? AND operation_uuid = ?", (bad["owner_id"], bad["op"]))

    world.recover()

    assert item_row(world.db, good)["state"] == "imported"
    assert item_row(world.db, bad)["state"] != "imported"
    assert track_row(world.db, bad["track"]) is None


# ---- the registry step (app level) ----

def _capture_steps(main, monkeypatch):
    captured = []
    real = main.run_startup_recovery

    def capture(steps):
        captured.append(list(steps))
        return real(steps)

    monkeypatch.setattr(main, "run_startup_recovery", capture)
    return captured


def test_the_journal_step_is_non_fatal_after_the_identity_reconcile_and_before_job_reclaim(
    configure_app, monkeypatch
):
    main = configure_app()
    captured = _capture_steps(main, monkeypatch)

    with TestClient(main.app):
        pass

    [steps] = captured
    names = [(s.name, s.fatal) for s in steps]
    at = names.index(("upload commit journal", False))
    assert names[at - 1] == ("audio identity", True)
    # 8A.3d: the deletion journal follows it, then the receipts.
    assert names[at + 1 : at + 3] == [("deletion journal", False), ("upload receipts", False)]


def test_startup_resumes_a_prepared_journal_with_the_real_publisher(configure_app, tmp_path):
    """Wiring: a prepared journal left by a dead server is imported at the next
    start (digest check 'unverified', so no decoder runs)."""
    main = configure_app()
    with TestClient(main.app):
        db_path = main.app.state.database.context.database_path
        owner = main.app.state.admin_user_id
        root = main.app.state.admin_library.root
    content = b"audio-bytes-for-wiring"
    music = tmp_path / "music"
    item_dir = music / ".uploads" / str(owner) / "b" / "i"
    item_dir.mkdir(parents=True)
    (item_dir / "source").write_bytes(content)
    work = item_dir / "work-op.flac"
    work.write_bytes(content)
    final = root / "Radiohead" / "OK Computer" / "Airbag-t.flac"
    op = "6f1f0d2e-1b2c-4d3e-8f4a-5b6c7d8e9f00"
    item = "7a1f0d2e-1b2c-4d3e-8f4a-5b6c7d8e9f00"
    batch = "8b1f0d2e-1b2c-4d3e-8f4a-5b6c7d8e9f00"
    track = "9c1f0d2e-1b2c-4d3e-8f4a-5b6c7d8e9f00"
    conn = sqlite3.connect(db_path)
    try:
        with conn:
            conn.execute("INSERT INTO upload_batches (owner_id, batch_uuid, created_at, updated_at)"
                         " VALUES (?, ?, 1, 1)", (owner, batch))
            conn.execute(
                "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, selection_index,"
                " expected_bytes, expected_sha256, received_bytes, source_path, state,"
                " reserved_track_uuid, kind, created_at, updated_at, progress_at)"
                " VALUES (?, ?, ?, 'a.flac', 0, ?, ?, ?, ?, 'committing', ?, 'audio', 1, 1, 1)",
                (owner, item, batch, len(content), "0" * 64, len(content), str(item_dir / "source"), track))
            conn.execute("INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash,"
                         " created_at, result_ref) VALUES (?, ?, 'upload_commit', ?, 1, ?)",
                         (owner, op, "1" * 64, item))
            conn.execute(
                "INSERT INTO upload_commit_journal (owner_id, operation_uuid, item_uuid, state,"
                " base_review_version, reserved_track_uuid, edits, write_tags, acknowledged_duplicates,"
                " source_path, work_path, final_path, final_metadata, exact_state, failure_reason,"
                " fp_state, digest_check, created_at, updated_at)"
                " VALUES (?, ?, ?, 'prepared', 0, ?, '{}', 0, '{\"library_tracks\":[],\"staged_items\":[]}',"
                " ?, ?, ?, ?, 'failed', 'decode_failed', 'unavailable', 'unverified', 1, 1)",
                (owner, op, item, track, str(item_dir / "source"), str(work), str(final),
                 '{"v":1,"title":"Airbag","artist":"Radiohead","album":"OK Computer","codec":"flac"}'))
    finally:
        conn.close()

    with TestClient(configure_app().app) as client:
        database = client.app.state.database
        with database._connection() as c:
            state = c.execute("SELECT state FROM upload_items WHERE item_uuid = ?", (item,)).fetchone()[0]
            path = c.execute("SELECT file_path FROM tracks WHERE uuid_id = ?", (track,)).fetchone()

    assert state == "imported"
    assert path is not None and path[0] == str(final)
    assert final.read_bytes() == content
    assert not os.path.exists(work)
