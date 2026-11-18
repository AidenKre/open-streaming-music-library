"""9D.2a (spec §7.7, SC-23, SC-28, 9-U09 subscriber part): the
``lastfm_scrobble_outbox`` subscriber on the history-insert hook.

- It is registered whenever the server is not ``off`` (running, stopped at
  startup, stopped at run time all queue) and is gone when it is ``off``.
- It runs inside ``POST /history``'s own transaction: a history failure after
  the outbox write rolls both back; a replayed duplicate creates nothing;
  events stored before opt-in are never backfilled.
- One row per new event that passes, in order: the owner has ``opted_in = 1``
  and ``needs_reconnect = 0``; ``kind = 'play'`` and ``entity_type = 'track'``;
  the track is in the owner's catalog (``live_tracks``: not another user's, not
  pending deletion).
- The row: ``status 'pending'``, no result code, no attempts, not ``alone``,
  ``created_at`` the server clock, no ``done_at``, ``listened_at_s =
  occurred_at // 1000`` and a frozen payload in Last.fm's names.

Expected values here are written out by hand from the spec, never computed by
the code under test."""

import sqlite3
import time

import pytest

from app.services import history_hooks, lastfm_client
from tests.lastfm_outbox_helpers import (
    add_catalog_track,
    history_uuids,
    hook_failures,
    listen,
    outbox,
    outbox_rig,
    post,
)
from tests.lastfm_routes import (
    BASE,
    admin_id,
    clean_env,
    open_rig,
    second_user,
    seed_connection,
    seed_token,
)
from tests.lastfm_sender_rig import execute
from tests.pending_deletion import mark_pending_deletion


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    clean_env(monkeypatch)


def _opted_in(rig, owner, **kwargs):
    return seed_connection(rig, owner, opted_in=True, **kwargs)


# ── the row ──────────────────────────────────────────────────────────────────


def test_a_qualifying_listen_is_queued_with_its_row_and_frozen_payload(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        occurred_at = rig.wall.ms - 300_123  # 1_799_999_699_877 ms
        event = listen(track, occurred_at)

        post(rig, [event])

        assert outbox(rig) == [{
            "event_uuid": event["event_uuid"],
            "owner_id": owner,
            "payload": {
                "artist": "Radiohead",
                "track": "Airbag",
                "timestamp": 1_799_999_699,
                "album": "OK Computer",
                "duration": 284,
            },
            "listened_at_s": 1_799_999_699,
            "status": "pending",
            "result_code": None,
            "attempts": 0,
            "alone": 0,
            "created_at": rig.wall.ms,
            "done_at": None,
        }]
        assert hook_failures(rig) == []


def test_every_field_the_hook_writes_is_a_field_the_sender_sends(open_app_client, tmp_path):
    """Other-issues row 84: the payload names the history hook writes (here with
    every optional one present) are fields the sender's row check accepts, so a
    renamed or added key cannot leave every queued row refused as invalid_row."""
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner, album_artist="Thom Yorke")

        post(rig, [listen(track, rig.wall.ms - 300_000)])

        [row] = outbox(rig)
    assert set(row["payload"]) == {"artist", "track", "timestamp", "album", "albumArtist", "duration"}
    assert set(row["payload"]) <= lastfm_client._ROW_FIELDS
    lastfm_client.check_scrobble_row(row["payload"])  # raises RowRefused on any refused field


