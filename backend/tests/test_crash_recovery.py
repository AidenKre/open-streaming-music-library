"""Crash recovery across a real restart (Phase M review M-U08).

A relocate commits in the DB, the process dies before the journal row is
deleted, and the next startup's ``reconcile_journal`` must keep the committed
master. The dirs are relative (as in a real deployment), so the paths stored
in the journal and the DB are resolved against the same absolute root.

Review r1 m-R1-38: the same holds for a second user's library (its root is
``music/<their folder>``) and for a conversion's relocating commit.
"""

import subprocess
from pathlib import Path

import pytest

from app.database.database import Database
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import metadata as metadata_mod
from app.services.track_edit import WriteMode

# Registered marker (plan D16): tests/conftest.py skips without ffmpeg/ffprobe.
requires_ffmpeg = pytest.mark.requires_ffmpeg


class _Killed(BaseException):
    """The process dying: not an Exception, so no handler may swallow it."""


def _make_audio(path: Path, codec: str = "aac", **tags) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "sine=frequency=440:duration=0.3", "-c:a", codec,
    ]
    for k, v in tags.items():
        cmd += ["-metadata", f"{k}={v}"]
    cmd.append(str(path))
    subprocess.run(cmd, check=True)


ENV = {
    "MUSIC_LIBRARY_DIR": "music", "APP_DATA_DIR": "data",
    "IMPORT_DIR": "import", "USER_IMPORT_DIR": "import-users",
}


def _owner_library(client, owner, tmp_path):
    from app.library import Library
    from tests.owned_database import add_test_user

    if owner == "admin":
        return client.app.state.admin_library, "admin"
    db = client.app.state.database
    sam_id = add_test_user(db, "sam")
    return Library(db, sam_id, root=tmp_path / "music" / "sam"), "sam"


def _restarted_library(client, owner_id):
    from app.library import Library

    return Library(client.app.state.database, owner_id)


@requires_ffmpeg
@pytest.mark.parametrize("owner", ["admin", "sam"])
def test_committed_relocate_survives_a_kill_before_the_journal_delete(
    tmp_path, monkeypatch, open_app_client, owner
):
    monkeypatch.chdir(tmp_path)

    with open_app_client(env=ENV) as client:
        library, folder = _owner_library(client, owner, tmp_path)
        old = tmp_path / "music" / folder / "Old" / "song.m4a"
        new = tmp_path / "music" / folder / "New" / "song.m4a"
        _make_audio(old, title="T", artist="Old")
        track = Track(file_path=old, metadata=TrackMetaData(
            codec="aac", duration=0.3, bitrate_kbps=128.0, sample_rate_hz=44100,
            channels=2, title="T", artist="Old"))
        assert library.add_track(track)
        revision = library.get_track_by_uuid(track.uuid_id).revision

        def killed(*args, **kwargs):
            raise _Killed()

        with monkeypatch.context() as m:
            m.setattr(Database, "delete_journal_entry", killed)
            # Driven through the app's own editor (what PATCH /tracks calls):
            # a BaseException escaping an HTTP handler tears down the
            # TestClient's event-loop portal, which would hide the restart.
            with pytest.raises(_Killed):
                client.app.state.track_editor.apply_edit(
                    library, track.uuid_id, {"artist": "New"}, revision,
                    WriteMode.db_and_master,
                )

        # The relocate committed; only the journal delete never happened.
        assert len(library.list_journal_entries()) == 1
        staging = tmp_path / "music" / ".staging"
        assert not staging.exists() or [p for p in staging.iterdir() if p.is_dir()] == []
        assert Path(library.get_track_file_path(track.uuid_id)) == new

    # Restart: a fresh app on the same (relative) dirs runs reconcile_journal.
    with open_app_client(env=ENV) as client:
        library = _restarted_library(client, library.owner_id)
        assert library.get_track_file_path(track.uuid_id) == str(new)
        assert new.is_file()
        assert metadata_mod.get_track_metadata(new).artist == "New"
        assert not old.exists()
        assert not old.parent.exists()
        assert library.list_journal_entries() == []


@requires_ffmpeg
def test_a_second_users_committed_conversion_survives_a_kill_before_the_journal_delete(
    tmp_path, monkeypatch, open_app_client
):
    monkeypatch.chdir(tmp_path)

    with open_app_client(env=ENV) as client:
        library, folder = _owner_library(client, "sam", tmp_path)
        source = tmp_path / "music" / folder / "Art" / "song.flac"
        dest = source.with_suffix(".m4a")
        _make_audio(source, codec="flac", title="T", artist="Art")
        track = Track(file_path=source, metadata=TrackMetaData(
            codec="flac", duration=0.3, bitrate_kbps=900.0, sample_rate_hz=44100,
            channels=2, title="T", artist="Art"))
        assert library.add_track(track)
        revision = library.get_track_by_uuid(track.uuid_id).revision
        orchestrator = client.app.state.conversion_orchestrator
        submitted = []
        monkeypatch.setattr(
            orchestrator.encoder_coordinator, "submit_conversion",
            lambda fn, *args: submitted.append(args),
        )
        job_id = orchestrator.enqueue(library, track.uuid_id, "aac", 192, revision)
        assert submitted == [(job_id,)]

        def killed(*args, **kwargs):
            raise _Killed()

        with monkeypatch.context() as m:
            m.setattr(Database, "delete_journal_entry", killed)
            with pytest.raises(_Killed):
                orchestrator._run_job(job_id)

        (entry,) = library.list_journal_entries()
        assert Path(library.get_track_file_path(track.uuid_id)) == dest
        # M-U15: .staging stays flat for every owner (no per-owner subdirs).
        staging = tmp_path / "music" / ".staging"
        assert Path(entry["temp_path"]).parent == staging
        assert [p for p in staging.iterdir() if p.is_dir()] == []

    with open_app_client(env=ENV) as client:
        library = _restarted_library(client, library.owner_id)
        assert library.get_track_file_path(track.uuid_id) == str(dest)
        assert dest.is_file()
        assert library.get_track_by_uuid(track.uuid_id).metadata.codec == "aac"
        assert not source.exists()
        assert library.list_journal_entries() == []
        assert [p for p in (tmp_path / "music" / ".staging").iterdir()] == []
