import importlib
import shutil
import subprocess
import sys
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

_HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
requires_ffmpeg = pytest.mark.skipif(not _HAS_FFMPEG, reason="ffmpeg/ffprobe not available")


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("APP_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("MUSIC_LIBRARY_DIR", str(tmp_path / "music"))
    monkeypatch.setenv("IMPORT_DIR", str(tmp_path / "import"))
    monkeypatch.setenv("ENABLE_FILE_WATCHER", "false")

    sys.modules.pop("app.main", None)
    sys.modules.pop("app.config", None)
    import app.main

    importlib.reload(app.main)

    with TestClient(app.main.app) as c:
        yield c


def _add_track_with_file(
    client, tmp_path: Path, codec: str = "flac", bitrate_kbps: float = 1000.0,
    filename: str = "song.flac", real_audio: bool = False,
) -> Track:
    music_dir = tmp_path / "music"
    music_dir.mkdir(parents=True, exist_ok=True)
    file_path = music_dir / filename
    if real_audio:
        _make_audio(file_path, codec=codec)
    else:
        file_path.write_bytes(b"fake-audio-bytes")
    metadata = TrackMetaData(
        codec=codec, duration=1.0, bitrate_kbps=bitrate_kbps, sample_rate_hz=44100,
        channels=2, title="T", artist="Art",
    )
    track = Track(file_path=file_path, metadata=metadata)
    assert client.app.state.database.add_track(track)
    return client.app.state.database.get_track_by_uuid(track.uuid_id)


def _add_track_without_file(client, tmp_path: Path, codec: str = "flac") -> Track:
    music_dir = tmp_path / "music"
    music_dir.mkdir(parents=True, exist_ok=True)
    file_path = music_dir / "missing.flac"  # never written
    metadata = TrackMetaData(
        codec=codec, duration=1.0, bitrate_kbps=1000.0, sample_rate_hz=44100,
        channels=2, title="T", artist="Art",
    )
    track = Track(file_path=file_path, metadata=metadata)
    assert client.app.state.database.add_track(track)
    return client.app.state.database.get_track_by_uuid(track.uuid_id)


def _make_audio(path: Path, codec: str = "flac") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    codec_flags = {
        "flac": ["-c:a", "flac"],
        "mp3": ["-c:a", "libmp3lame", "-b:a", "192k"],
        "aac": ["-c:a", "aac", "-b:a", "192k"],
    }[codec]
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3",
        *codec_flags, str(path),
    ]
    subprocess.run(cmd, check=True)


def _post_job(client, uuid_id, target_codec, base_revision, target_bitrate_kbps=None, **overrides):
    body = {
        "type": "conversion",
        "uuid_id": uuid_id,
        "params": {"target_codec": target_codec, "target_bitrate_kbps": target_bitrate_kbps},
        "base_revision": base_revision,
    }
    body.update(overrides)
    return client.post("/jobs", json=body)


