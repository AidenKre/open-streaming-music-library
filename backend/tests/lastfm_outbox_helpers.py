"""Helpers for the scrobble-outbox subscriber tests (9D.2a): catalog tracks
with exact tag values, listens posted through the real ``POST /history`` and
the outbox rows read back in plain SQL.

``outbox_rig`` opens a started app (``tests/lastfm_routes.open_rig``) and
re-installs the subscriber with the rig's fixed wall clock, so the server
clock of spec §7.7 step 6 is ``rig.wall``."""

import contextlib
import json
import sqlite3
import uuid
from pathlib import Path

from app.models import Track, TrackMetaData
from app.services.lastfm_outbox import install_scrobble_outbox
from tests.lastfm_routes import admin_id, open_rig, rows, seed_connection

OCCURRED_AT = 1_799_999_000_000  # 1_000 s before the rig's wall clock
TIMESTAMP = 1_799_999_000

OUTBOX_COLUMNS = (
    "event_uuid", "owner_id", "payload", "listened_at_s", "status", "result_code",
    "attempts", "alone", "created_at", "done_at",
)


@contextlib.contextmanager
def outbox_rig(open_app_client, server_state: str = "running"):
    with open_rig(open_app_client, server_state) as rig:
        install_scrobble_outbox(rig.state, now_ms=rig.wall)
        yield rig


def add_catalog_track(rig, folder: Path, owner: int, **tags) -> str:
    """A track of ``owner`` through the real ``add_track``, then its four
    Last.fm-relevant tags set to exactly the given values (None, "", spaces
    and all). Defaults: a real song with every tag present."""
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{uuid.uuid4().hex}.flac"
    path.write_bytes(b"not really flac")
    track = Track(
        file_path=path,
        metadata=TrackMetaData(
            codec="flac", duration=284.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            title="Airbag", artist="Radiohead", album="OK Computer",
        ),
    )
    assert rig.db.add_track(track, owner_id=owner)
    values = {"title": "Airbag", "artist": "Radiohead", "album": "OK Computer", "album_artist": None}
    values.update(tags)
    conn = sqlite3.connect(rig.db.context.database_path)
    try:
        conn.execute(
            "UPDATE trackmetadata SET title = ?, artist = ?, album = ?, album_artist = ? WHERE uuid_id = ?",
            (values["title"], values["artist"], values["album"], values["album_artist"], track.uuid_id),
        )
        conn.commit()
    finally:
        conn.close()
    return track.uuid_id


def listen(track_uuid: str, occurred_at: int, **overrides) -> dict:
    """A qualifying Last.fm listen by default: 200 of 284 seconds played."""
    event = {
        "event_uuid": str(uuid.uuid4()),
        "kind": "play",
        "entity_type": "track",
        "entity_ref": track_uuid,
        "occurred_at": occurred_at,
        "seconds_played": 200.0,
        "track_length": 284.0,
    }
    event.update(overrides)
    return event


def post(rig, events, headers=None):
    response = rig.client.post("/history", json={"events": events}, headers=headers)
    assert response.status_code == 200, response.text
    return response


def outbox(rig, owner: int | None = None) -> list[dict]:
    sql = f"SELECT {', '.join(OUTBOX_COLUMNS)} FROM scrobble_outbox"
    params = ()
    if owner is not None:
        sql += " WHERE owner_id = ?"
        params = (owner,)
    found = [dict(zip(OUTBOX_COLUMNS, row)) for row in rows(rig, sql + " ORDER BY created_at, event_uuid", params)]
    for row in found:
        row["payload"] = json.loads(row["payload"])
    return found


def history_uuids(rig) -> set[str]:
    return {uid for (uid,) in rows(rig, "SELECT event_uuid FROM history_events")}


def hook_failures(rig) -> list:
    return rows(rig, "SELECT subscriber, event_uuid FROM history_hook_failures")


def queue(open_app_client, tmp_path, *, tags=None, occurred_at=OCCURRED_AT, **event):
    """Posts one listen of a fresh track with ``tags``; returns its payload, or
    None when no row was made (the history row is always stored)."""
    with outbox_rig(open_app_client) as rig:
        owner = admin_id(rig)
        seed_connection(rig, owner, opted_in=True)
        track = add_catalog_track(rig, tmp_path / "m", owner, **(tags or {}))
        sent = listen(track, occurred_at, **event)

        post(rig, [sent])

        assert sent["event_uuid"] in history_uuids(rig)
        found = outbox(rig)
        assert len(found) <= 1
        return found[0]["payload"] if found else None
