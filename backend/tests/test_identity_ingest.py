"""Phase 6.5A.2b: the ingest identity writer (spec §6.2 first row; plan D6, D12, D14).

The organizer computes the exact layer synchronously on the source, after the
"changed since read" re-check and before the move, and carries it on the
``Track`` into ``add_track``. A compute failure of any kind never changes the
import outcome (DEV-M-10: an environmental outcome would keep an archive and
re-import it on every start).
"""

import shutil
import sqlite3
import subprocess
import threading
from pathlib import Path
from unittest.mock import patch

import pytest

import app.services.audio_identity as audio_identity
import app.services.organizer as organizer
from app.database import DatabaseContext
from app.database.database import Database
from app.models.track_meta_data import TrackMetaData
from app.services.audio_identity import KIND_PCM, AudioIdentity, ExactAudioHash, ExactUnavailable, compute_exact
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.ffmpeg_runner import CaptureTimeout, FfmpegError, FfmpegProcessRegistry
from app.services.import_outcome import ImportOutcome
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL

IDENTITY = AudioIdentity(
    exact=ExactAudioHash(KIND_PCM, "cd" * 32, 44100, 2, 16),
    tool_versions="ffmpeg 9.0.2", computed_at=1,
)


class Recorder:
    def __init__(self, result=IDENTITY, error=None):
        self.result, self.error, self.calls = result, error, []

    def __call__(self, path, codec_hint):
        self.calls.append({"path": Path(path), "codec": codec_hint, "at_source": Path(path).is_file()})
        if self.error is not None:
            raise self.error
        return self.result


def _organizer(tmp_path, *, compute=None, should_stop=None, added=None):
    added = added if added is not None else []
    kwargs = {}
    if compute is not None:
        kwargs["compute_identity"] = compute
    if should_stop is not None:
        kwargs["should_stop"] = should_stop
    ctx = organizer.OrganizerContext(
        music_library_dir=tmp_path / "music",
        should_organize_files=True,
        should_copy_files=False,
        add_to_database=lambda t: added.append(t) or True,
        **kwargs,
    )
    return organizer.Organizer(ctx), added


def _source(tmp_path, name="song.flac"):
    source = tmp_path / "import" / name
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"audio")
    return source


def _organize(org, source, *, signatures=None):
    meta = TrackMetaData(title="Lucky", artist="Radiohead", codec="flac", duration=1.0)
    with (
        patch("app.services.organizer.get_track_metadata", return_value=meta),
        patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
    ):
        if signatures is None:
            return org.organize(source)
        with patch("app.services.organizer.file_signature", side_effect=signatures):
            return org.organize(source)


def test_the_exact_layer_is_computed_on_the_source_and_carried_into_the_insert(tmp_path):
    compute = Recorder()
    org, added = _organizer(tmp_path, compute=compute)
    source = _source(tmp_path)

    assert _organize(org, source) is ImportOutcome.IMPORTED

    assert compute.calls == [{"path": source, "codec": "flac", "at_source": True}]
    [track] = added
    assert track.audio_identity == IDENTITY
    assert track.file_path == tmp_path / "music" / "Radiohead" / "song.flac"


def test_a_file_that_changed_since_it_was_read_is_never_hashed(tmp_path):
    compute = Recorder()
    org, added = _organizer(tmp_path, compute=compute)

    outcome = _organize(org, _source(tmp_path), signatures=[(5, 1), (6, 2)])

    assert outcome is ImportOutcome.CHANGED
    assert compute.calls == [] and added == []


@pytest.mark.parametrize("error", [RuntimeError("boom"), OSError("gone"), MemoryError()])
def test_a_compute_exception_still_imports_with_no_identity(tmp_path, error):
    org, added = _organizer(tmp_path, compute=Recorder(error=error))

    assert _organize(org, _source(tmp_path)) is ImportOutcome.IMPORTED
    [track] = added
    assert track.audio_identity is None


@pytest.mark.parametrize("reason", ["tool_missing", "timeout", "killed", "decode_error"])
def test_a_failed_hash_still_imports(tmp_path, reason):
    failed = AudioIdentity(exact=ExactUnavailable("failed", reason), tool_versions=None, computed_at=1)
    org, added = _organizer(tmp_path, compute=Recorder(result=failed))

    assert _organize(org, _source(tmp_path)) is ImportOutcome.IMPORTED
    [track] = added
    assert track.audio_identity == failed


def test_the_hash_is_skipped_once_stopping(tmp_path):
    """Plan D14: shutdown never waits on an ingest hash; the layer stays pending."""
    compute = Recorder()
    org, added = _organizer(tmp_path, compute=compute, should_stop=lambda: True)

    assert _organize(org, _source(tmp_path)) is ImportOutcome.IMPORTED
    assert compute.calls == []
    [track] = added
    assert track.audio_identity is None


def test_without_a_compute_function_nothing_is_hashed(tmp_path):
    org, added = _organizer(tmp_path)

    assert _organize(org, _source(tmp_path)) is ImportOutcome.IMPORTED
    [track] = added
    assert track.audio_identity is None


# --- make_pipeline: the real hash, the fingerprinter flag, the post-commit signal ---



