"""Phase 8A.3b (spec §5 step 2, plan D14): the background writers leave a
track that is pending deletion alone.

Two writers change a track without a request: the settle refresh (re-reads a
file that changed after import, bumps the revision and marks the identity
stale) and the edit-journal finisher (finishes a kept ``edit_journal`` row
while the server runs). Both work under the track lock; both now skip a track
whose ``deletion_journal`` row exists, writing nothing and touching no file.
The finisher keeps the row for a later pass (the deletion may roll back).
"""

import sqlite3
from unittest.mock import Mock, patch

import pytest

from app.services.track_editor import finish_kept_journal_rows
from app.services.track_locks import TrackLocks
from tests.pending_deletion import clear_pending_deletion, mark_pending_deletion
from tests.test_identity_editor import SpyWakeup, _identity
from tests.test_identity_journal_finisher import _edit_with_a_failing_mark
from tests.test_identity_editor import _world as _editor_world
from tests.test_identity_settle import WHOLE, _duration
from tests.test_identity_settle import _world as _settle_world
from app.services.settle_check import DEFER, make_settle_refresh
from tests.test_track_editor import _lib


def _revision(db, uuid_id):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute("SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,)).fetchone()[0]
    finally:
        conn.close()


# --- settle refresh ----------------------------------------------------------------------


def test_the_settle_refresh_skips_a_pending_track_and_writes_nothing(tmp_path):
    db, path, track, before = _settle_world(tmp_path)
    mark_pending_deletion(db.context.database_path, track.uuid_id)
    wakeup = SpyWakeup(db, track.uuid_id)
    cache, default_cache, coordinator = Mock(), Mock(), Mock()
    refresh = make_settle_refresh(
        database=db, track_locks=TrackLocks(), cache=cache, default_cache=default_cache,
        encoder_coordinator=coordinator, identity_signal=wakeup,
    )
    revision, duration, original = _revision(db, track.uuid_id), _duration(db, track.uuid_id), path.read_bytes()

    with patch("app.services.settle_check.get_track_metadata", return_value=WHOLE) as probe:
        # 8A.3c: deferred (entry kept for after a rollback), no longer dropped.
        assert refresh(track.uuid_id, db.owner_id, path) is DEFER

    assert not probe.called  # the file is not even read
    assert _revision(db, track.uuid_id) == revision
    assert _duration(db, track.uuid_id) == duration
    assert _identity(db, track.uuid_id) == before
    assert wakeup.seen == []
    assert cache.mock_calls == [] and default_cache.mock_calls == []
    assert coordinator.mock_calls == []
    assert path.read_bytes() == original


def test_the_settle_refresh_works_again_once_the_deletion_rolls_back(tmp_path):
    db, path, track, _ = _settle_world(tmp_path)
    mark_pending_deletion(db.context.database_path, track.uuid_id)
    clear_pending_deletion(db.context.database_path, track.uuid_id)
    refresh = make_settle_refresh(
        database=db, track_locks=TrackLocks(), cache=Mock(), default_cache=Mock(),
        encoder_coordinator=Mock(),
    )
    revision = _revision(db, track.uuid_id)

    with patch("app.services.settle_check.get_track_metadata", return_value=WHOLE):
        assert refresh(track.uuid_id, db.owner_id, path) is True

    assert _revision(db, track.uuid_id) > revision


# --- edit-journal finisher ----------------------------------------------------------------


@pytest.mark.requires_ffmpeg
def test_the_journal_finisher_skips_a_pending_track_and_keeps_its_row(tmp_path, monkeypatch):
    library, audio, db, track, before = _editor_world(tmp_path)
    _edit_with_a_failing_mark(monkeypatch, library, db, track, None)
    mark_pending_deletion(db.context.database_path, track.uuid_id)
    edited = audio.read_bytes()
    stat = audio.stat()

    assert finish_kept_journal_rows(db, library, TrackLocks()) == 0

    assert [e["intent"] for e in db.list_journal_entries()] == ["inplace"]
    assert _identity(db, track.uuid_id) == before
    assert audio.read_bytes() == edited
    assert audio.stat().st_mtime_ns == stat.st_mtime_ns

    # A rolled-back deletion leaves a healthy track: the next pass finishes the row.
    clear_pending_deletion(db.context.database_path, track.uuid_id)
    assert finish_kept_journal_rows(db, library, TrackLocks()) == 1
    assert db.list_journal_entries() == []
    assert not _lib(db).has_journal_entry_for_uuid(track.uuid_id)
