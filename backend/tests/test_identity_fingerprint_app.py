"""Phase 6.5B.1b: the fingerprinter in the app's startup (spec §4.1 "Selection",
§6.2 writers, §6.4 startup reconcile; review 6.5-U07).

``detect_fingerprinter(settings)`` runs once at startup and its result is
stored on ``app.state.fingerprinter`` before the identity reconcile and before
any pipeline is built, so the writers' fingerprint state, the reconcile's
transitions, the tool versions and the worker all come from that one value.
App tests run with ``AUDIO_FINGERPRINT_BACKEND=off`` unless they ask.
"""

import sqlite3
import uuid as uuid_mod

import pytest
from fastapi.testclient import TestClient

from app.services import fingerprinter as fingerprinter_mod
from app.services import identity_worker as identity_worker_mod
from app.services import pipeline as pipeline_mod
from tests.identity_worker_fakes import FakeFingerprinter

WATCH = {"ENABLE_FILE_WATCHER": "true"}


def _add_track(db_path, owner_id, fp_state):
    uuid_id = str(uuid_mod.uuid4())
    conn = sqlite3.connect(db_path)
    try:
        track_id = conn.execute(
            "INSERT INTO tracks (uuid_id, file_path, owner_id) VALUES (?, '/m/x.flac', ?)", (uuid_id, owner_id),
        ).lastrowid
        conn.execute("INSERT INTO trackmetadata (track_id, uuid_id, codec, has_album_art) VALUES (?, ?, 'flac', 0)",
                     (track_id, uuid_id))
        conn.execute("INSERT INTO track_audio_identity (uuid_id, exact_state, fp_state, match_state) "
                     "VALUES (?, 'current', ?, 'current')", (uuid_id, fp_state))
        conn.commit()
    finally:
        conn.close()
    return uuid_id


def _fp_state(db_path, uuid_id):
    conn = sqlite3.connect(db_path)
    try:
        return conn.execute("SELECT fp_state FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,)).fetchone()[0]
    finally:
        conn.close()


@pytest.fixture
def fake_detect(monkeypatch):
    """detect_fingerprinter replaced by one that finds a fake fingerprinter."""
    found = FakeFingerprinter()
    calls = []

    def detect(settings):
        calls.append(settings)
        return found

    monkeypatch.setattr(fingerprinter_mod, "detect_fingerprinter", detect)
    return found, calls


@pytest.fixture
def spies(monkeypatch):
    """Record the reconcile's and the pipelines' fingerprint arguments."""
    seen = {"reconcile": [], "pipeline": [], "order": []}
    real_reconcile = identity_worker_mod.reconcile_audio_identity
    real_pipeline = pipeline_mod.make_pipeline

    def reconcile(*args, **kwargs):
        seen["reconcile"].append(kwargs)
        seen["order"].append("reconcile")
        return real_reconcile(*args, **kwargs)

    def make_pipeline(*args, **kwargs):
        seen["pipeline"].append(kwargs.get("fingerprinter_present"))
        seen["order"].append("pipeline")
        return real_pipeline(*args, **kwargs)

    monkeypatch.setattr(identity_worker_mod, "reconcile_audio_identity", reconcile)
    monkeypatch.setattr(pipeline_mod, "make_pipeline", make_pipeline)
    return seen


def test_with_fingerprinting_off_there_is_no_fingerprinter_and_writers_say_unavailable(configure_app, spies):
    with TestClient(configure_app(env=WATCH).app) as c:
        assert c.app.state.fingerprinter is None
        db_path = c.app.state.database.context.database_path
        owner = c.app.state.admin_user_id
    [kwargs] = spies["reconcile"]
    assert kwargs["fingerprinter_present"] is False and kwargs.get("fingerprint_algorithm") is None
    assert spies["pipeline"] and set(spies["pipeline"]) == {False}

    pending = _add_track(db_path, owner, "pending")
    with TestClient(configure_app().app):
        pass
    assert _fp_state(db_path, pending) == "unavailable"


def test_the_detected_fingerprinter_is_stored_once_before_reconcile_and_pipelines(
        configure_app, fake_detect, spies):
    found, calls = fake_detect
    with TestClient(configure_app(env=WATCH).app) as c:
        assert c.app.state.fingerprinter is found
        settings = c.app.state.settings
    assert calls == [settings]
    [kwargs] = spies["reconcile"]
    assert kwargs["fingerprinter_present"] is True
    assert kwargs["fingerprint_algorithm"] == "chromaprint-2"
    tools = kwargs["tool_versions"]
    assert tools is None or tools.endswith("; fakeprint 1.6.2")
    assert spies["pipeline"] and set(spies["pipeline"]) == {True}
    assert spies["order"][0] == "reconcile"


def test_a_fingerprinter_appearing_at_startup_queues_unavailable_prints(configure_app, fake_detect):
    with TestClient(configure_app().app) as c:
        db_path = c.app.state.database.context.database_path
        owner = c.app.state.admin_user_id
    parked = _add_track(db_path, owner, "unavailable")
    with TestClient(configure_app().app):
        pass
    assert _fp_state(db_path, parked) == "pending"


def test_the_worker_gets_the_fingerprinter(configure_app, fake_detect, monkeypatch):
    found, _ = fake_detect
    built = []
    real = identity_worker_mod.AudioIdentityWorker

    def capture(*args, **kwargs):
        built.append(kwargs)
        return real(*args, **kwargs)

    monkeypatch.setattr(identity_worker_mod, "AudioIdentityWorker", capture)
    with TestClient(configure_app(env={"ENABLE_IDENTITY_WORKER": "true"}).app):
        pass
    [kwargs] = built
    assert kwargs["fingerprinter"] is found
