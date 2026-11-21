import contextlib
import subprocess
import time
from pathlib import Path

import pytest

from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from tests.jobs_api_fixtures import _post_job

# Registered marker (plan D16): tests/conftest.py skips without ffmpeg/ffprobe.
requires_ffmpeg = pytest.mark.requires_ffmpeg

_ALL_CODECS = frozenset({"aac", "alac", "flac", "mp3"})


@pytest.fixture
def client(app_client):
    return app_client


@pytest.fixture
def make_client(open_app_client):
    with contextlib.ExitStack() as stack:
        yield lambda encoders=None: stack.enter_context(open_app_client(encoders=encoders))


class _HeldCoordinator:
    """Stands in for the encoder pool: records submissions so jobs stay
    'queued' until a test runs them explicitly (no race with a real worker)."""

    def __init__(self):
        self.submitted = []

    def submit_conversion(self, fn, *args, **kwargs):
        self.submitted.append((fn, args, kwargs))

    def run_last(self):
        fn, args, kwargs = self.submitted[-1]
        fn(*args, **kwargs)


def _hold_worker(client, encoders=_ALL_CODECS) -> _HeldCoordinator:
    orchestrator = client.app.state.conversion_orchestrator
    held = _HeldCoordinator()
    orchestrator.encoder_coordinator = held
    if encoders is not None:
        orchestrator.available_encoders = frozenset(encoders)
    return held


@pytest.fixture
def held_client(client):
    held = _hold_worker(client)
    client.held = held
    return client


def _add_track_with_file(
    client, tmp_path: Path, codec: str = "flac", bitrate_kbps: float = 1000.0,
    filename: str = "song.flac", real_audio: bool = False,
) -> Track:
    music_dir = tmp_path / "music" / "admin"
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
    assert client.app.state.admin_library.add_track(track)
    return client.app.state.admin_library.get_track_by_uuid(track.uuid_id)


def _add_track_without_file(client, tmp_path: Path, codec: str = "flac") -> Track:
    music_dir = tmp_path / "music" / "admin"
    music_dir.mkdir(parents=True, exist_ok=True)
    file_path = music_dir / "missing.flac"  # never written
    metadata = TrackMetaData(
        codec=codec, duration=1.0, bitrate_kbps=1000.0, sample_rate_hz=44100,
        channels=2, title="T", artist="Art",
    )
    track = Track(file_path=file_path, metadata=metadata)
    assert client.app.state.admin_library.add_track(track)
    return client.app.state.admin_library.get_track_by_uuid(track.uuid_id)


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


class TestPostJobs:
    def test_post_jobs__valid_conversion__returns_queued_job(self, held_client, tmp_path):
        client = held_client
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
        assert len(client.held.submitted) == 1

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


class TestPostJobsBitrateValidation:
    @pytest.mark.parametrize("codec", ["aac", "mp3"])
    @pytest.mark.parametrize("bitrate", [7, 0, -5, 999999, None])
    def test_lossy_target__non_preset_bitrate__422(self, held_client, tmp_path, codec, bitrate):
        track = _add_track_with_file(held_client, tmp_path, codec="flac")
        r = _post_job(held_client, track.uuid_id, codec, track.revision, bitrate)
        assert r.status_code == 422, r.text
        assert held_client.held.submitted == []

    @pytest.mark.parametrize("codec", ["aac", "mp3"])
    def test_lossy_target__each_preset__accepted(self, held_client, tmp_path, codec):
        for bitrate in (320, 256, 192, 128):
            track = _add_track_with_file(
                held_client, tmp_path, codec="flac", filename=f"song-{bitrate}.flac"
            )
            r = _post_job(held_client, track.uuid_id, codec, track.revision, bitrate)
            assert r.status_code == 200, (bitrate, r.text)
            assert r.json()["target_bitrate"] == bitrate

    @pytest.mark.parametrize("codec", ["alac", "flac"])
    def test_lossless_target__bitrate_given__422(self, held_client, tmp_path, codec):
        track = _add_track_with_file(held_client, tmp_path, codec="mp3", filename="song.mp3")
        r = _post_job(held_client, track.uuid_id, codec, track.revision, 320)
        assert r.status_code == 422, r.text

    @pytest.mark.parametrize("codec", ["alac", "flac"])
    def test_lossless_target__null_bitrate__accepted(self, held_client, tmp_path, codec):
        track = _add_track_with_file(held_client, tmp_path, codec="mp3", filename="song.mp3")
        r = _post_job(held_client, track.uuid_id, codec, track.revision, None)
        assert r.status_code == 200, r.text
        assert r.json()["target_bitrate"] is None


