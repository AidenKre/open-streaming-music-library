"""Phase 7A.2a: the startup storage-reservation reconcile (SC-16e, SC-16g).

No worker survives a restart, so a reservation leased by another boot id is
an orphan of a dead process: startup releases it, after job reclaim and
before any janitor. Reservations of this boot, and durable ones without a
lease, are left alone. The step is idempotent and non-fatal: a failure leaves
orphans counted (more conservative), and the server still starts.
"""

import sqlite3
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.database import DatabaseContext
from app.database.database import Database
from app.services.conversion import reconcile_conversion_jobs
from app.services.storage_ledger import CONVERSION, InsufficientStorage, StorageLedger
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def _ledger(db, tmp_path, boot_id, free=1000):
    return StorageLedger(
        db, path=tmp_path, floor_bytes=0, boot_id=boot_id,
        disk_usage=lambda _p: SimpleNamespace(free=free),
    )


def _rows(db_path):
    conn = sqlite3.connect(db_path)
    try:
        return conn.execute(
            "SELECT subject_ref, lease_boot_id FROM storage_reservations ORDER BY id"
        ).fetchall()
    finally:
        conn.close()


def _insert_unleased(db_path, owner_id):
    conn = sqlite3.connect(db_path)
    try:
        with conn:
            conn.execute(
                "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, "
                "lease_boot_id, created_at) VALUES (?, 'conversion', 'durable', 5, NULL, 1)",
                (owner_id,),
            )
    finally:
        conn.close()


def test_reconcile_releases_dead_leases_and_keeps_this_boots_and_unleased_rows(db, tmp_path):
    dead = _ledger(db, tmp_path, "boot-dead")
    now = _ledger(db, tmp_path, "boot-now")
    dead.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=100, subject_ref="old-1")
    dead.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=100, subject_ref="old-2")
    now.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=100, subject_ref="live")
    _insert_unleased(db.context.database_path, db.owner_id)

    assert now.reconcile() == 2
    assert _rows(db.context.database_path) == [("live", "boot-now"), ("durable", None)]

    # Idempotent: a second run releases nothing more.
    assert now.reconcile() == 0
    assert _rows(db.context.database_path) == [("live", "boot-now"), ("durable", None)]


def test_a_dead_processes_reservation_blocks_until_the_reconcile_releases_it(db, tmp_path):
    _ledger(db, tmp_path, "boot-dead").reserve(
        owner_id=db.owner_id, purpose=CONVERSION, nbytes=900, subject_ref="old"
    )
    now = _ledger(db, tmp_path, "boot-now")

    with pytest.raises(InsufficientStorage):
        now.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=500, subject_ref="new")

    now.reconcile()
    now.reserve(owner_id=db.owner_id, purpose=CONVERSION, nbytes=500, subject_ref="new")
    assert _rows(db.context.database_path) == [("new", "boot-now")]


def test_a_conversion_killed_mid_run_converges_after_restart(db, tmp_path):
    """The job row and its reservation both survive a kill; the conversion
    reconcile fails the job and the storage reconcile releases its bytes."""
    source = tmp_path / "owner" / "song.flac"
    source.parent.mkdir()
    source.write_bytes(b"fake")
    job_id = db.insert_conversion_job("u", "aac", "m4a", 192)
    assert db.mark_conversion_job_running(job_id)
    _ledger(db, tmp_path, "boot-dead").reserve(
        owner_id=db.owner_id, purpose=CONVERSION, nbytes=100, subject_ref=str(job_id)
    )

    reconcile_conversion_jobs(db, tmp_path / ".staging")
    _ledger(db, tmp_path, "boot-now").reconcile()

    assert db.get_conversion_job(job_id)["status"] == "failed"
    assert _rows(db.context.database_path) == []


# --- wired into startup -----------------------------------------------------------------


def _capture_steps(main, monkeypatch):
    captured = []
    real_run = main.run_startup_recovery

    def capture(steps):
        captured.append(list(steps))
        return real_run(steps)

    monkeypatch.setattr(main, "run_startup_recovery", capture)
    return captured


def test_the_reservation_reconcile_is_a_non_fatal_step_after_the_identity_reconcile(
    configure_app, monkeypatch
):
    main = configure_app()
    captured = _capture_steps(main, monkeypatch)

    with TestClient(main.app):
        state = main.app.state
        assert state.conversion_orchestrator.storage_ledger is state.storage_ledger
        assert state.storage_ledger._path == state.settings.music_library_dir
        assert state.storage_ledger._floor == state.settings.storage_free_space_floor_bytes

    [steps] = captured
    assert [(s.name, s.fatal) for s in steps] == [
        ("edit journal", True),
        ("conversion jobs", True),
        ("audio identity", True),
        # 7A.3c: the upload commit journal, before job reclaim (SC-16e).
        ("upload commit journal", False),
        # 8A.3d: the deletion journal, right after the upload one (SC-16e).
        ("deletion journal", False),
        # 7A.2b: receipts settle or release their rows before this reconcile runs.
        ("upload receipts", False),
        # 7A.2c: dead validation leases are re-queued (job reclaim, SC-16e).
        ("upload validation", False),
        # 8A.3d: deletion job reclaim, after the upload one.
        ("deletion jobs", False),
        ("storage reservations", False),
        # 7A.3c: the upload janitor (SC-16e janitors), then 8A.3d's.
        ("upload janitor", False),
        ("deletion janitor", False),
    ]


def test_startup_releases_a_dead_boots_reservation_and_a_second_run_changes_nothing(
    configure_app, monkeypatch
):
    main = configure_app()
    with TestClient(main.app):
        db_path = main.app.state.database.context.database_path
        owner = main.app.state.admin_user_id
    database = Database(DatabaseContext(database_path=db_path, init_sql_path=INIT_SQL))
    StorageLedger(
        database, path=db_path.parent, floor_bytes=0, boot_id="boot-of-a-killed-server",
        disk_usage=lambda _p: SimpleNamespace(free=10**12),
    ).reserve(owner_id=owner, purpose=CONVERSION, nbytes=10**9, subject_ref="1")
    assert len(_rows(db_path)) == 1
    captured = _capture_steps(main, monkeypatch)

    with TestClient(main.app):
        assert _rows(db_path) == []
        [steps] = captured
        [step] = [s for s in steps if s.name == "storage reservations"]
        step.fn()  # a second run inside the live server changes nothing
        assert _rows(db_path) == []


def test_a_failing_reservation_reconcile_does_not_stop_startup(configure_app, monkeypatch):
    main = configure_app()

    def boom(self):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(StorageLedger, "reconcile", boom)

    with TestClient(main.app) as client:
        assert client.get("/").status_code == 200
