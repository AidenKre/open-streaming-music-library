"""Phase 8A.3c (spec §5 "Never await a worker that needs the held lock. Lock
order is track → directory → short DB transaction"; 8A.3b hand-over (e);
review 8-U05 lock side, 8-D07 "no deadlock"): the deletion worker and the
other track writers share the app's one ``TrackLocks`` instance.

Independent threads with gates and bounded joins (never a sleep):
- an edit (PATCH) that arrives while a deletion holds the lock waits, then
  answers 404 for the deleted track; nothing deadlocks;
- a conversion request that arrives while a deletion holds the lock waits,
  then answers 404 and queues no job;
- a deletion that meets the lock held by another writer answers ``busy`` at
  once and leaves the writer's work alone.
"""

import threading

import pytest

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.deletion_worker import DeletionExecutor
from tests.deletion_world import SpyCache, accept_job, item
from tests.jobs_api_fixtures import _post_job

WAIT_S = 30


def _signal_waits(locks):
    """An event set when a writer starts waiting on ``lock()`` of the app's one
    lock registry (the context-manager entry the PATCH route and the conversion
    orchestrator use; the orchestrator keeps the instance it was built with)."""
    waiting = threading.Event()
    original = locks.lock

    def lock(key):
        waiting.set()
        return original(key)

    locks.lock = lock
    return waiting


class _World:
    """Just what ``accept_job`` and ``item`` read from a deletion_world World."""

    def __init__(self, client):
        self.db = client.app.state.database
        self.owner = client.app.state.admin_library.owner_id


def _add(client):
    music = client.app.state.settings.music_library_dir
    folder = music / "admin" / "Art"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "song.flac"
    path.write_bytes(b"fake-audio-bytes")
    metadata = TrackMetaData(codec="flac", duration=1.0, title="T", artist="Art")
    track = Track(file_path=path, metadata=metadata)
    db = client.app.state.database
    owner = client.app.state.admin_library.owner_id
    assert db.add_track(track, owner_id=owner)
    return db.get_track_by_uuid(track.uuid_id, owner_id=owner)


def _executor(client, locks, seam=None, lock_timeout_s=0):
    state = client.app.state
    return DeletionExecutor(
        state.database,
        music_library_dir=state.settings.music_library_dir,
        track_locks=locks,
        cover_art=state.cover_art_manager,
        cache=SpyCache(),
        default_cache=SpyCache(),
        boot_id="boot-locks",
        lock_timeout_s=lock_timeout_s,
        seam=seam,
    )


@pytest.fixture
def client(app_client):
    return app_client


def test_an_edit_waiting_behind_a_deletion_answers_404_without_a_deadlock(client):
    track = _add(client)
    world = _World(client)
    op = accept_job(world, (track.uuid_id, track.revision))
    locks = client.app.state.track_locks
    waiting = _signal_waits(locks)
    at_pause, go = threading.Event(), threading.Event()

    def seam(name):
        if name == "after_moved":
            at_pause.set()
            assert go.wait(WAIT_S)

    deletion = threading.Thread(target=_executor(client, locks, seam).run_one)
    deletion.start()
    assert at_pause.wait(WAIT_S)
    result = {}
    edit = threading.Thread(target=lambda: result.setdefault("r", client.patch(
        f"/tracks/{track.uuid_id}", json={"base_revision": track.revision, "title": "Late"},
    )))
    edit.start()
    assert waiting.wait(WAIT_S)  # the edit now waits for the deletion's lock
    go.set()
    deletion.join(WAIT_S)
    edit.join(WAIT_S)

    assert not deletion.is_alive() and not edit.is_alive()
    assert item(world, op, track.uuid_id)["status"] == "deleted"
    assert result["r"].status_code == 404, result["r"].text


def test_a_conversion_request_waiting_behind_a_deletion_queues_nothing(client):
    track = _add(client)
    world = _World(client)
    op = accept_job(world, (track.uuid_id, track.revision))
    locks = client.app.state.track_locks
    waiting = _signal_waits(locks)
    at_pause, go = threading.Event(), threading.Event()

    def seam(name):
        if name == "after_moved":
            at_pause.set()
            assert go.wait(WAIT_S)

    deletion = threading.Thread(target=_executor(client, locks, seam).run_one)
    deletion.start()
    assert at_pause.wait(WAIT_S)
    result = {}
    convert = threading.Thread(target=lambda: result.setdefault(
        "r", _post_job(client, track.uuid_id, "aac", track.revision, 192)))
    convert.start()
    assert waiting.wait(WAIT_S)
    go.set()
    deletion.join(WAIT_S)
    convert.join(WAIT_S)

    assert not deletion.is_alive() and not convert.is_alive()
    assert item(world, op, track.uuid_id)["status"] == "deleted"
    assert result["r"].status_code == 404, result["r"].text
    assert client.app.state.database.list_conversion_jobs_with_status(
        "queued", owner_id=world.owner
    ) == []


def test_a_deletion_meeting_a_writer_that_holds_the_lock_is_busy_at_once(client):
    track = _add(client)
    world = _World(client)
    op = accept_job(world, (track.uuid_id, track.revision))
    locks = client.app.state.track_locks
    held = locks.lock_for(track.uuid_id)
    assert held.acquire()  # a conversion commit or a master edit in progress
    try:
        done = threading.Event()
        deletion = threading.Thread(
            target=lambda: (_executor(client, locks).run_one(), done.set()))
        deletion.start()
        assert done.wait(WAIT_S)
        deletion.join(WAIT_S)
    finally:
        held.release()

    assert item(world, op, track.uuid_id)["status"] == "busy"
    assert client.app.state.database.get_track_by_uuid(
        track.uuid_id, owner_id=world.owner
    ).revision == track.revision
