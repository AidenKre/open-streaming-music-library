"""Phase 6.5A.2b, plan D13 / DEV-6.5-03: the settle check is an identity writer.

When a file changed after import (Phase M's settle check, DEV-M-15), the exact
digest taken before the move and any fingerprint taken since came from a
partial file. The refresh marks every identity layer stale (``'settle'``) in
its own transaction and signals the worker after the commit.
"""

import sqlite3
from unittest.mock import Mock, patch

import pytest

from app.database.database import Database
from app.models.track_meta_data import TrackMetaData
from app.services.settle_check import make_settle_refresh
from app.services.track_locks import TrackLocks
from tests.owned_database import add_test_user
from tests.test_identity_editor import DIGEST, SpyWakeup, _identity, _settle
from tests.test_track_editor import _add_track, _db

WHOLE = TrackMetaData(title="Lucky", artist="Radiohead", codec="flac", duration=4.0,
                      bitrate_kbps=900.0, sample_rate_hz=44100, channels=2)


def _settle_marked(row, fp_state="pending"):
    return (row["generation"], row["exact_state"], row["exact_digest"], row["fp_state"],
            row["match_state"], row["priority"]) == (4, "pending", DIGEST, fp_state, "pending", 0)


def _world(tmp_path):
    db = _db(tmp_path)
    path = tmp_path / "music" / "owner" / "Radiohead" / "lucky.flac"
    path.parent.mkdir(parents=True)
    path.write_bytes(b"partial then whole")
    track = _add_track(db, path, "Lucky", "Radiohead")
    return db, path, track, _settle(db, track.uuid_id)


def _refresh(db, path, track, owner_id=None):
    return db.refresh_track_audio_properties(
        track.uuid_id, codec="flac", bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
        duration=4.0, owner_id=owner_id or db.owner_id,
    )


def _duration(db, uuid_id):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute("SELECT duration FROM trackmetadata WHERE uuid_id = ?", (uuid_id,)).fetchone()[0]
    finally:
        conn.close()


# --- the DB refresh marks every layer stale in its own transaction -----------------


def test_a_settle_refresh_marks_every_identity_layer_stale(tmp_path):
    db, path, track, _ = _world(tmp_path)

    assert _refresh(db, path, track) is not None

    assert _settle_marked(_identity(db, track.uuid_id))


def test_a_settle_refresh_never_claims_a_fingerprinter_exists(tmp_path):
    db, path, track, _ = _world(tmp_path)
    conn = sqlite3.connect(db.context.database_path)
    conn.execute("UPDATE track_audio_identity SET fp_state = 'unavailable' WHERE uuid_id = ?",
                 (track.uuid_id,))
    conn.commit()
    conn.close()

    _refresh(db, path, track)

    assert _settle_marked(_identity(db, track.uuid_id), fp_state="unavailable")


def test_another_owners_refresh_marks_nothing(tmp_path):
    db, path, track, before = _world(tmp_path)
    alex = add_test_user(db, "Alex")

    assert _refresh(db, path, track, owner_id=alex) is None
    assert _identity(db, track.uuid_id) == before


def test_the_mark_and_the_refresh_commit_together(tmp_path, monkeypatch):
    db, path, track, before = _world(tmp_path)
    duration_before = _duration(db, track.uuid_id)

    def crash(conn, uuid_id, reason):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(Database, "_mark_audio_identity_stale_in", staticmethod(crash))
    with pytest.raises(sqlite3.OperationalError):
        _refresh(db, path, track)

    assert _identity(db, track.uuid_id) == before
    assert _duration(db, track.uuid_id) == duration_before


# --- the settle refresh signals the worker after the commit ------------------------


def _settle_refresh(db, wakeup):
    return make_settle_refresh(
        database=db, track_locks=TrackLocks(), cache=Mock(), default_cache=Mock(),
        encoder_coordinator=Mock(), identity_signal=wakeup,
    )


def test_the_settle_refresh_signals_after_its_commit(tmp_path):
    db, path, track, _ = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    with patch("app.services.settle_check.get_track_metadata", return_value=WHOLE):
        assert _settle_refresh(db, wakeup)(track.uuid_id, db.owner_id, path) is True

    assert wakeup.seen == [4]


def test_a_skipped_settle_refresh_never_signals(tmp_path):
    db, path, track, before = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)
    moved = tmp_path / "elsewhere.flac"

    with patch("app.services.settle_check.get_track_metadata", return_value=WHOLE):
        assert _settle_refresh(db, wakeup)(track.uuid_id, db.owner_id, moved) is False

    assert wakeup.seen == []
    assert _identity(db, track.uuid_id) == before


def test_a_changed_file_that_cannot_be_read_yet_is_still_marked_stale(tmp_path):
    """Review F2: the file changed after import but cannot be probed right now.
    The identity taken from the old bytes is stale whether or not the next
    check can read the file, so the refresh marks it (and signals) now."""
    db, path, track, _ = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    with patch("app.services.settle_check.get_track_metadata", return_value=None):
        assert _settle_refresh(db, wakeup)(track.uuid_id, db.owner_id, path) is True

    assert _settle_marked(_identity(db, track.uuid_id))
    assert wakeup.seen == [4]


# --- U05-A-06: the settle check's probe is bounded ---------------------------------


@pytest.mark.integration
def test_a_hung_probe_in_the_settle_refresh_ends_within_the_bound(tmp_path, monkeypatch):
    """The settle check probes under the track lock: a probe that never
    answers must not hold it. Unreadable for now: the identity is still marked
    stale and the check keeps going."""
    from tests import hanging_ffprobe

    hanging_ffprobe.install(monkeypatch, tmp_path)
    hanging_ffprobe.shorten_bound(monkeypatch)
    db, path, track, _ = _world(tmp_path)
    wakeup = SpyWakeup(db, track.uuid_id)

    with hanging_ffprobe.timed() as elapsed:
        kept_checking = _settle_refresh(db, wakeup)(track.uuid_id, db.owner_id, path)

    assert elapsed() < hanging_ffprobe.WITHIN_S
    assert kept_checking is True
    assert _settle_marked(_identity(db, track.uuid_id))
