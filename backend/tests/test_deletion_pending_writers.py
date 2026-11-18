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


def _always_deferred(tmp_path, window=30):
    """A settle entry whose file changed and whose track stays pending deletion
    (every look answers DEFER); the times of the looks are recorded."""
    path = tmp_path / "a.flac"
    path.write_bytes(b"grown since the import")
    now = [0.0]
    looks = []
    answers = []

    def refresh(uuid_id, owner_id, p):
        looks.append(now[0])
        return answers.pop(0) if answers else DEFER

    check = SettleCheck(refresh=refresh, clock=lambda: now[0], window=window)
    check.schedule("u", 1, path, (1, 1))  # the signature seen at import
    return check, now, looks, answers


def test_a_deletion_that_stays_pending_is_looked_at_less_and_less_often(tmp_path):
    """Pre-merge review B1-05. A deletion kept for recovery can keep its track
    pending for good. Its settle entry was then asked again every window (30 s)
    for as long as the server ran. Now the gap doubles with each deferral, up
    to 128 windows (64 minutes); the entry is never dropped, so a deletion that
    is undone later still gets its refresh."""
    check, now, looks, _ = _always_deferred(tmp_path)

    for _ in range(24 * 60 * 2):  # a day, in steps of one window
        now[0] += 30
        check.run_due()

    assert check.pending() == ["u"]
    gaps = [b - a for a, b in zip(looks, looks[1:])]
    assert looks[0] == 30 and gaps[:8] == [30, 60, 120, 240, 480, 960, 1920, 3840]
    assert set(gaps[8:]) == {3840}
    assert len(looks) == 29


def test_after_many_deferrals_a_rolled_back_deletion_still_gets_its_refresh(tmp_path):
    check, now, looks, answers = _always_deferred(tmp_path)
    answers += [DEFER, DEFER, DEFER, True]  # undone before the fourth look
    dropped_at = None

    for _ in range(40):
        now[0] += 30
        check.run_due()
        if dropped_at is None and check.pending() == []:
            dropped_at = now[0]

    assert looks == [30, 60, 120, 240]  # deferred three times, then refreshed
    # The file did not change after the refresh: the entry leaves one usual
    # window later, not a grown one.
    assert dropped_at == 270


def test_a_deferral_after_a_refresh_starts_from_the_usual_window_again(tmp_path):
    check, now, looks, answers = _always_deferred(tmp_path)
    answers += [DEFER, DEFER, DEFER, True]
    path = tmp_path / "a.flac"

    for _ in range(12):
        now[0] += 30
        check.run_due()
        if now[0] == 240:  # right after the refresh the file changes once more
            path.write_bytes(b"grown again, and longer than before")

    # 270: changed again and deferred (a new deletion); the next look is one
    # usual window later, not eight.
    assert looks == [30, 60, 120, 240, 270, 300, 360]


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
