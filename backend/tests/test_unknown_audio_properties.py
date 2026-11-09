"""SC-16l: unknown audio properties are NULL, never 0.

``trackmetadata.duration``, ``sample_rate_hz`` and ``channels`` store NULL for
unknown. The upgrade converts the old ingest default (0) to NULL WITHOUT
bumping revisions (a bump would flag every download stale, as with the v9
bitrate fix). Ingest writes NULL when ffprobe has no value; the API returns
null.
"""

import sqlite3
import uuid

from app.models import Track, TrackMetaData
from app.services.metadata import build_track_metadata

from tests.schema_fixtures import (
    insert_v9_track,
    make_v9_database,
    open_database,
    user_version,
)


def _probe(audio_stream: dict, fmt: dict | None = None) -> dict:
    return {"streams": [{"codec_type": "audio", **audio_stream}], "format": fmt or {"tags": {}}}


def test_defaults_are_unknown_not_zero():
    meta = TrackMetaData()
    assert meta.duration is None
    assert meta.sample_rate_hz is None
    assert meta.channels is None


def test_ingest_reports_missing_values_as_none():
    meta = build_track_metadata(_probe({"codec_name": "flac"}))
    assert meta is not None
    assert meta.codec == "flac"
    assert meta.duration is None
    assert meta.sample_rate_hz is None
    assert meta.channels is None


def test_ingest_reports_unparseable_duration_as_none():
    # ffprobe prints "N/A" for streams without a known duration.
    meta = build_track_metadata(
        _probe({"codec_name": "mp3", "duration": "N/A", "sample_rate": "N/A"})
    )
    assert meta is not None
    assert meta.duration is None
    assert meta.sample_rate_hz is None


def test_ingest_keeps_known_values():
    meta = build_track_metadata(
        _probe(
            {
                "codec_name": "flac",
                "duration": "181.5",
                "sample_rate": "48000",
                "channels": 2,
            }
        )
    )
    assert meta.duration == 181.5
    assert meta.sample_rate_hz == 48000
    assert meta.channels == 2


def test_is_empty_does_not_rely_on_zero_sentinels():
    assert TrackMetaData().is_empty() is True
    assert TrackMetaData(codec="flac").is_empty() is False
    assert TrackMetaData(duration=12.0).is_empty() is False
    # A real reading of 0 channels is still a reading, not "nothing known".
    assert TrackMetaData(channels=0).is_empty() is False


def _uuid() -> str:
    return str(uuid.uuid4())


def test_add_track_stores_null_and_reads_back_none(tmp_path):
    db = open_database(tmp_path / "db.sqlite")
    uid = _uuid()
    added = db.add_track(
        Track(
            uuid_id=uid,
            file_path=tmp_path / "a.flac",
            metadata=TrackMetaData(title="t", artist="a", codec="flac"),
        )
    )
    assert added is True
    conn = sqlite3.connect(tmp_path / "db.sqlite")
    try:
        row = conn.execute(
            "SELECT duration, sample_rate_hz, channels FROM trackmetadata WHERE uuid_id = ?",
            (uid,),
        ).fetchone()
    finally:
        conn.close()
    assert row == (None, None, None)
    track = db.get_track_by_uuid(uid)
    assert track.metadata.duration is None
    assert track.metadata.sample_rate_hz is None
    assert track.metadata.channels is None


def test_upgrade_converts_stored_zeros_to_null_without_bumping_revisions(tmp_path):
    path = tmp_path / "db.sqlite"
    make_v9_database(path)
    conn = sqlite3.connect(path)
    conn.execute("INSERT INTO artists (id, name) VALUES (1, 'Artist')")
    conn.execute("INSERT INTO albums (id, name, artist_id) VALUES (1, 'Album', 1)")
    unknown, known = _uuid(), _uuid()
    insert_v9_track(
        conn, track_id=1, uuid_id=unknown, artist_id=1, album_id=1, revision=5,
        duration=0.0, sample_rate_hz=0, channels=0,
    )
    insert_v9_track(
        conn, track_id=2, uuid_id=known, artist_id=1, album_id=1, revision=6,
        duration=200.0, sample_rate_hz=44100, channels=2,
    )
    conn.execute("UPDATE revision_counter SET value = 6")
    conn.commit()
    conn.close()

    open_database(path)

    assert user_version(path) >= 10
    conn = sqlite3.connect(path)
    try:
        rows = dict(
            (r[0], r[1:])
            for r in conn.execute(
                "SELECT uuid_id, duration, sample_rate_hz, channels FROM trackmetadata"
            )
        )
        assert rows[unknown] == (None, None, None)
        assert rows[known] == (200.0, 44100, 2)
        revisions = dict(conn.execute("SELECT uuid_id, revision FROM tracks").fetchall())
        assert revisions == {unknown: 5, known: 6}
        assert conn.execute("SELECT value FROM revision_counter").fetchone()[0] == 6
    finally:
        conn.close()


def test_upgrade_is_idempotent_on_second_open(tmp_path):
    path = tmp_path / "db.sqlite"
    make_v9_database(path)
    open_database(path)
    first = user_version(path)
    open_database(path)
    assert user_version(path) == first


def test_api_returns_null_for_unknown_audio_properties(tmp_path, monkeypatch):
    import importlib
    import sys

    from fastapi.testclient import TestClient

    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")
    sys.modules.pop("app.main", None)
    sys.modules.pop("app.config", None)
    import app.main

    importlib.reload(app.main)
    with TestClient(app.main.app) as client:
        uid = _uuid()
        client.app.state.database.add_track(
            Track(
                uuid_id=uid,
                file_path=tmp_path / "a.flac",
                metadata=TrackMetaData(title="t", artist="a", codec="flac"),
            )
        )
        body = client.get(f"/tracks/{uid}").json()
        assert body["metadata"]["duration"] is None
        assert body["metadata"]["sample_rate_hz"] is None
        assert body["metadata"]["channels"] is None
        changes = client.get("/changes", params={"after_revision": 0}).json()
        meta = next(c for c in changes["changes"] if c["uuid_id"] == uid)["track"]["metadata"]
        assert meta["duration"] is None


def test_ingest_treats_non_finite_duration_as_unknown():
    # NaN/Infinity are not durations, and are not valid JSON on the wire.
    for raw in ("nan", "inf", "-inf"):
        meta = build_track_metadata(_probe({"codec_name": "mp3", "duration": raw}))
        assert meta.duration is None, raw
