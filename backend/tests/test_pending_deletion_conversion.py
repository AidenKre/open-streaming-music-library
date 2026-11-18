"""Phase 8A.3b (spec §5 step 2, plan D14, decision O9; review 8-U05 mutation
side): a conversion refuses a track that is pending deletion.

"``ConversionOrchestrator.enqueue``/``_run_job_inner`` (next to
``has_journal_entry_for_uuid``) ... also refuse such UUIDs." A request answers
409 ``track_pending_deletion`` (retryable, O9) and queues nothing. A queued job
that meets the marker fails before it transcodes. A job whose track is marked
while it transcodes fails under the track lock, before it journals, moves or
replaces anything: the master stays byte-identical and no converted file
appears.

The deletion worker writes its journal row only while holding the track lock,
so the enqueue's check and its job insert run under that lock too: a deletion
marked while the request waits for the lock still stops it.
"""

import threading
from pathlib import Path
from unittest.mock import Mock

import pytest

from app.services.track_locks import TrackLocks
from tests.pending_deletion import clear_pending_deletion, mark_pending_deletion
from tests.jobs_api_fixtures import _post_job
from tests.test_jobs_api import _add_track_with_file, _hold_worker

requires_ffmpeg = pytest.mark.requires_ffmpeg

WAIT_S = 10  # bounded waits on events and joins; never a sleep
PENDING_TEXT = "the track is being deleted"


@pytest.fixture
def client(app_client):
    app_client.held = _hold_worker(app_client)
    return app_client


def _library(client):
    return client.app.state.admin_library


def _pend(client, uuid_id):
    mark_pending_deletion(client.app.state.database.context.database_path, uuid_id)


def _jobs(client):
    jobs, _cursor = _library(client).list_conversion_jobs()
    return jobs


def _reservations(client):
    import sqlite3

    conn = sqlite3.connect(client.app.state.database.context.database_path)
    try:
        return conn.execute("SELECT count(*) FROM storage_reservations").fetchone()[0]
    finally:
        conn.close()


def _files(tmp_path):
    return sorted(str(p) for p in (tmp_path / "music").rglob("*") if p.is_file())


def _assert_refused(response):
    assert response.status_code == 409, response.text
    detail = response.json()["detail"]
    assert detail["error"] == "track_pending_deletion"
    assert detail["retryable"] is True


# --- the request ------------------------------------------------------------------------


def test_a_conversion_request_for_a_pending_track_is_refused_and_queues_nothing(client, tmp_path):
    track = _add_track_with_file(client, tmp_path, codec="flac")
    _pend(client, track.uuid_id)

    _assert_refused(_post_job(client, track.uuid_id, "aac", track.revision, 192))

    assert _jobs(client) == []
    assert client.held.submitted == []


def test_the_same_request_is_accepted_once_the_deletion_rolls_back(client, tmp_path):
    track = _add_track_with_file(client, tmp_path, codec="flac")
    _pend(client, track.uuid_id)
    _assert_refused(_post_job(client, track.uuid_id, "aac", track.revision, 192))

    clear_pending_deletion(client.app.state.database.context.database_path, track.uuid_id)
    response = _post_job(client, track.uuid_id, "aac", track.revision, 192)

    assert response.status_code == 200, response.text
    assert response.json()["status"] == "queued"


class _SignallingLocks(TrackLocks):
    """A lock registry that reports when a caller starts waiting for a uuid's lock."""

    def __init__(self):
        super().__init__()
        self.waiting = threading.Event()

    def lock(self, key):
        self.waiting.set()
        return super().lock(key)


def test_a_deletion_marked_while_the_request_waits_for_the_lock_still_stops_it(client, tmp_path):
    track = _add_track_with_file(client, tmp_path, codec="flac")
    locks = _SignallingLocks()
    client.app.state.track_locks = locks
    client.app.state.conversion_orchestrator.track_locks = locks
    result = {}

    held = locks.lock_for(track.uuid_id)
    held.acquire()
    try:
        worker = threading.Thread(
            target=lambda: result.setdefault(
                "r", _post_job(client, track.uuid_id, "aac", track.revision, 192)
            ),
        )
        worker.start()
        assert locks.waiting.wait(WAIT_S)
        _pend(client, track.uuid_id)  # the deletion marks the track while holding the lock
    finally:
        held.release()
    worker.join(WAIT_S)
    assert not worker.is_alive()

    _assert_refused(result["r"])
    assert _jobs(client) == []
    assert client.held.submitted == []