class TestPostJobs:
    def test_post_jobs__valid_conversion__returns_queued_job(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")

        r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

        assert r.status_code == 200, r.text
        body = r.json()
        assert body["status"] == "queued"
        assert body["uuid_id"] == track.uuid_id
        assert body["target_codec"] == "aac"
        assert body["target_container"] == "m4a"
        assert body["target_bitrate"] == 192
        assert isinstance(body["job_id"], int)

    def test_post_jobs__unknown_uuid__404(self, client):
        r = _post_job(client, "no-such-uuid", "aac", 1, 192)
        assert r.status_code == 404, r.text

    def test_post_jobs__stale_base_revision__409(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        r = _post_job(client, track.uuid_id, "aac", track.revision + 999, 192)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["error"] == "revision_conflict"

    def test_post_jobs__null_base_revision__409_not_422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        r = _post_job(client, track.uuid_id, "aac", None, 192)
        assert r.status_code == 409, r.text

    def test_post_jobs__missing_base_revision_field__422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        body = {
            "type": "conversion", "uuid_id": track.uuid_id,
            "params": {"target_codec": "aac", "target_bitrate_kbps": 192},
        }
        r = client.post("/jobs", json=body)
        assert r.status_code == 422, r.text

    def test_post_jobs__missing_master_file__404(self, client, tmp_path):
        track = _add_track_without_file(client, tmp_path, codec="flac")
        r = _post_job(client, track.uuid_id, "aac", track.revision, 192)
        assert r.status_code == 404, r.text

    def test_post_jobs__unsupported_codec__422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        r = _post_job(client, track.uuid_id, "wav", track.revision)
        assert r.status_code == 422, r.text

    def test_post_jobs__lossless_same_codec__422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        r = _post_job(client, track.uuid_id, "flac", track.revision)
        assert r.status_code == 422, r.text

    def test_post_jobs__lossy_target_missing_bitrate__422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        r = _post_job(client, track.uuid_id, "aac", track.revision, target_bitrate_kbps=None)
        assert r.status_code == 422, r.text

    def test_post_jobs__wrong_type_literal__422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        r = _post_job(client, track.uuid_id, "aac", track.revision, 192, type="upload")
        assert r.status_code == 422, r.text

    def test_post_jobs__unknown_extra_field__422(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac")
        body = {
            "type": "conversion", "uuid_id": track.uuid_id,
            "params": {"target_codec": "aac", "target_bitrate_kbps": 192},
            "base_revision": track.revision,
            "surprise_field": "x",
        }
        r = client.post("/jobs", json=body)
        assert r.status_code == 422, r.text


class TestGetJobs:
    def test_get_jobs__filters_by_uuid_and_status(self, client, tmp_path):
        # Inserted directly via the DB (not POST /jobs) so this test is only
        # exercising the GET query/filter logic, not racing the real
        # background worker pool, which would otherwise pick these jobs up
        # and flip their status non-deterministically before the assertions
        # below run.
        track_a = _add_track_with_file(client, tmp_path, filename="a.flac")
        track_b = _add_track_with_file(client, tmp_path, filename="b.flac")
        db = client.app.state.database
        db.insert_conversion_job(track_a.uuid_id, "aac", "m4a", 192)
        db.insert_conversion_job(track_b.uuid_id, "mp3", "mp3", 320)

        r = client.get("/jobs", params={"uuid_id": track_a.uuid_id})
        assert r.status_code == 200, r.text
        data = r.json()["data"]
        assert len(data) == 1
        assert data[0]["uuid_id"] == track_a.uuid_id

        r = client.get("/jobs", params={"status": "queued"})
        assert len(r.json()["data"]) == 2

        r = client.get("/jobs", params={"status": "done"})
        assert len(r.json()["data"]) == 0

    def test_get_jobs__pagination__cursor_advances(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        for _ in range(5):
            _post_job(client, track.uuid_id, "aac", track.revision, 192)

        r = client.get("/jobs", params={"limit": 2})
        body = r.json()
        assert len(body["data"]) == 2
        assert body["nextCursor"] is not None

        r2 = client.get("/jobs", params={"limit": 2, "cursor": body["nextCursor"]})
        body2 = r2.json()
        assert len(body2["data"]) == 2
        assert body2["data"][0]["job_id"] != body["data"][0]["job_id"]

    def test_get_jobs__no_jobs__empty_data_null_cursor(self, client):
        r = client.get("/jobs")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["data"] == []
        assert body["nextCursor"] is None


class TestDeleteJobs:
    def test_delete_jobs__queued_job__cancelled_true(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        job_id = _post_job(client, track.uuid_id, "aac", track.revision, 192).json()["job_id"]

        r = client.delete(f"/jobs/{job_id}")
        assert r.status_code == 200, r.text
        assert r.json()["cancelled"] is True

        r2 = client.get("/jobs", params={"uuid_id": track.uuid_id})
        assert r2.json()["data"][0]["status"] == "cancelled"

    def test_delete_jobs__already_cancelled__idempotent_false(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        job_id = _post_job(client, track.uuid_id, "aac", track.revision, 192).json()["job_id"]
        client.delete(f"/jobs/{job_id}")

        r = client.delete(f"/jobs/{job_id}")
        assert r.status_code == 200, r.text
        assert r.json()["cancelled"] is False

    def test_delete_jobs__unknown_job_id__200_cancelled_false(self, client):
        r = client.delete("/jobs/999999")
        assert r.status_code == 200, r.text
        assert r.json()["cancelled"] is False


class TestAppInfoConversionBlock:
    def test_app_info__includes_conversion_block(self, client):
        r = client.get("/app/info")
        assert r.status_code == 200, r.text
        body = r.json()
        assert "conversion" in body
        codecs = {t["codec"] for t in body["conversion"]["targets"]}
        assert codecs == {"aac", "alac", "flac", "mp3"}
        lossless = {t["codec"] for t in body["conversion"]["targets"] if t["is_lossless"]}
        assert lossless == {"alac", "flac"}
        assert set(body["conversion"]["bitrate_presets"]) == {320, 256, 192, 128}

    def test_app_info__track_entity_advertises_convert_action(self, client):
        r = client.get("/app/info")
        body = r.json()
        assert "convert" in body["entities"]["track"]["actions"]


@requires_ffmpeg
class TestJobsEndToEnd:
    def test_post_then_poll_until_done__codec_and_path_update(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path, codec="flac", real_audio=True)

        r = _post_job(client, track.uuid_id, "aac", track.revision, 192)
        assert r.status_code == 200, r.text
        job_id = r.json()["job_id"]

        job = None
        for _ in range(50):
            data = client.get("/jobs", params={"uuid_id": track.uuid_id}).json()["data"]
            job = next(j for j in data if j["job_id"] == job_id)
            if job["status"] in ("done", "failed", "cancelled"):
                break
            time.sleep(0.1)

        assert job["status"] == "done", job

        updated = client.get(f"/tracks/{track.uuid_id}").json()
        assert updated["metadata"]["codec"] == "aac"

        # file_path is server-local and deliberately not exposed on
        # ClientTrack -- check it directly via the DB.
        db_track = client.app.state.database.get_track_by_uuid(track.uuid_id)
        assert str(db_track.file_path).endswith(".m4a")
        assert Path(db_track.file_path).exists()
