"""9D.2a (spec §7.7 para 2, SC-23 9D note, 9-U09 "the subscriber never
raises"): one failing event in a multi-event ``POST /history`` loses only its
own outbox row. The subscriber wraps each event in its own ``try`` and logs
one ERROR line naming the exception class and the event UUID and nothing else
(no exception message, no tag, no secret); it never raises, so the hook's
whole-batch rollback and its ``history_hook_failures`` rows never happen.

The failure is real, not mocked: an outbox row already holding the second
event's UUID makes that event's insert hit the primary key."""

import json
import logging

import pytest

from tests import lastfm_secrets as planted
from tests.lastfm_outbox_helpers import add_catalog_track, history_uuids, hook_failures, listen, outbox, outbox_rig, post
from tests.lastfm_routes import admin_id, clean_env, execute, seed_connection

ORPHAN_PAYLOAD = {"artist": "Orphan", "track": "Row", "timestamp": 1}


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _plant_orphan(rig, owner, event_uuid):
    execute(
        rig,
        "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, status, attempts, alone,"
        " created_at) VALUES (?, ?, ?, 1, 'pending', 0, 0, 1)",
        (event_uuid, owner, json.dumps(ORPHAN_PAYLOAD)),
    )


def _errors(caplog):
    return [r for r in caplog.records if r.levelno >= logging.ERROR]


def test_one_failing_event_in_three_loses_only_its_own_row(open_app_client, tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        track = add_catalog_track(rig, tmp_path / "m", owner, title="Secret-Looking Title")
        events = [listen(track, rig.wall.ms - (300 - i) * 1000) for i in range(3)]
        failing = events[1]["event_uuid"]
        _plant_orphan(rig, owner, failing)
        caplog.clear()

        response = post(rig, events)

        assert sorted(response.json()["acknowledged"]) == sorted(e["event_uuid"] for e in events)
        assert {e["event_uuid"] for e in events} <= history_uuids(rig)
        by_uuid = {row["event_uuid"]: row for row in outbox(rig)}
        assert set(by_uuid) == {e["event_uuid"] for e in events}
        assert by_uuid[failing]["payload"] == ORPHAN_PAYLOAD, "the orphan row is untouched"
        assert by_uuid[failing]["created_at"] == 1
        assert by_uuid[events[0]["event_uuid"]]["payload"]["track"] == "Secret-Looking Title"
        assert by_uuid[events[2]["event_uuid"]]["payload"]["track"] == "Secret-Looking Title"
        assert hook_failures(rig) == []

        [error] = _errors(caplog)
        line = error.getMessage()
        assert failing in line
        assert "IntegrityError" in line
        assert error.exc_info is None and error.exc_text is None
        assert "UNIQUE" not in line and "constraint" not in line.lower(), "no exception message text"
        assert "Secret-Looking Title" not in caplog.text and "Radiohead" not in caplog.text
        for other in (events[0]["event_uuid"], events[2]["event_uuid"]):
            assert other not in caplog.text
        planted.assert_no_secret(caplog.text, "the captured log")


def test_every_failing_event_logs_once_and_the_batch_still_commits(open_app_client, tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        events = [listen(track, rig.wall.ms - (300 - i) * 1000) for i in range(3)]
        for event in events:
            _plant_orphan(rig, owner, event["event_uuid"])
        caplog.clear()

        post(rig, events)

        assert {e["event_uuid"] for e in events} <= history_uuids(rig)
        assert [row["payload"] for row in outbox(rig)] == [ORPHAN_PAYLOAD] * 3
        assert hook_failures(rig) == []
        assert sorted(e["event_uuid"] for e in events) == sorted(
            next(u for u in (ev["event_uuid"] for ev in events) if u in r.getMessage()) for r in _errors(caplog)
        )