# --- the run ----------------------------------------------------------------------------


def test_a_queued_job_whose_track_became_pending_fails_before_transcoding(
    client, tmp_path, monkeypatch
):
    track = _add_track_with_file(client, tmp_path, codec="flac")
    job_id = _post_job(client, track.uuid_id, "aac", track.revision, 192).json()["job_id"]
    _pend(client, track.uuid_id)
    transcode = Mock(side_effect=AssertionError("transcoded a pending track"))
    monkeypatch.setattr("app.services.conversion.transcode", transcode)
    before = _files(tmp_path)

    client.held.run_last()

    job = _library(client).get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", PENDING_TEXT)
    assert not transcode.called
    assert _reservations(client) == 0
    assert _files(tmp_path) == before


@requires_ffmpeg
def test_a_track_marked_while_its_job_transcodes_keeps_its_master_untouched(client, tmp_path):
    """The marker lands after the transcode, while the job runs without the
    lock; the job's re-check under the lock fails it before any file step."""
    track = _add_track_with_file(client, tmp_path, codec="flac", real_audio=True)
    master = Path(track.file_path)
    original = master.read_bytes()
    original_stat = master.stat()
    orchestrator = client.app.state.conversion_orchestrator
    real_identity = orchestrator.compute_identity

    def identity_then_mark(*args, **kwargs):
        result = real_identity(*args, **kwargs)
        _pend(client, track.uuid_id)  # the deletion worker marks the track meanwhile
        return result

    orchestrator.compute_identity = identity_then_mark
    job_id = _post_job(client, track.uuid_id, "aac", track.revision, 192).json()["job_id"]
    evicted = Mock()
    orchestrator._evict = evicted
    before = _files(tmp_path)

    client.held.run_last()

    job = _library(client).get_conversion_job(job_id)
    assert (job["status"], job["error_text"]) == ("failed", PENDING_TEXT)
    assert master.read_bytes() == original
    assert master.stat().st_mtime_ns == original_stat.st_mtime_ns
    assert not master.with_suffix(".m4a").exists()
    assert _files(tmp_path) == before
    row = _library(client).get_track_by_uuid(track.uuid_id)
    assert (row.revision, row.file_path, row.metadata.codec) == (
        track.revision, master, "flac",
    )
    assert _library(client).list_journal_entries() == []
    assert not evicted.called
    assert _reservations(client) == 0
    staging = tmp_path / "music" / ".staging"
    assert not staging.exists() or list(staging.iterdir()) == []


# --- ownership: a foreign track answers like an unknown one -----------------------------


def test_another_users_pending_track_answers_404_like_an_unknown_one(client, tmp_path):
    from app.models.track import Track
    from app.models.track_meta_data import TrackMetaData
    from tests.owned_database import add_test_user

    database = client.app.state.database
    other = add_test_user(database, "other")
    path = tmp_path / "music" / "other" / "theirs.flac"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"their-audio-bytes")
    theirs = Track(file_path=path, metadata=TrackMetaData(
        codec="flac", duration=1.0, bitrate_kbps=1000.0, sample_rate_hz=44100, channels=2,
        title="T", artist="Art",
    ))
    assert database.add_track(theirs, owner_id=other)
    mark_pending_deletion(database.context.database_path, theirs.uuid_id)

    response = _post_job(client, theirs.uuid_id, "aac", 1, 192)
    unknown = _post_job(client, "6b1f6b39-5d0d-4a4a-9d3c-0d6c5d6f0002", "aac", 1, 192)

    assert response.status_code == unknown.status_code == 404
    assert response.json() == unknown.json()
    assert _jobs(client) == []
