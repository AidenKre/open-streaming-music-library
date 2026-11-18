"""Phase 8A.3c: two writers that met a pending deletion lost or slipped work
(8A.3b hand-over items (a) and (c); 8A.3b review r1 #1 and #3).

(a) The settle check met a pending track and dropped its entry, so a file
change seen while the deletion was pending was never applied when the deletion
rolled back. The refresh now answers ``DEFER``: the entry stays, with the
signature it was scheduled with, and is retried a window later; a committed
deletion then drops it (the track is gone), a rolled-back one applies it.

(c) The cover-art backfill could set ``cover_art_id`` on a pending track
after its journal recorded ``cover_art_id`` NULL: the art would then never be
released. A pending track is not live, so the backfill write refuses it.
"""

import sqlite3
from unittest.mock import Mock, patch

from app.services.settle_check import DEFER, SettleCheck, make_settle_refresh
from app.services.track_locks import TrackLocks
from tests.pending_deletion import clear_pending_deletion, mark_pending_deletion
from tests.test_identity_settle import WHOLE
from tests.test_identity_settle import _world as _settle_world


def _revision(db, uuid_id):
    conn = sqlite3.connect(db.context.database_path)
    try:
        return conn.execute("SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,)).fetchone()[0]
    finally:
        conn.close()


# ── (a) settle ─────────────────────────────────────────────────────────────


def test_the_settle_refresh_defers_a_pending_track_and_writes_nothing(tmp_path):
    db, path, track, _ = _settle_world(tmp_path)
    mark_pending_deletion(db.context.database_path, track.uuid_id)
    refresh = make_settle_refresh(
        database=db, track_locks=TrackLocks(), cache=Mock(), default_cache=Mock(),
        encoder_coordinator=Mock(),
    )
    revision = _revision(db, track.uuid_id)

    with patch("app.services.settle_check.get_track_metadata", return_value=WHOLE) as probe:
        assert refresh(track.uuid_id, db.owner_id, path) is DEFER

    assert not probe.called
    assert _revision(db, track.uuid_id) == revision


def test_a_deferred_entry_keeps_its_signature_and_is_retried_a_window_later(tmp_path):
    path = tmp_path / "a.flac"
    path.write_bytes(b"grown since the import")
    now = [0.0]
    answers = [DEFER, True]
    calls = []

    def refresh(uuid_id, owner_id, p):
        calls.append(uuid_id)
        return answers.pop(0)

    check = SettleCheck(refresh=refresh, clock=lambda: now[0], window=10)
    check.schedule("u", 1, path, (1, 1))  # the signature seen at import

    now[0] = 10
    check.run_due()
    assert calls == ["u"] and check.pending() == ["u"]

    now[0] = 15
    check.run_due()
    assert calls == ["u"]  # not due again yet

    now[0] = 20
    check.run_due()
    assert calls == ["u", "u"]  # the change is still seen (old signature kept)


def test_after_a_rollback_the_deferred_change_is_applied(tmp_path):
    db, path, track, _ = _settle_world(tmp_path)
    mark_pending_deletion(db.context.database_path, track.uuid_id)
    now = [0.0]
    refresh = make_settle_refresh(
        database=db, track_locks=TrackLocks(), cache=Mock(), default_cache=Mock(),
        encoder_coordinator=Mock(),
    )
    check = SettleCheck(refresh=refresh, clock=lambda: now[0], window=10)
    check.schedule(track.uuid_id, db.owner_id, path, (1, 1))
    revision = _revision(db, track.uuid_id)

    with patch("app.services.settle_check.get_track_metadata", return_value=WHOLE):
        now[0] = 10
        check.run_due()
        assert _revision(db, track.uuid_id) == revision
        clear_pending_deletion(db.context.database_path, track.uuid_id)  # rolled back
        now[0] = 20
        check.run_due()

    assert _revision(db, track.uuid_id) > revision


# ── (c) cover-art backfill ─────────────────────────────────────────────────


def test_the_backfill_write_refuses_a_pending_track(tmp_path):
    db, _path, track, _ = _settle_world(tmp_path)
    conn = sqlite3.connect(db.context.database_path)
    try:
        art = conn.execute(
            "INSERT INTO cover_arts (sha256, phash, phash_prefix, file_path)"
            " VALUES ('s', 'p', 'pp', '/art/s.jpg')"
        ).lastrowid
        conn.commit()
    finally:
        conn.close()
    mark_pending_deletion(db.context.database_path, track.uuid_id)
    revision = _revision(db, track.uuid_id)

    assert db.update_track_cover_art_id(track.uuid_id, art, owner_id=db.owner_id) is False
    assert _revision(db, track.uuid_id) == revision

    clear_pending_deletion(db.context.database_path, track.uuid_id)
    assert db.update_track_cover_art_id(track.uuid_id, art, owner_id=db.owner_id) is True