class TestPostJobsRefusalAnswers:
    """Refactor BE-TIDY row 6, written before the catch in post_job is
    narrowed: the full answer of every request refusal POST /jobs gives today.
    None of them may become a 500. Texts typed by hand."""

    @pytest.mark.parametrize(
        "source_codec, source_bitrate, filename, target, bitrate, detail",
        [
            ("flac", 1000.0, "song.flac", "wav", None,
             "unsupported or unavailable target codec: wav"),
            ("flac", 1000.0, "song.flac", "aac", None,
             "aac requires a target bitrate of 320, 256, 192 or 128 kbps"),
            ("flac", 1000.0, "song.flac", "mp3", 999,
             "mp3 requires a target bitrate of 320, 256, 192 or 128 kbps"),
            ("mp3", 320.0, "song.mp3", "flac", 320,
             "flac is lossless and takes no target bitrate"),
            # U06-B-06: a same-codec lossy request at the same or a higher bitrate.
            ("mp3", 320.0, "song.mp3", "mp3", 320,
             "The track is already in this format. "
             "Converting it again at this bitrate cannot improve it."),
            ("aac", 190.0, "song.m4a", "aac", 192,
             "The track is already in this format. "
             "Converting it again at this bitrate cannot improve it."),
            # Upward, far above the stored bitrate (32 -> 256).
            ("mp3", 32.0, "song.mp3", "mp3", 256,
             "The track is already in this format. "
             "Converting it again at this bitrate cannot improve it."),
            ("flac", 1000.0, "song.flac", "flac", None,
             "Target codec is the same lossless codec as the source"),
        ],
        ids=["unsupported", "lossy-no-bitrate", "lossy-non-preset", "lossless-with-bitrate",
             "same-lossy-same-bitrate", "same-lossy-higher-bitrate", "same-lossy-upward",
             "same-lossless"],
    )
    def test_a_refused_request_answers_422_with_its_text(
        self, held_client, tmp_path, source_codec, source_bitrate, filename, target, bitrate,
        detail,
    ):
        track = _add_track_with_file(
            held_client, tmp_path, codec=source_codec, bitrate_kbps=source_bitrate,
            filename=filename,
        )

        r = _post_job(held_client, track.uuid_id, target, track.revision, bitrate)

        assert (r.status_code, r.json()) == (422, {"detail": detail})
        assert held_client.held.submitted == []

    def test_an_encoder_missing_on_this_server_answers_422_with_its_text(self, held_client, tmp_path):
        held_client.app.state.conversion_orchestrator.available_encoders = frozenset({"aac"})
        track = _add_track_with_file(held_client, tmp_path, codec="flac")

        r = _post_job(held_client, track.uuid_id, "mp3", track.revision, 320)

        assert (r.status_code, r.json()) == (
            422, {"detail": "unsupported or unavailable target codec: mp3"}
        )

    def test_a_file_at_the_target_path_answers_409_target_exists_taken_by_a_file(
        self, held_client, tmp_path
    ):
        track = _add_track_with_file(held_client, tmp_path, codec="flac")
        (Path(track.file_path).with_suffix(".mp3")).write_bytes(b"someone else")

        r = _post_job(held_client, track.uuid_id, "mp3", track.revision, 320)

        assert (r.status_code, r.json()) == (
            409, {"detail": {"error": "target_exists", "taken_by": "file"}}
        )

    def test_a_target_path_only_another_tracks_row_names_answers_taken_by_a_track(
        self, held_client, tmp_path
    ):
        """No file is at the path (the other track's master is missing): the
        client must not be told that a file exists there."""
        track = _add_track_with_file(held_client, tmp_path, codec="flac")
        other = _add_track_with_file(held_client, tmp_path, codec="mp3", filename="song.mp3")
        Path(other.file_path).unlink()

        r = _post_job(held_client, track.uuid_id, "mp3", track.revision, 320)

        assert (r.status_code, r.json()) == (
            409, {"detail": {"error": "target_exists", "taken_by": "track"}}
        )
        assert held_client.held.submitted == []

    def test_a_file_at_a_target_path_another_tracks_row_names_answers_taken_by_a_file(
        self, held_client, tmp_path
    ):
        track = _add_track_with_file(held_client, tmp_path, codec="flac")
        _add_track_with_file(held_client, tmp_path, codec="mp3", filename="song.mp3")

        r = _post_job(held_client, track.uuid_id, "mp3", track.revision, 320)

        assert (r.status_code, r.json()) == (
            409, {"detail": {"error": "target_exists", "taken_by": "file"}}
        )

    def test_a_kept_journal_row_answers_409_pending_recovery_before_the_request_checks(
        self, held_client, tmp_path
    ):
        # The kept-row check runs before _validate_request: even an invalid
        # request (same lossless codec) is answered pending_recovery.
        track = _add_track_with_file(held_client, tmp_path, codec="flac")
        held_client.app.state.admin_library.insert_journal_entry(
            "convert", track.uuid_id, old_path=str(track.file_path),
            temp_path=str(tmp_path / "pending.tagged.flac"),
        )

        r = _post_job(held_client, track.uuid_id, "flac", track.revision)

        assert (r.status_code, r.json()) == (409, {"detail": {"error": "pending_recovery"}})


