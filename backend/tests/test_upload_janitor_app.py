"""7A.3c S9 (SC-16e: "... job reclaim per type → janitors (7 expiry ...)";
spec §3 "Background janitor"): the upload janitor runs once at startup as the
last, non-fatal recovery step, and then periodically in a background thread
while the server runs (``ENABLE_UPLOAD_JANITOR``, ``UPLOAD_JANITOR_INTERVAL_S``),
stopped at shutdown. Expiry and retention come from configuration."""

import sqlite3
import threading

import pytest
from fastapi.testclient import TestClient

from app.services.upload_janitor import UploadJanitorThread
from tests.test_identity_worker_app import _lock_is_held

DAY = 86_400


def _capture_steps(main, monkeypatch):
    captured = []
    real = main.run_startup_recovery

    def capture(steps):
        captured.append(list(steps))
        return real(steps)

    monkeypatch.setattr(main, "run_startup_recovery", capture)
    return captured


def test_the_janitor_is_the_last_non_fatal_startup_step(configure_app, monkeypatch):
    main = configure_app()
    captured = _capture_steps(main, monkeypatch)

    with TestClient(main.app):
        pass

    [steps] = captured
    names = [(s.name, s.fatal) for s in steps]
    # 8A.3d: the deletion janitor follows it (SC-16e janitors).
    assert names[-3:] == [
        ("storage reservations", False), ("upload janitor", False), ("deletion janitor", False),
    ]


def _seed_idle_item(db_path, owner, item="7a1f0d2e-1b2c-4d3e-8f4a-5b6c7d8e9f01"):
    batch = "8b1f0d2e-1b2c-4d3e-8f4a-5b6c7d8e9f01"
    conn = sqlite3.connect(db_path)
    try:
        with conn:
            conn.execute("INSERT INTO upload_batches (owner_id, batch_uuid, created_at, updated_at)"
                         " VALUES (?, ?, 1, 1)", (owner, batch))
            conn.execute(
                "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, selection_index,"
                " expected_bytes, expected_sha256, state, created_at, updated_at, progress_at)"
                " VALUES (?, ?, ?, 'a.flac', 0, 1, ?, 'allocated', 1, 1, 1)", (owner, item, batch, "0" * 64))
    finally:
        conn.close()
    return item


def _state(db_path, item):
    conn = sqlite3.connect(db_path)
    try:
        return conn.execute("SELECT state FROM upload_items WHERE item_uuid = ?", (item,)).fetchone()[0]
    finally:
        conn.close()


def test_startup_expires_an_item_idle_for_seven_days(configure_app):
    with TestClient(configure_app().app) as client:
        db_path = client.app.state.database.context.database_path
        owner = client.app.state.admin_user_id
    item = _seed_idle_item(db_path, owner)

    with TestClient(configure_app().app):
        pass

    assert _state(db_path, item) == "expired"


def test_the_expiry_window_comes_from_configuration(configure_app):
    with TestClient(configure_app().app) as client:
        db_path = client.app.state.database.context.database_path
        owner = client.app.state.admin_user_id
    item = _seed_idle_item(db_path, owner)

    # Progress at t=1; a window longer than the time since then keeps it.
    with TestClient(configure_app(env={"UPLOAD_STAGE_EXPIRY_S": str(100 * 365 * DAY)}).app):
        pass

    assert _state(db_path, item) == "allocated"


def test_the_periodic_janitor_is_off_unless_enabled(configure_app):
    with TestClient(configure_app().app) as client:
        assert client.app.state.upload_janitor_thread is None


def test_the_enabled_periodic_janitor_runs_while_the_app_runs_and_stops_with_it(configure_app):
    with TestClient(configure_app(env={"ENABLE_UPLOAD_JANITOR": "true"}).app) as client:
        thread = client.app.state.upload_janitor_thread
        assert isinstance(thread, UploadJanitorThread)
        assert thread.is_alive()

    assert not thread.is_alive()


# ── the thread itself (no wall clock: interval 0, the fake stops it) ──────

class FakeJanitor:
    def __init__(self, stop_after, raise_first=False):
        self.calls = 0
        self.stop_after = stop_after
        self.raise_first = raise_first
        self.thread = None
        self.done = threading.Event()

    def run_once(self):
        self.calls += 1
        if self.calls >= self.stop_after:
            self.thread.request_stop()
            self.done.set()
        if self.raise_first and self.calls == 1:
            raise RuntimeError("one bad pass")


def test_the_thread_runs_the_janitor_each_interval_until_stopped():
    janitor = FakeJanitor(stop_after=3)
    thread = janitor.thread = UploadJanitorThread(janitor, interval_s=0)

    thread.start()
    assert thread.join(timeout=5)

    assert janitor.calls == 3


def test_a_failing_pass_does_not_end_the_thread():
    janitor = FakeJanitor(stop_after=2, raise_first=True)
    thread = janitor.thread = UploadJanitorThread(janitor, interval_s=0)

    thread.start()
    assert thread.join(timeout=5)

    assert janitor.calls == 2


def test_stop_ends_a_waiting_thread_at_once():
    janitor = FakeJanitor(stop_after=10**9)
    thread = janitor.thread = UploadJanitorThread(janitor, interval_s=10**6)
    thread.start()

    assert thread.stop(timeout=5)
    assert janitor.calls == 0  # the first periodic pass waits one interval (startup already ran)


def test_a_thread_never_started_stops_cleanly():
    thread = UploadJanitorThread(FakeJanitor(stop_after=1), interval_s=1)

    assert thread.stop(timeout=1)
    assert not thread.is_alive()


# ── shutdown never releases the instance lock while a pass may still write ──

class BlockingJanitor:
    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()

    def run_once(self):
        self.entered.set()
        self.release.wait(10)


def test_done_resolves_only_when_the_thread_has_ended():
    janitor = BlockingJanitor()
    thread = UploadJanitorThread(janitor, interval_s=0)
    thread.start()
    assert janitor.entered.wait(5)

    assert thread.stop(timeout=0) is False  # mid-pass: not ended
    assert not thread.done.done()

    janitor.release.set()
    thread.done.result(timeout=5)
    assert not thread.is_alive()


def test_a_never_started_thread_is_done():
    thread = UploadJanitorThread(BlockingJanitor(), interval_s=1)

    assert thread.join(timeout=0)
    assert thread.done.done()


def test_shutdown_keeps_the_instance_lock_while_a_janitor_pass_runs(configure_app, tmp_path, monkeypatch):
    main = configure_app(env={"ENABLE_UPLOAD_JANITOR": "true", "UPLOAD_JANITOR_INTERVAL_S": "1"})
    janitor = BlockingJanitor()
    real_thread = main.upload_janitor.UploadJanitorThread
    monkeypatch.setattr(main.upload_janitor, "UploadJanitorThread",
                        lambda _real, *, interval_s: real_thread(janitor, interval_s=0))
    monkeypatch.setattr(main, "IDENTITY_JOIN_TIMEOUT_S", 0.01)

    with TestClient(main.app) as client:
        thread = client.app.state.upload_janitor_thread
        assert janitor.entered.wait(5)

    assert _lock_is_held(tmp_path / "data")  # the pass may still write: lock kept

    janitor.release.set()
    assert thread.join(timeout=5)  # the thread resolves done (and its callbacks) before it ends
    assert not _lock_is_held(tmp_path / "data")