class SpyWakeup:
    """Records, at each notify, whether the identity row is visible to a
    fresh connection (i.e. committed)."""

    def __init__(self, db_path):
        self.db_path, self.seen = db_path, []

    def notify(self):
        conn = sqlite3.connect(self.db_path)
        try:
            self.seen.append(conn.execute("SELECT count(*) FROM track_audio_identity").fetchone()[0])
        finally:
            conn.close()


@pytest.fixture
def env(tmp_path):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    return db, manager, tmp_path


def _pipeline(env, **kwargs):
    db, manager, tmp = env
    organizer_, _ = make_pipeline(
        db.get_user(db.owner_id), database=db, cover_art_manager=manager,
        music_library_dir=tmp / "music", workspace_root=tmp / "data" / "workspace", **kwargs,
    )
    return organizer_


def _flac(path, title="Lucky"):
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
         "-metadata", f"title={title}", "-metadata", "artist=Radiohead", "-c:a", "flac", str(path)],
        check=True,
    )
    return path


def _row(db):
    conn = sqlite3.connect(db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute("SELECT * FROM track_audio_identity")]
    finally:
        conn.close()


@pytest.mark.requires_ffmpeg
def test_an_ingest_writes_the_exact_layer_current_with_the_track(env):
    db, _, tmp = env
    source = _flac(tmp / "import" / "lucky.flac")
    reference = tmp / "reference.flac"
    shutil.copy(source, reference)
    expected = compute_exact(reference, "flac")

    assert _pipeline(env).organize(source) is ImportOutcome.IMPORTED

    [track] = db.get_tracks()
    [row] = _row(db)
    assert row["uuid_id"] == track.uuid_id
    assert (row["exact_state"], row["exact_kind"], row["exact_digest"]) \
        == ("current", "pcm_sha256", expected.digest)
    assert (row["fp_state"], row["match_state"], row["priority"]) == ("unavailable", "pending", 0)


@pytest.mark.requires_ffmpeg
def test_a_present_fingerprinter_leaves_the_fingerprint_pending(env):
    db, _, tmp = env
    source = _flac(tmp / "import" / "lucky.flac")

    assert _pipeline(env, fingerprinter_present=True).organize(source) is ImportOutcome.IMPORTED

    [row] = _row(db)
    assert row["fp_state"] == "pending"


@pytest.mark.requires_ffmpeg
@pytest.mark.parametrize("failure", [FfmpegError("ffmpeg not found"), CaptureTimeout("slow")])
def test_ffmpeg_missing_or_timing_out_still_imports_with_the_exact_layer_pending(env, failure):
    """Plan D12 (binding): never TOOL_UNAVAILABLE for an identity failure."""
    db, _, tmp = env
    source = _flac(tmp / "import" / "lucky.flac")

    with patch("app.services.audio_identity.run_capture", side_effect=failure):
        assert _pipeline(env).organize(source) is ImportOutcome.IMPORTED

    [track] = db.get_tracks()
    assert track.file_path.is_file()
    [row] = _row(db)
    assert (row["exact_state"], row["exact_digest"], row["failure_reason"]) == ("pending", None, None)


@pytest.mark.requires_ffmpeg
def test_the_ingest_hash_runs_under_the_pipelines_registry(env):
    """Plan D14: shutdown can kill a running ingest hash through the registry."""
    db, _, tmp = env
    source = _flac(tmp / "import" / "lucky.flac")
    registry = FfmpegProcessRegistry()
    seen = []
    real = audio_identity.run_capture

    def spy(cmd, **kwargs):
        seen.append((kwargs.get("registry"), kwargs.get("job_id")))
        return real(cmd, **kwargs)

    with patch("app.services.audio_identity.run_capture", side_effect=spy):
        assert _pipeline(env, identity_registry=registry).organize(source) is ImportOutcome.IMPORTED

    assert seen and all(r is registry and job is not None for r, job in seen)
    assert _row(db)[0]["exact_state"] == "current"


def test_the_hash_is_skipped_when_the_pipeline_is_stopping(env):
    db, _, tmp = env
    stop = threading.Event()
    stop.set()
    source = _source(tmp)

    with patch("app.services.audio_identity.compute_exact") as compute:
        assert _organize(_pipeline(env, stop_event=stop), source) is ImportOutcome.IMPORTED

    compute.assert_not_called()
    assert _row(db)[0]["exact_state"] == "pending"


def test_the_signal_fires_once_after_the_commit(env):
    db, _, tmp = env
    wakeup = SpyWakeup(db.context.database_path)

    assert _organize(_pipeline(env, identity_signal=wakeup), _source(tmp)) is ImportOutcome.IMPORTED

    assert wakeup.seen == [1]


def test_a_failing_commit_never_signals(env, monkeypatch):
    db, _, tmp = env
    wakeup = SpyWakeup(db.context.database_path)

    def crash(conn, uuid_id, identity, *, fingerprinter_present):
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(Database, "_insert_audio_identity_in", staticmethod(crash))
    outcome = _organize(_pipeline(env, identity_signal=wakeup), _source(tmp))

    assert outcome is ImportOutcome.DATABASE_ERROR
    assert wakeup.seen == []
    assert db.get_tracks() == [] and _row(db) == []
