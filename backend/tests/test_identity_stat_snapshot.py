"""Writers store the master's stat snapshot with the identity they write (spec §6.1, §6.4).

The ``stat_*`` columns let a later "Re-scan identities" spot changed files
without decoding. An ingest stores the stat of the master after the move, and
a conversion the stat of the new master after the move or replace, in the same
transaction as the identity. Unknown stays NULL, never 0: no computed identity
or no file means no snapshot. Expected values come from ``os.stat``.
"""

import os
from pathlib import Path

import pytest

import tests.test_conversion as conv
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.import_outcome import ImportOutcome
from tests.test_identity_conversion import _conversion_world
from tests.test_identity_ingest import _flac, _pipeline, _row, env  # noqa: F401  (env is a fixture)
from tests.test_identity_writers import _current, _identity, db  # noqa: F401  (db is a fixture)

STAT = ("stat_size", "stat_mtime_ns", "stat_inode")


def _snapshot(row):
    return tuple(row[k] for k in STAT)


def _expected(path):
    st = os.stat(path)
    return (st.st_size, st.st_mtime_ns, st.st_ino)


@pytest.mark.requires_ffmpeg
def test_an_ingest_stores_the_moved_masters_stat(env):
    db, _, tmp = env
    source = _flac(tmp / "import" / "lucky.flac")

    assert _pipeline(env).organize(source) is ImportOutcome.IMPORTED

    [track] = db.get_tracks()
    [row] = _row(db)
    assert row["exact_state"] == "current"
    assert _snapshot(row) == _expected(track.file_path)


def test_add_track_stores_the_stat_of_the_file_it_inserts(db, tmp_path):
    master = tmp_path / "m" / "a.flac"
    master.parent.mkdir()
    master.write_bytes(b"audio")
    track = Track(file_path=master, metadata=TrackMetaData(title="A", codec="flac"))
    track.audio_identity = _current()

    assert db.add_track(track)

    assert _snapshot(_identity(db, track.uuid_id)) == _expected(master)


def test_no_computed_identity_means_no_snapshot(db, tmp_path):
    master = tmp_path / "a.flac"
    master.write_bytes(b"audio")
    track = Track(file_path=master, metadata=TrackMetaData(title="A", codec="flac"))

    assert db.add_track(track)

    assert _snapshot(_identity(db, track.uuid_id)) == (None, None, None)


def test_a_missing_file_leaves_the_snapshot_unknown_not_zero(db, tmp_path):
    track = Track(file_path=tmp_path / "gone.flac", metadata=TrackMetaData(title="A", codec="flac"))
    track.audio_identity = _current()

    assert db.add_track(track)

    assert _snapshot(_identity(db, track.uuid_id)) == (None, None, None)


@pytest.mark.requires_ffmpeg
def test_a_relocating_conversion_stores_the_new_masters_stat(tmp_path):
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "flac", "aac", 256)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    master = Path(db.get_track_by_uuid(track.uuid_id).file_path)
    assert master != source
    assert _snapshot(_identity(db, track.uuid_id)) == _expected(master)


@pytest.mark.requires_ffmpeg
def test_an_in_place_conversion_stores_the_replaced_masters_stat(tmp_path):
    db, orch, coordinator, track, source, before, wakeup, job_id = _conversion_world(
        tmp_path, "mp3", "mp3", 128)

    conv._run_submitted(coordinator)

    assert db.get_conversion_job(job_id)["status"] == "done"
    assert _snapshot(_identity(db, track.uuid_id)) == _expected(source)
