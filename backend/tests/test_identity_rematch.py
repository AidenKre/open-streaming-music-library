"""Phase 6.5A.3: the startup ``matcher_version`` re-match (spec §6.4 last
reconcile bullet; review 6.5-U10 "dismissed survives recompute and
re-match").

"Computes ``matcher_version`` ... When it differs from the value in
``app_settings``, it sets every row's ``match_state='pending'`` (a re-match
with no decoding) and stores the new value."
"""

import sqlite3

import pytest

from app.database import ANY_OWNER
from app.services.duplicate_detection import MatcherParams, matcher_version
from app.services.identity_worker import reconcile_audio_identity
from tests.identity_worker_fakes import TOOLS, make_worker
from tests.identity_worker_fixtures import DIGEST_A, add_track, identity, sql
from tests.owned_database import add_test_user


def _reconcile(db, version):
    reconcile_audio_identity(db, tool_versions=TOOLS, fingerprinter_present=False,
                             matcher_version=version)


def _stored(db):
    rows = sql(db, "SELECT value FROM app_settings WHERE key = 'matcher_version'")
    return rows[0]["value"] if rows else None


MATCHED = {"exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A,
           "sample_rate_hz": 44100, "channels": 2, "match_state": "current",
           "matcher_version": "v1"}


def test_a_new_matcher_version_requeues_every_row_and_is_stored(db):
    bob = add_test_user(db, "bob")
    rows = [add_track(db, f"/m/{i}.flac", identity=MATCHED) for i in range(3)]
    rows.append(add_track(db, "/m/his.flac", owner_id=bob, identity=MATCHED))
    sql(db, "INSERT INTO app_settings (key, value) VALUES ('matcher_version', 'v1')")

    _reconcile(db, "v2")

    assert [identity(db, u)["match_state"] for u in rows] == ["pending"] * 4
    assert _stored(db) == "v2"


def test_the_requeue_touches_nothing_but_the_match_state(db):
    uuid_id = add_track(db, "/m/a.flac", identity=MATCHED)
    before = identity(db, uuid_id)
    sql(db, "INSERT INTO app_settings (key, value) VALUES ('matcher_version', 'v1')")

    _reconcile(db, "v2")

    after = identity(db, uuid_id)
    assert after["match_state"] == "pending"
    assert {k: v for k, v in after.items() if k != "match_state"} == {
        k: v for k, v in before.items() if k != "match_state"}


def test_an_unchanged_matcher_version_requeues_nothing(db):
    uuid_id = add_track(db, "/m/a.flac", identity=MATCHED)
    sql(db, "INSERT INTO app_settings (key, value) VALUES ('matcher_version', 'v1')")

    _reconcile(db, "v1")
    _reconcile(db, "v1")

    assert identity(db, uuid_id)["match_state"] == "current"
    assert _stored(db) == "v1"


def test_the_first_start_stores_the_version(db):
    uuid_id = add_track(db, "/m/a.flac", identity=MATCHED)

    _reconcile(db, "v1")

    assert _stored(db) == "v1"
    assert identity(db, uuid_id)["match_state"] == "pending"


def test_no_version_given_leaves_matching_alone(db):
    uuid_id = add_track(db, "/m/a.flac", identity=MATCHED)

    reconcile_audio_identity(db, tool_versions=TOOLS, fingerprinter_present=False)

    assert identity(db, uuid_id)["match_state"] == "current"
    assert _stored(db) is None


def test_a_failed_requeue_never_stops_startup_and_keeps_the_old_version(db, monkeypatch, caplog):
    uuid_id = add_track(db, "/m/a.flac", identity=MATCHED)
    sql(db, "INSERT INTO app_settings (key, value) VALUES ('matcher_version', 'v1')")

    def boom(*args, **kwargs):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(db, "requeue_matching", boom)

    _reconcile(db, "v2")  # does not raise

    assert _stored(db) == "v1"
    assert identity(db, uuid_id)["match_state"] == "current"
    assert caplog.records


def test_requeue_matching_takes_any_owner_only(db):
    with pytest.raises(TypeError):
        db.requeue_matching("v2", owner_id=db.owner_id)
    assert db.requeue_matching("v2", owner_id=ANY_OWNER) == 0


def test_a_dismissed_pair_survives_the_rematch(db, tmp_path):
    music = tmp_path / "music"
    music.mkdir()
    uuids = []
    for name in ("x", "y"):
        path = music / f"{name}.flac"
        path.write_bytes(b"same")
        uuids.append(add_track(db, path))
    worker = make_worker(db, matcher_version="v1")
    for _ in range(10):
        worker.process_one()
    sql(db, "UPDATE track_duplicate_candidates SET status = 'dismissed', status_changed_at = 9")

    _reconcile(db, "v2")
    worker = make_worker(db, matcher_version="v2")
    for _ in range(10):
        worker.process_one()

    [row] = sql(db, "SELECT * FROM track_duplicate_candidates")
    assert (row["status"], row["status_changed_at"], row["matcher_version"]) == ("dismissed", 9, "v2")
    assert {identity(db, u)["matcher_version"] for u in uuids} == {"v2"}


def test_the_app_version_is_derived_from_the_matcher_settings():
    from app.config import settings
    from app.services import identity_worker

    assert identity_worker.default_matcher_version() == matcher_version(
        MatcherParams.from_settings(settings))


def test_startup_stores_the_active_matcher_version(configure_app):
    from fastapi.testclient import TestClient

    from app.services import identity_worker

    with TestClient(configure_app().app) as c:
        stored = c.app.state.database.read_setting("matcher_version")

    assert stored == identity_worker.default_matcher_version()


def test_a_restart_with_another_stored_matcher_version_requeues_matching(configure_app, tmp_path):
    # Review r1 R1-13: the startup wiring, not only the reconcile function.
    from fastapi.testclient import TestClient

    from app.services import identity_worker

    with TestClient(configure_app().app) as c:
        db = c.app.state.database
        owner = c.app.state.admin_user_id
    uuid_id = add_track(db, tmp_path / "music" / "x.flac", owner_id=owner, identity=MATCHED)

    with TestClient(configure_app().app):
        pass  # same matcher settings: nothing to re-match
    assert identity(db, uuid_id)["match_state"] == "current"

    sql(db, "UPDATE app_settings SET value = 'an older matcher' WHERE key = 'matcher_version'")
    with TestClient(configure_app().app):
        pass

    assert identity(db, uuid_id)["match_state"] == "pending"
    assert _stored(db) == identity_worker.default_matcher_version()