class TestPostJobsInternalError:
    def test_an_unrelated_value_error_under_enqueue_answers_500_without_its_text(
        self, held_client, tmp_path, monkeypatch
    ):
        """Refactor BE-TIDY row 6 (U06-A-06): only a refused request answers
        422; an internal ValueError is a server error, and its text (which may
        name a path) is never sent."""
        from fastapi.testclient import TestClient

        track = _add_track_with_file(held_client, tmp_path, codec="flac")

        def broken_check(**kwargs):
            raise ValueError("internal detail /srv/music/admin/song.flac")

        monkeypatch.setattr(
            held_client.app.state.conversion_orchestrator.storage_ledger, "check", broken_check
        )
        quiet = TestClient(
            held_client.app, raise_server_exceptions=False, headers=held_client.headers
        )

        r = _post_job(quiet, track.uuid_id, "aac", track.revision, 192)

        assert r.status_code == 500
        assert "internal detail" not in r.text and "/srv/music" not in r.text
        assert held_client.held.submitted == []


class TestPostJobsConflicts:
    def test_post_jobs__job_already_active__409_job_active(self, held_client, tmp_path):
        client = held_client
        track = _add_track_with_file(client, tmp_path, codec="flac")
        first = _post_job(client, track.uuid_id, "aac", track.revision, 192)
        assert first.status_code == 200, first.text
        first_id = first.json()["job_id"]

        r = _post_job(client, track.uuid_id, "mp3", track.revision, 320)
        assert r.status_code == 409, r.text
        assert r.json() == {"detail": {"error": "job_active", "job_id": first_id}}

        # Also while it's running.
        client.app.state.admin_library.mark_conversion_job_running(first_id)
        r = _post_job(client, track.uuid_id, "mp3", track.revision, 320)
        assert r.status_code == 409, r.text
        assert r.json()["detail"]["job_id"] == first_id
        assert len(client.held.submitted) == 1

    def test_post_jobs__journal_row_outstanding__409_pending_recovery(self, held_client, tmp_path):
        client = held_client
        track = _add_track_with_file(client, tmp_path, codec="flac")
        client.app.state.admin_library.insert_journal_entry(
            "convert", track.uuid_id, old_path=str(track.file_path),
            temp_path=str(tmp_path / "pending.tagged.flac"),
        )

        r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

        assert r.status_code == 409, r.text
        assert r.json() == {"detail": {"error": "pending_recovery"}}
        assert client.held.submitted == []

    def test_a_conversion_whose_swap_waits_for_the_next_start_answers_with_the_jobs_own_sentence(
        self, held_client, tmp_path
    ):
        """The failed job reads "The conversion could not be finished. The
        server checks this track at its next start." and keeps its journal row,
        which only the next start settles. A Retry before that start is refused
        with the same sentence, not with one that says a later try helps."""
        from app.services.conversion import SWAP_PENDING_ERROR

        client = held_client
        library = client.app.state.admin_library
        track = _add_track_with_file(client, tmp_path, codec="flac")
        job_id = library.insert_conversion_job(
            track.uuid_id, "flac", "flac", None, base_revision=track.revision
        )
        assert library.mark_conversion_job_failed(job_id, SWAP_PENDING_ERROR)
        staging = client.app.state.conversion_orchestrator.staging_dir
        staging.mkdir(parents=True, exist_ok=True)
        staged = staging / f"{track.uuid_id}.{job_id}.tagged.flac"
        staged.write_bytes(b"converted-bytes")
        library.insert_journal_entry(
            "convert", track.uuid_id, old_path=str(track.file_path), temp_path=str(staged),
        )

        r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

        assert (r.status_code, r.json()) == (
            409, {"detail": {"error": "pending_recovery", "message": SWAP_PENDING_ERROR}}
        )
        assert client.held.submitted == []
        assert [e["uuid_id"] for e in library.list_journal_entries()] == [track.uuid_id]

    def test_another_tracks_swap_that_waits_for_the_next_start_does_not_change_this_answer(
        self, held_client, tmp_path
    ):
        """Only this track's own kept rows decide the sentence: a track whose
        kept row is of another kind answers 409 without it, even while another
        track waits for the next start."""
        from app.services.conversion import SWAP_PENDING_ERROR

        client = held_client
        library = client.app.state.admin_library
        waiting = _add_track_with_file(client, tmp_path, codec="flac", filename="waiting.flac")
        job_id = library.insert_conversion_job(
            waiting.uuid_id, "flac", "flac", None, base_revision=waiting.revision
        )
        assert library.mark_conversion_job_failed(job_id, SWAP_PENDING_ERROR)
        staging = client.app.state.conversion_orchestrator.staging_dir
        staging.mkdir(parents=True, exist_ok=True)
        staged = staging / f"{waiting.uuid_id}.{job_id}.tagged.flac"
        staged.write_bytes(b"converted-bytes")
        library.insert_journal_entry(
            "convert", waiting.uuid_id, old_path=str(waiting.file_path), temp_path=str(staged),
        )
        track = _add_track_with_file(client, tmp_path, codec="flac")
        library.insert_journal_entry(
            "convert", track.uuid_id, old_path=str(track.file_path),
            temp_path=str(tmp_path / "pending.tagged.flac"),
        )

        r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

        assert (r.status_code, r.json()) == (409, {"detail": {"error": "pending_recovery"}})

    def test_post_jobs__after_active_job_cancelled__allowed(self, held_client, tmp_path):
        client = held_client
        track = _add_track_with_file(client, tmp_path, codec="flac")
        first_id = _post_job(client, track.uuid_id, "aac", track.revision, 192).json()["job_id"]
        assert client.delete(f"/jobs/{first_id}").json()["cancelled"] is True

        r = _post_job(client, track.uuid_id, "mp3", track.revision, 320)
        assert r.status_code == 200, r.text
        assert r.json()["job_id"] != first_id

    @requires_ffmpeg
    def test_post_jobs__after_first_finishes__new_post_needs_new_revision(
        self, held_client, tmp_path
    ):
        client = held_client
        track = _add_track_with_file(client, tmp_path, codec="flac", real_audio=True)
        first_id = _post_job(client, track.uuid_id, "aac", track.revision, 192).json()["job_id"]
        assert _post_job(client, track.uuid_id, "aac", track.revision, 192).status_code == 409

        client.held.run_last()
        db = client.app.state.database
        assert client.app.state.admin_library.get_conversion_job(first_id)["status"] == "done"
        converted = client.app.state.admin_library.get_track_by_uuid(track.uuid_id)
        assert converted.revision > track.revision

        stale = _post_job(client, track.uuid_id, "mp3", track.revision, 320)
        assert stale.status_code == 409, stale.text
        assert stale.json()["detail"] == {
            "error": "revision_conflict", "current_revision": converted.revision,
        }

        r = _post_job(client, track.uuid_id, "mp3", converted.revision, 320)
        assert r.status_code == 200, r.text

    def test_post_jobs__target_path_taken__409_target_exists_nothing_queued(
        self, held_client, tmp_path
    ):
        client = held_client
        track = _add_track_with_file(client, tmp_path, codec="mp3", filename="Song.mp3")
        squatter = tmp_path / "music" / "admin" / "Song.m4a"
        squatter.write_bytes(b"another track")

        r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

        assert r.status_code == 409, r.text
        assert r.json() == {"detail": {"error": "target_exists", "taken_by": "file"}}
        assert client.held.submitted == []
        assert client.get("/jobs").json()["data"] == []
        assert squatter.read_bytes() == b"another track"


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
        client.app.state.admin_library.insert_conversion_job(track_a.uuid_id, "aac", "m4a", 192)
        client.app.state.admin_library.insert_conversion_job(track_b.uuid_id, "mp3", "mp3", 320)

        r = client.get("/jobs", params={"uuid_id": track_a.uuid_id})
        assert r.status_code == 200, r.text
        data = r.json()["data"]
        assert len(data) == 1
        assert data[0]["uuid_id"] == track_a.uuid_id

        r = client.get("/jobs", params={"status": "queued"})
        assert len(r.json()["data"]) == 2

        r = client.get("/jobs", params={"status": "done"})
        assert len(r.json()["data"]) == 0

    def test_get_jobs__comma_separated_statuses__returns_each(self, client, tmp_path):
        db = client.app.state.database
        tracks = [_add_track_with_file(client, tmp_path, filename=f"{n}.flac") for n in "abc"]
        queued = client.app.state.admin_library.insert_conversion_job(tracks[0].uuid_id, "aac", "m4a", 192)
        running = client.app.state.admin_library.insert_conversion_job(tracks[1].uuid_id, "aac", "m4a", 192)
        cancelled = client.app.state.admin_library.insert_conversion_job(tracks[2].uuid_id, "aac", "m4a", 192)
        client.app.state.admin_library.mark_conversion_job_running(running)
        client.app.state.admin_library.mark_conversion_job_cancelled(cancelled)

        r = client.get("/jobs", params={"status": "queued,running"})
        assert r.status_code == 200, r.text
        assert [j["job_id"] for j in r.json()["data"]] == [queued, running]

        r = client.get("/jobs", params={"status": " running , cancelled "})
        assert [j["job_id"] for j in r.json()["data"]] == [running, cancelled]

    @pytest.mark.parametrize("status", ["bogus", "queued,bogus", ",", ""])
    def test_get_jobs__unknown_status__422(self, client, status):
        r = client.get("/jobs", params={"status": status})
        assert r.status_code == 422, r.text

    def test_get_jobs__unsupported_type__422(self, client):
        assert client.get("/jobs", params={"type": "upload"}).status_code == 422
        assert client.get("/jobs", params={"type": "conversion"}).status_code == 200

    @pytest.mark.parametrize("limit", [0, 201, -1])
    def test_get_jobs__limit_out_of_range__422(self, client, limit):
        r = client.get("/jobs", params={"limit": limit})
        assert r.status_code == 422, r.text

    def test_get_jobs__pagination__cursor_advances(self, client, tmp_path):
        db = client.app.state.database
        job_ids = []
        for n in range(5):
            track = _add_track_with_file(client, tmp_path, filename=f"{n}.flac")
            job_ids.append(client.app.state.admin_library.insert_conversion_job(track.uuid_id, "aac", "m4a", 192))

        r = client.get("/jobs", params={"limit": 2})
        body = r.json()
        assert [j["job_id"] for j in body["data"]] == job_ids[0:2]
        assert body["nextCursor"] is not None

        r2 = client.get("/jobs", params={"limit": 2, "cursor": body["nextCursor"]})
        body2 = r2.json()
        assert [j["job_id"] for j in body2["data"]] == job_ids[2:4]

    def test_get_jobs__full_cursor_traversal__every_job_exactly_once(self, client, tmp_path):
        db = client.app.state.database
        track = _add_track_with_file(client, tmp_path)
        job_ids = []
        for _ in range(7):
            job_id = client.app.state.admin_library.insert_conversion_job(track.uuid_id, "aac", "m4a", 192)
            client.app.state.admin_library.mark_conversion_job_cancelled(job_id)  # frees the uuid for the next one
            job_ids.append(job_id)

        seen, cursor, pages = [], 0, 0
        while True:
            body = client.get("/jobs", params={"limit": 3, "cursor": cursor}).json()
            seen.extend(j["job_id"] for j in body["data"])
            pages += 1
            if body["nextCursor"] is None:
                break
            cursor = body["nextCursor"]
            assert pages < 10, "cursor never terminated"

        assert seen == job_ids
        assert pages == 3

    def test_get_jobs__no_jobs__empty_data_null_cursor(self, client):
        r = client.get("/jobs")
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["data"] == []
        assert body["nextCursor"] is None


