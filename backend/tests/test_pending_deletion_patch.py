"""Phase 8A.3b (spec §5 step 2, plan D14, decision O9; review 8-U05 mutation
side): a track edit refuses a track that is pending deletion.

"Mark deletion pending so other mutators and ``open_track_source`` refuse new
opens. The marker is the existence of a ``deletion_journal`` row for the UUID
(removed when a deletion rolls back). ``TrackEditor`` ... also refuse[s] such
UUIDs." The answer is 409 ``track_pending_deletion``, retryable (O9): a
rolled-back deletion leaves a healthy track, and the same edit then succeeds.

The refusal is checked under the track lock, where the editor would otherwise
start changing the row or the file, so a deletion that marks the track while
the edit waits for the lock still stops it. Nothing is written: not the row,
not the file, not the edit journal, not the staging area.
"""

import os
import threading
from pathlib import Path

import pytest

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.track_locks import TrackLocks
from tests.pending_deletion import clear_pending_deletion, mark_pending_deletion
from tests.owned_database import add_test_user
from tests.test_jobs_api import _make_audio

WAIT_S = 10  # bounded waits on events and joins; never a sleep


@pytest.fixture
def client(app_client):
    return app_client


def _db(client):
    return client.app.state.database


def _owner(client):
    return client.app.state.admin_library.owner_id


def _add(client, tmp_path, *, real_audio=False, owner_id=None, name="song.flac"):
    folder = tmp_path / "music" / "admin" / "Art"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    if real_audio:
        _make_audio(path, codec="flac")
    else:
        path.write_bytes(b"fake-audio-bytes")
    metadata = TrackMetaData(
        codec="flac", duration=1.0, bitrate_kbps=1000.0, sample_rate_hz=44100,
        channels=2, title="T", artist="Art",
    )
    track = Track(file_path=path, metadata=metadata)
    owner = owner_id if owner_id is not None else _owner(client)
    assert _db(client).add_track(track, owner_id=owner)
    return _db(client).get_track_by_uuid(track.uuid_id, owner_id=owner)


def _pend(client, uuid_id):
    mark_pending_deletion(_db(client).context.database_path, uuid_id)


def _snapshot(client, track, tmp_path):
    db = _db(client)
    row = db.get_track_by_uuid(track.uuid_id, owner_id=_owner(client))
    stat = Path(track.file_path).stat()
    files = sorted(str(p) for p in (tmp_path / "music").rglob("*") if p.is_file())
    return {
        "revision": row.revision,
        "title": row.metadata.title,
        "artist": row.metadata.artist,
        "file_path": row.file_path,
        "bytes": Path(track.file_path).read_bytes(),
        "mtime_ns": stat.st_mtime_ns,
        "ino": stat.st_ino,
        "files": files,
        "edit_journal": db.list_journal_entries(owner_id=_owner(client)),
    }


def _patch(client, track, write_mode="db_only", **fields):
    body = {"base_revision": track.revision, "write_mode": write_mode}
    body.update(fields or {"title": "Renamed"})
    return client.patch(f"/tracks/{track.uuid_id}", json=body)


def _assert_refused(response):
    assert response.status_code == 409, response.text
    detail = response.json()["detail"]
    assert detail["error"] == "track_pending_deletion"
    assert detail["retryable"] is True
    assert isinstance(detail["message"], str) and detail["message"]


# --- every write mode refuses and writes nothing ---------------------------------------


def test_a_db_only_edit_of_a_pending_track_is_refused_and_writes_nothing(client, tmp_path):
    track = _add(client, tmp_path)
    _pend(client, track.uuid_id)
    before = _snapshot(client, track, tmp_path)

    _assert_refused(_patch(client, track, "db_only", title="Renamed"))

    assert _snapshot(client, track, tmp_path) == before


@pytest.mark.requires_ffmpeg
def test_a_relocating_master_edit_is_refused_and_never_touches_the_file(client, tmp_path):
    track = _add(client, tmp_path, real_audio=True)
    _pend(client, track.uuid_id)
    before = _snapshot(client, track, tmp_path)

    _assert_refused(_patch(client, track, "db_and_master", artist="Elsewhere"))

    assert _snapshot(client, track, tmp_path) == before


@pytest.mark.requires_ffmpeg
def test_an_in_place_master_edit_is_refused_and_never_touches_the_file(client, tmp_path):
    track = _add(client, tmp_path, real_audio=True)
    _pend(client, track.uuid_id)
    before = _snapshot(client, track, tmp_path)

    _assert_refused(_patch(client, track, "db_and_master", title="Same place"))

    assert _snapshot(client, track, tmp_path) == before


def test_a_master_edit_that_would_degrade_to_db_only_is_refused_too(client, tmp_path):
    """Fake bytes stand in for a master the editor cannot tag (it would fail);
    a WAV degrades to a DB-only write. Either way the marker refuses first."""
    track = _add(client, tmp_path, name="song.wav")
    _pend(client, track.uuid_id)
    before = _snapshot(client, track, tmp_path)

    _assert_refused(_patch(client, track, "db_and_master", title="Renamed"))

    assert _snapshot(client, track, tmp_path) == before


# --- retryable: a rolled-back deletion leaves a healthy track ---------------------------


def test_the_same_edit_succeeds_once_the_deletion_rolls_back(client, tmp_path):
    track = _add(client, tmp_path)
    _pend(client, track.uuid_id)
    _assert_refused(_patch(client, track, "db_only", title="Renamed"))

    clear_pending_deletion(_db(client).context.database_path, track.uuid_id)
    response = _patch(client, track, "db_only", title="Renamed")

    assert response.status_code == 200, response.text
    assert response.json()["revision"] > track.revision


# --- ownership: a foreign track answers like an unknown one ------------------------------


def test_another_users_pending_track_answers_404_like_an_unknown_one(client, tmp_path):
    other = add_test_user(_db(client), "other")
    theirs = _add(client, tmp_path, owner_id=other, name="theirs.flac")
    _pend(client, theirs.uuid_id)

    response = _patch(client, theirs, "db_only", title="Mine now")
    unknown = client.patch(
        "/tracks/6b1f6b39-5d0d-4a4a-9d3c-0d6c5d6f0001",
        json={"base_revision": theirs.revision, "title": "Mine now"},
    )

    assert response.status_code == unknown.status_code == 404
    assert response.json() == unknown.json()


# --- the check runs under the track lock --------------------------------------------------


class _SignallingLocks(TrackLocks):
    """The app's lock registry, plus an event set when a caller starts waiting
    for a uuid's lock."""

    def __init__(self):
        super().__init__()
        self.waiting = threading.Event()

    def lock(self, key):
        self.waiting.set()
        return super().lock(key)


def test_a_deletion_marked_while_the_edit_waits_for_the_lock_still_stops_it(client, tmp_path):
    """The deletion worker writes its journal row under the track lock. An edit
    that arrived first and waits for that lock must re-check once it holds it."""
    track = _add(client, tmp_path)
    locks = _SignallingLocks()
    client.app.state.track_locks = locks
    before = _snapshot(client, track, tmp_path)
    result = {}

    held = locks.lock_for(track.uuid_id)
    held.acquire()
    try:
        worker = threading.Thread(
            target=lambda: result.setdefault("r", _patch(client, track, "db_only", title="Late")),
        )
        worker.start()
        assert locks.waiting.wait(WAIT_S)
        _pend(client, track.uuid_id)  # the deletion marks the track while holding the lock
    finally:
        held.release()
    worker.join(WAIT_S)
    assert not worker.is_alive()

    _assert_refused(result["r"])
    after = _snapshot(client, track, tmp_path)
    assert after == before
