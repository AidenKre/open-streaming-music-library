"""Phase 8A.3d S5 (SC-16e with DEV-7-07, plan D12 and O4): the three deletion
steps in the startup recovery registry.

- Order: "deletion journal" right after "upload commit journal" (journals
  before job reclaim), "deletion jobs" right after "upload validation" (job
  reclaim per type), "deletion janitor" right after "upload janitor"
  (janitors last). All three are non-fatal.
- A failing deletion step is logged and does not stop the later steps or the
  start; the journal it could not resolve stays, so the track stays hidden.
- Wiring: a deletion a dead server left in quarantine is put back at the next
  start (the steps get the real database, library folder and caches).
"""

import sqlite3

import pytest
from fastapi.testclient import TestClient

from app.database import DatabaseContext
from app.database.database import Database
from app.library import Library
from app.models.deletions import DeletionJobRequest
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import deletion_recovery
from app.services.deletion_worker import DeletionExecutor
from app.services.track_locks import TrackLocks
from app.services.upload_publish import SimulatedCrash
from tests.deletion_world import SpyCache
from tests.recovery_steps import capture_steps, named
from tests.schema_fixtures import INIT_SQL

def test_the_deletion_steps_sit_in_the_registry_in_their_stated_order(configure_app, monkeypatch):
    main = configure_app()
    captured = capture_steps(main, monkeypatch)

    with TestClient(main.app):
        pass

    [steps] = captured
    names = named(steps)
    # The full order: tests/test_startup_recovery_order.py. Here, the three
    # deletion steps' places next to their neighbours (SC-16e).
    at = names.index(("deletion journal", False))
    assert names[at - 1 : at + 2] == [
        ("upload commit journal", False), ("deletion journal", False), ("upload receipts", False),
    ]
    at = names.index(("deletion jobs", False))
    assert names[at - 1 : at + 2] == [
        ("upload validation", False), ("deletion jobs", False), ("storage reservations", False),
    ]
    assert names[-1] == ("deletion janitor", False)


def test_the_factory_gives_the_three_steps_in_order(tmp_path):
    database = Database(DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
    assert database.initialize()

    steps = deletion_recovery.startup_steps(
        database,
        music_library_dir=tmp_path / "music",
        track_locks=TrackLocks(),
        cover_art=None,
        cache=SpyCache(),
        default_cache=SpyCache(),
        boot_id="boot",
    )

    assert [(s.name, s.fatal) for s in steps] == [
        ("deletion journal", False),
        ("deletion jobs", False),
        ("deletion janitor", False),
    ]


@pytest.mark.parametrize(
    "target",
    [
        (deletion_recovery, "reconcile_deletion_journals"),
        (deletion_recovery, "reclaim_deletion_items"),
        (deletion_recovery.DeletionJanitor, "run_startup_pass"),
    ],
)
def test_a_failing_deletion_step_never_stops_the_start_or_the_later_steps(
    configure_app, monkeypatch, target
):
    main = configure_app()
    captured = capture_steps(main, monkeypatch)
    ran = []

    def boom(*args, **kwargs):
        raise RuntimeError("/music/owner/secret.flac")

    monkeypatch.setattr(*target, boom)
    real_janitor = main.upload_janitor.UploadJanitor.run_once

    def upload_janitor_ran(self):
        ran.append("upload janitor")
        return real_janitor(self)

    monkeypatch.setattr(main.upload_janitor.UploadJanitor, "run_once", upload_janitor_ran)

    with TestClient(main.app) as client:
        assert client.get("/app/info").status_code == 200

    assert captured and ran == ["upload janitor"]


def _plant_crashed_deletion(db_path, owner, root, music):
    database = Database(DatabaseContext(database_path=db_path, init_sql_path=INIT_SQL))
    master = root / "Portishead" / "Dummy" / "01 Mysterons.flac"
    master.parent.mkdir(parents=True)
    master.write_bytes(b"a master the dead server was deleting")
    track = Track(
        file_path=master,
        metadata=TrackMetaData(title="Mysterons", artist="Portishead", album="Dummy",
                               codec="flac", duration=1.0),
    )
    library = Library(database, owner)
    assert library.add_track(track=track)
    revision = sqlite3.connect(db_path).execute(
        "SELECT revision FROM tracks WHERE uuid_id = ?", (track.uuid_id,)
    ).fetchone()[0]
    op = "11111111-2222-4333-8444-555555555555"
    assert library.create_deletion_job(
        DeletionJobRequest.model_validate({
            "operation_uuid": op,
            "targets": [{"uuid_id": track.uuid_id, "base_revision": revision}],
            "confirmed_count": 1,
        }),
        now=1,
    )

    def seam(name):
        if name == "after_moved":
            raise SimulatedCrash(name)

    executor = DeletionExecutor(
        database, music_library_dir=music, track_locks=TrackLocks(), cover_art=None,
        cache=SpyCache(), default_cache=SpyCache(), boot_id="dead-boot", seam=seam,
    )
    with pytest.raises(SimulatedCrash):
        executor.run_one()
    assert not master.exists()
    return track.uuid_id, master, revision


def test_a_deletion_a_dead_server_left_in_quarantine_is_put_back_at_the_next_start(
    configure_app, tmp_path
):
    main = configure_app()
    with TestClient(main.app):
        db_path = main.app.state.database.context.database_path
        owner = main.app.state.admin_user_id
        root = main.app.state.admin_library.root
    uuid_id, master, revision = _plant_crashed_deletion(db_path, owner, root, tmp_path / "music")

    with TestClient(main.app):
        pass

    conn = sqlite3.connect(db_path)
    try:
        assert conn.execute("SELECT count(*) FROM deletion_journal").fetchone()[0] == 0
        assert conn.execute(
            "SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()[0] == revision
        assert conn.execute(
            "SELECT status FROM deletion_job_items WHERE uuid_id = ?", (uuid_id,)
        ).fetchone()[0] == "pending"
    finally:
        conn.close()
    assert master.read_bytes() == b"a master the dead server was deleting"