def test_listened_at_is_the_listen_start_in_whole_unix_seconds(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        events = [listen(track, ms) for ms in (1_700_000_000_000, 1_700_000_000_999, 1_700_000_001_000)]

        post(rig, events)

        got = {row["event_uuid"]: (row["listened_at_s"], row["payload"]["timestamp"]) for row in outbox(rig)}
        assert got == {
            events[0]["event_uuid"]: (1_700_000_000, 1_700_000_000),
            events[1]["event_uuid"]: (1_700_000_000, 1_700_000_000),
            events[2]["event_uuid"]: (1_700_000_001, 1_700_000_001),
        }


def test_each_new_event_of_a_batch_gets_its_own_row(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        events = [listen(track, rig.wall.ms - 1_000_000 + i * 1000) for i in range(5)]

        post(rig, events)

        assert sorted(row["event_uuid"] for row in outbox(rig)) == sorted(e["event_uuid"] for e in events)


def test_a_later_rename_does_not_change_a_queued_payload(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        post(rig, [listen(track, rig.wall.ms - 300_000)])
        [before] = outbox(rig)

        execute(rig, "UPDATE trackmetadata SET title = 'Renamed', artist = 'Someone' WHERE uuid_id = ?", (track,))

        assert outbox(rig) == [before]


# ── registration per server state ────────────────────────────────────────────


def _now_ms():
    return time.time_ns() // 1_000_000


@pytest.mark.parametrize(("server_state", "queued"), [("off", 0), ("running", 1), ("stopped", 1)])
def test_the_startup_subscriber_queues_unless_the_server_is_off(open_app_client, tmp_path, server_state, queued):
    # No re-install here: the subscriber as startup registered it, with the real clock.
    with open_rig(open_app_client, server_state) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)

        post(rig, [listen(track, _now_ms() - 300_000)])

        assert len(outbox(rig)) == queued
        assert hook_failures(rig) == []


def test_listens_keep_queuing_after_a_run_time_stop(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        rig.state.stop("a fixed test cause")

        post(rig, [listen(track, rig.wall.ms - 300_000)])

        assert len(outbox(rig)) == 1


def test_an_off_server_after_a_running_one_has_no_subscriber_left(open_app_client, tmp_path, monkeypatch):
    # The same data directory restarted with Last.fm switched off: the running
    # app's row is still there; the off app adds none for the still opted-in user.
    with open_rig(open_app_client, "running") as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        post(rig, [listen(track, _now_ms() - 300_000)])
        [first] = outbox(rig)  # control: it was registered
    clean_env(monkeypatch)  # the running app's LASTFM_* variables would otherwise stay set
    with open_rig(open_app_client, "off") as rig:
        assert rig.state.service.value == "off"
        assert rig.db.get_lastfm_connection(owner_id=owner)["opted_in"] is True

        post(rig, [listen(track, _now_ms() - 200_000)])

        assert outbox(rig) == [first]
        assert hook_failures(rig) == []


# ── step 1: opted in and not needing a reconnect ─────────────────────────────


@pytest.mark.parametrize("setup", ["never_connected", "awaiting_authorization", "not_opted_in", "needs_reconnect"])
def test_only_an_opted_in_owner_without_needs_reconnect_gets_rows(open_app_client, tmp_path, setup):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        if setup == "awaiting_authorization":
            seed_token(rig, owner)
        elif setup == "not_opted_in":
            seed_connection(rig, owner)
        elif setup == "needs_reconnect":
            seed_connection(rig, owner, opted_in=True, needs_reconnect=True)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        bea, bea_headers = second_user(rig)  # control: an opted-in user in the same server
        _opted_in(rig, bea, account="beta")
        beas_track = add_catalog_track(rig, tmp_path / "b", bea)
        mine = listen(track, rig.wall.ms - 300_000)
        beas = listen(beas_track, rig.wall.ms - 300_000)

        post(rig, [mine])
        post(rig, [beas], headers=bea_headers)

        assert [(row["event_uuid"], row["owner_id"]) for row in outbox(rig)] == [(beas["event_uuid"], bea)]
        assert {mine["event_uuid"], beas["event_uuid"]} <= history_uuids(rig)


def test_listens_stored_before_opt_in_are_never_backfilled(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        connection_id = seed_connection(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        before = listen(track, rig.wall.ms - 600_000)
        post(rig, [before])
        assert rig.client.post(f"{BASE}/enable", json={"connection_id": connection_id}).status_code == 200
        after = listen(track, rig.wall.ms - 300_000)

        post(rig, [before, after])  # the earlier one is now a replayed duplicate

        assert [row["event_uuid"] for row in outbox(rig)] == [after["event_uuid"]]


# ── step 2: plays of tracks only ─────────────────────────────────────────────


@pytest.mark.parametrize(("kind", "entity_type"), [("skip", "track"), ("play", "album"), ("Play", "track")])
def test_only_track_plays_are_queued(open_app_client, tmp_path, kind, entity_type):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        other = listen(track, rig.wall.ms - 300_000, kind=kind, entity_type=entity_type)
        play = listen(track, rig.wall.ms - 200_000)

        post(rig, [other, play])

        assert [row["event_uuid"] for row in outbox(rig)] == [play["event_uuid"]]
        assert {other["event_uuid"], play["event_uuid"]} <= history_uuids(rig)


# ── step 4: the track is in the owner's catalog ──────────────────────────────


def test_a_track_that_is_not_in_the_owners_catalog_is_not_queued(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        mine = add_catalog_track(rig, tmp_path / "m", owner)
        bea, _ = second_user(rig)
        beas_track = add_catalog_track(rig, tmp_path / "b", bea)
        pending = add_catalog_track(rig, tmp_path / "p", owner)
        mark_pending_deletion(rig.db.context.database_path, pending)
        events = {
            "unknown": listen("a1000000-0000-4000-8000-0000000000aa", rig.wall.ms - 500_000),
            "foreign": listen(beas_track, rig.wall.ms - 400_000),
            "pending_deletion": listen(pending, rig.wall.ms - 300_000),
            "control": listen(mine, rig.wall.ms - 200_000),
        }

        post(rig, list(events.values()))

        assert [row["event_uuid"] for row in outbox(rig)] == [events["control"]["event_uuid"]]
        assert {e["event_uuid"] for e in events.values()} <= history_uuids(rig)
        assert hook_failures(rig) == []


def test_a_deleted_track_is_not_queued(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        gone = add_catalog_track(rig, tmp_path / "g", owner)
        kept = add_catalog_track(rig, tmp_path / "k", owner)
        assert rig.db.delete_track(gone, owner_id=owner)
        events = [listen(gone, rig.wall.ms - 300_000), listen(kept, rig.wall.ms - 200_000)]

        post(rig, events)

        assert [row["event_uuid"] for row in outbox(rig)] == [events[1]["event_uuid"]]


# ── one transaction with the history insert ──────────────────────────────────


def test_a_history_failure_after_the_outbox_write_rolls_both_back(open_app_client, tmp_path, monkeypatch):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        seen_inside = []
        real = history_hooks.on_history_events_inserted

        def then_fail(conn, new_events):
            real(conn, new_events)
            seen_inside.append(conn.execute("SELECT count(*) FROM scrobble_outbox").fetchone()[0])
            raise sqlite3.OperationalError("the history insert fails after the hooks ran")

        monkeypatch.setattr(history_hooks, "on_history_events_inserted", then_fail)
        event = listen(track, rig.wall.ms - 300_000)

        response = rig.client.post("/history", json={"events": [event]})

        assert response.status_code == 503
        assert seen_inside == [1], "the outbox row was written inside the history transaction"
        assert outbox(rig) == []
        assert event["event_uuid"] not in history_uuids(rig)


def test_a_replayed_duplicate_creates_nothing(open_app_client, tmp_path):
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        _opted_in(rig, owner)
        track = add_catalog_track(rig, tmp_path / "m", owner)
        first = listen(track, rig.wall.ms - 300_000)
        post(rig, [first])
        [row] = outbox(rig)
        rig.wall.ms += 60_000

        post(rig, [first])
        post(rig, [first, first])

        assert outbox(rig) == [row]
        assert hook_failures(rig) == []


# ── review r1 F2: the process-wide hook never outlives its app ───────────────


def test_r1_a_failed_startup_leaves_no_subscriber_registered(configure_app, monkeypatch):
    from fastapi.testclient import TestClient

    from app.services.lastfm_outbox import HOOK_NAME
    from tests.lastfm_secrets import valid_env

    main = configure_app(env=valid_env())

    def boom():
        raise RuntimeError("startup fails after the Last.fm state was built")

    monkeypatch.setattr(main, "_startup_locked", boom)
    with pytest.raises(RuntimeError):
        with TestClient(main.app):
            pass

    assert HOOK_NAME not in history_hooks._hooks


def test_r1_a_failing_client_close_at_shutdown_still_removes_the_subscriber(open_app_client):
    from app.services.lastfm_outbox import HOOK_NAME

    def boom():
        raise RuntimeError("closing the Last.fm client fails")

    with pytest.raises(RuntimeError):
        with open_rig(open_app_client) as rig:
            assert HOOK_NAME in history_hooks._hooks  # control
            rig.accounts.client.close = boom

    assert HOOK_NAME not in history_hooks._hooks