class TestDeleteJobs:
    # Jobs are inserted via the DB, not POSTed: a POST would hand the job to
    # the real worker pool, which could fail it (fake bytes) before the DELETE.

    def test_delete_jobs__queued_job__cancelled_true(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        job_id = client.app.state.admin_library.insert_conversion_job(
            track.uuid_id, "aac", "m4a", 192, base_revision=track.revision,
        )

        r = client.delete(f"/jobs/{job_id}")
        assert r.status_code == 200, r.text
        assert r.json()["cancelled"] is True

        r2 = client.get("/jobs", params={"uuid_id": track.uuid_id})
        assert r2.json()["data"][0]["status"] == "cancelled"

    def test_delete_jobs__running_job__cancelled_true(self, client, tmp_path):
        db = client.app.state.database
        track = _add_track_with_file(client, tmp_path)
        job_id = client.app.state.admin_library.insert_conversion_job(track.uuid_id, "aac", "m4a", 192)
        client.app.state.admin_library.mark_conversion_job_running(job_id)

        r = client.delete(f"/jobs/{job_id}")
        assert r.json()["cancelled"] is True
        assert client.app.state.admin_library.get_conversion_job(job_id)["status"] == "cancelled"

    def test_delete_jobs__already_cancelled__idempotent_false(self, client, tmp_path):
        track = _add_track_with_file(client, tmp_path)
        job_id = client.app.state.admin_library.insert_conversion_job(
            track.uuid_id, "aac", "m4a", 192, base_revision=track.revision,
        )
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
        client.app.state.available_encoders = _ALL_CODECS
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
        client.app.state.available_encoders = _ALL_CODECS
        r = client.get("/app/info")
        body = r.json()
        assert "convert" in body["entities"]["track"]["actions"]

    def test_app_info__only_aac_available__advertised_equals_accepted(
        self, make_client, tmp_path
    ):
        client = make_client(encoders={"aac"})
        body = client.get("/app/info").json()
        assert [t["codec"] for t in body["conversion"]["targets"]] == ["aac"]
        assert body["entities"]["track"]["actions"] == ["convert"]

        _hold_worker(client, encoders=None)  # keep the probed set
        track = _add_track_with_file(client, tmp_path, codec="flac")
        assert _post_job(client, track.uuid_id, "mp3", track.revision, 320).status_code == 422
        assert _post_job(client, track.uuid_id, "alac", track.revision).status_code == 422
        assert _post_job(client, track.uuid_id, "aac", track.revision, 320).status_code == 200

    def test_app_info__no_encoders__no_convert_action(self, make_client, tmp_path):
        client = make_client(encoders=frozenset())
        body = client.get("/app/info").json()
        assert body["conversion"]["targets"] == []
        assert body["entities"]["track"]["actions"] == []

        _hold_worker(client, encoders=None)
        track = _add_track_with_file(client, tmp_path, codec="flac")
        assert _post_job(client, track.uuid_id, "aac", track.revision, 192).status_code == 422


@requires_ffmpeg
class TestStartupRecovery:
    def test_restart__fails_running_resumes_queued_sweeps_temps_evicts(
        self, tmp_path, monkeypatch, open_app_client
    ):
        evicted = []
        with contextlib.ExitStack() as stack:
            client = stack.enter_context(open_app_client())
            _hold_worker(client)  # nothing runs before the "crash"
            db = client.app.state.database
            queued_track = _add_track_with_file(
                client, tmp_path, codec="flac", filename="q.flac", real_audio=True
            )
            running_track = _add_track_with_file(client, tmp_path, filename="r.flac")
            queued = _post_job(client, queued_track.uuid_id, "aac", queued_track.revision, 192)
            queued_id = queued.json()["job_id"]
            running_id = client.app.state.admin_library.insert_conversion_job(running_track.uuid_id, "aac", "m4a", 192)
            client.app.state.admin_library.mark_conversion_job_running(running_id)
            staging = tmp_path / "music" / ".staging"
            orphan = staging / f"{running_track.uuid_id}.tagged.m4a"
            orphan.write_bytes(b"left by the crash")
            # An unfinished same-path convert whose temp is already gone.
            client.app.state.admin_library.insert_journal_entry(
                "convert", running_track.uuid_id,
                old_path=str(running_track.file_path),
                temp_path=str(staging / f"{running_track.uuid_id}.tagged.flac"),
            )
            # Shutting the TestClient down here stands in for the crash.

        # main imports the helper from encoded_cache when the app (re)loads.
        import app.services.encoded_cache as encoded_cache_module
        real_evict = encoded_cache_module.evict_track_caches

        def recording_evict(uuid_id, cache, default_cache):
            evicted.append(uuid_id)
            return real_evict(uuid_id, cache, default_cache)

        monkeypatch.setattr(encoded_cache_module, "evict_track_caches", recording_evict)

        with contextlib.ExitStack() as stack:
            client = stack.enter_context(open_app_client())
            db = client.app.state.database

            running = client.app.state.admin_library.get_conversion_job(running_id)
            assert running["status"] == "failed"
            assert running["error_text"] == "interrupted by restart"
            assert not orphan.exists()
            assert client.app.state.admin_library.list_journal_entries() == []
            assert running_track.uuid_id in evicted

            job = None
            for _ in range(100):  # the resumed job runs on the real pool
                job = client.app.state.admin_library.get_conversion_job(queued_id)
                if job["status"] in ("done", "failed", "cancelled"):
                    break
                time.sleep(0.05)
            assert job["status"] == "done", job
            assert client.app.state.admin_library.get_track_by_uuid(queued_track.uuid_id).metadata.codec == "aac"


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
        db_track = client.app.state.admin_library.get_track_by_uuid(track.uuid_id)
        assert str(db_track.file_path).endswith(".m4a")
        assert Path(db_track.file_path).exists()
