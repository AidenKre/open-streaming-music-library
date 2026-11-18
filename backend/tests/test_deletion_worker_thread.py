"""Phase 8A.3c (spec §5 "Durable worker claiming", SC-16d; plan row: one
bounded thread, started after the recovery registry, stopped at shutdown with
the instance lock kept while it is alive): the deletion worker runs on the
shared worker-thread base (``services/worker_thread.py``) and is one line of
``main._background_workers``.

- ``process_one`` runs one target through the executor: "done" when it ran
  one, "idle" when nothing is pending, "error" (type name logged only) when
  the executor raised.
- In the app: a job accepted through the API is executed after the worker is
  woken; an accepted job also runs when the operator switch is off.

Waits are bounded events, never sleeps.
"""

import logging
import threading

import pytest
from fastapi.testclient import TestClient

from app.services import deletion_worker as deletion_worker_mod
from app.services.deletion_worker import DeletionWorker, RunResult
from app.services.worker_thread import PollingWorkerThread
from tests.deletion_world import accept_job, item

WAIT_S = 30


# ── the thread on the shared base ──────────────────────────────────────────


class _Executor:
    def __init__(self, answers):
        self.answers = list(answers)
        self.calls = 0

    def run_one(self):
        self.calls += 1
        answer = self.answers.pop(0)
        if isinstance(answer, BaseException):
            raise answer
        return answer


def test_the_worker_is_a_polling_worker_on_the_shared_base():
    assert issubclass(DeletionWorker, PollingWorkerThread)


def test_process_one_reports_done_idle_and_error(caplog):
    executor = _Executor([RunResult.DONE, RunResult.IDLE, RuntimeError("/music/owner/secret.flac")])
    worker = DeletionWorker(executor, idle_poll_s=60)

    assert worker.process_one() == "done"
    assert worker.process_one() == "idle"
    with caplog.at_level(logging.WARNING):
        assert worker.process_one() == "error"

    assert executor.calls == 3
    assert "RuntimeError" in caplog.text
    assert "secret" not in caplog.text  # never the message, which can hold a path


def test_a_started_worker_runs_until_idle_and_stops():
    ran = threading.Event()

    class Executor:
        def __init__(self):
            self.left = 2

        def run_one(self):
            if self.left:
                self.left -= 1
                return RunResult.DONE
            ran.set()
            return RunResult.IDLE

    worker = DeletionWorker(Executor(), idle_poll_s=60)
    worker.start()
    try:
        assert ran.wait(WAIT_S)
    finally:
        assert worker.stop(timeout=WAIT_S)
    assert not worker.is_alive()


# ── the app ────────────────────────────────────────────────────────────────


class _World:
    def __init__(self, client):
        self.db = client.app.state.database
        self.owner = client.app.state.admin_library.owner_id


def _add(client):
    from app.models.track import Track
    from app.models.track_meta_data import TrackMetaData

    music = client.app.state.settings.music_library_dir
    folder = music / "admin" / "Art"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "song.flac"
    path.write_bytes(b"fake-audio-bytes")
    track = Track(file_path=path, metadata=TrackMetaData(codec="flac", duration=1.0, title="T"))
    db = client.app.state.database
    owner = client.app.state.admin_library.owner_id
    assert db.add_track(track, owner_id=owner)
    return db.get_track_by_uuid(track.uuid_id, owner_id=owner)


@pytest.fixture
def executed(monkeypatch):
    """An event set after the app's executor finished a target."""
    event = threading.Event()
    real = deletion_worker_mod.DeletionExecutor.execute

    def execute(self, target):
        try:
            return real(self, target)
        finally:
            event.set()

    monkeypatch.setattr(deletion_worker_mod.DeletionExecutor, "execute", execute)
    return event


def _client(open_app_client, *, switch):
    return open_app_client(env={
        "ENABLE_DELETION_WORKER": "true",
        "LIBRARY_DELETE_ENABLED": "true" if switch else "false",
    })


def test_a_job_accepted_through_the_api_is_executed_by_the_worker(open_app_client, executed):
    with _client(open_app_client, switch=True) as client:
        import app.main as main

        worker = client.app.state.deletion_worker
        assert isinstance(worker, DeletionWorker) and worker.is_alive()
        assert worker in [w for w, _registry in main._background_workers(client.app.state)]
        track = _add(client)
        response = client.post("/tracks/deletions", json={
            "operation_uuid": "11111111-1111-4111-8111-111111111111",
            "targets": [{"uuid_id": track.uuid_id, "base_revision": track.revision}],
            "confirmed_count": 1,
        })
        assert response.status_code == 202, response.text

        assert executed.wait(WAIT_S)
        world = _World(client)
        assert item(world, "11111111-1111-4111-8111-111111111111", track.uuid_id)["status"] == "deleted"
        assert not track.file_path.exists()
    assert not worker.is_alive()  # stopped at shutdown


def test_an_accepted_job_runs_with_the_switch_off(open_app_client, executed):
    with _client(open_app_client, switch=False) as client:
        track = _add(client)
        world = _World(client)
        op = accept_job(world, (track.uuid_id, track.revision))
        client.app.state.deletion_worker.wake()

        assert executed.wait(WAIT_S)
        assert item(world, op, track.uuid_id)["status"] == "deleted"


def test_the_worker_is_off_when_disabled(configure_app):
    main = configure_app(env={"ENABLE_DELETION_WORKER": "false"})
    with TestClient(main.app) as client:
        assert client.app.state.deletion_worker is None
