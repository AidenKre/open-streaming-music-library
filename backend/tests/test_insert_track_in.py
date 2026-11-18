"""7A.3a S1 (SC-16a; spec §6 step 5 "a narrow extracted transaction-aware
insertion helper `_insert_track_in(conn, ...)`"; plan D9: "`stat` is required
and taken before the transaction by every caller ... otherwise uploads store
NULL `stat_*` (6.5 review 6-5-R2-06). `add_track` becomes the wrapper with the
same bool contract").

The helper runs on the caller's connection: it never opens, commits or closes
one, raises instead of swallowing, and stores exactly the ``stat`` it is given.
``add_track`` keeps its contract and takes the stat before it opens its write
transaction. Rows are read back with plain SQL."""

import inspect
import os
import sqlite3

import pytest

from app.database.database import Database
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services import audio_identity
from app.services.audio_identity import AudioIdentity, ExactAudioHash, FingerprintIdentity
from tests.identity_worker_fixtures import sql

DIGEST = "ab" * 32
STAT = (4321, 1_700_000_000_123_456_789, 98765)


def _identity():
    return AudioIdentity(
        exact=ExactAudioHash("pcm_sha256", DIGEST, 44100, 2, 16),
        tool_versions="ffmpeg 8.1", computed_at=1700,
    )


def _track(path, *, title="Airbag", identity=None):
    track = Track(
        file_path=path,
        metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac",
            duration=287.5, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
        ),
    )
    track.audio_identity = identity if identity is not None else _identity()
    return track


def _master(tmp_path, name="a.flac", content=b"audio bytes"):
    path = tmp_path / "lib" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return path


def _stat_of(db, uuid_id):
    rows = sql(db, "SELECT stat_size, stat_mtime_ns, stat_inode FROM track_audio_identity"
                   " WHERE uuid_id = ?", (uuid_id,))
    return None if not rows else tuple(rows[0].values())


def test_the_helper_stores_exactly_the_stat_it_is_given_not_the_files(db, tmp_path):
    master = _master(tmp_path)
    track = _track(master)

    with db._connection(commit=True) as conn:
        db._insert_track_in(conn, track, owner_id=db.owner_id, fingerprinter_present=False, stat=STAT)

    assert _stat_of(db, track.uuid_id) == STAT
    real = os.stat(master)
    assert STAT != (real.st_size, real.st_mtime_ns, real.st_ino)  # the file's own stat was not used


def test_the_helper_inserts_the_track_its_metadata_search_row_and_identity(db, tmp_path):
    track = _track(_master(tmp_path))

    with db._connection(commit=True) as conn:
        revision = db._insert_track_in(
            conn, track, owner_id=db.owner_id, fingerprinter_present=False, stat=STAT)

    [row] = sql(db, "SELECT owner_id, file_path, revision FROM tracks WHERE uuid_id = ?", (track.uuid_id,))
    assert row == {"owner_id": db.owner_id, "file_path": str(track.file_path), "revision": revision}
    assert revision > 0
    [meta] = sql(db, "SELECT title, codec, duration FROM trackmetadata WHERE uuid_id = ?", (track.uuid_id,))
    assert meta == {"title": "Airbag", "codec": "flac", "duration": 287.5}
    # fts_tracks is contentless: find the row by matching each column.
    [track_id] = [r["id"] for r in sql(db, "SELECT id FROM tracks WHERE uuid_id = ?", (track.uuid_id,))]
    for query in ('title:airbag', 'artist_name:radiohead', 'album_name:"ok computer"'):
        hits = sql(db, "SELECT rowid FROM fts_tracks WHERE fts_tracks MATCH ?", (query,))
        assert [h["rowid"] for h in hits] == [track_id], query
    [ident] = sql(db, "SELECT exact_state, exact_digest FROM track_audio_identity WHERE uuid_id = ?",
                  (track.uuid_id,))
    assert ident == {"exact_state": "current", "exact_digest": DIGEST}


def test_a_none_stat_is_stored_as_unknown_never_zero(db, tmp_path):
    track = _track(_master(tmp_path))

    with db._connection(commit=True) as conn:
        db._insert_track_in(conn, track, owner_id=db.owner_id, fingerprinter_present=False, stat=None)

    assert _stat_of(db, track.uuid_id) == (None, None, None)


def test_stat_is_a_required_keyword():
    params = inspect.signature(Database._insert_track_in).parameters
    for name in ("owner_id", "fingerprinter_present", "stat"):
        assert params[name].kind is inspect.Parameter.KEYWORD_ONLY, name
        assert params[name].default is inspect.Parameter.empty, name


def test_the_helper_leaves_the_transaction_to_its_caller(db, tmp_path):
    """It never commits: the caller's rollback leaves no row behind."""
    track = _track(_master(tmp_path))

    conn = sqlite3.connect(db.context.database_path)
    try:
        conn.row_factory = sqlite3.Row  # what Database._connection sets
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("BEGIN IMMEDIATE")
        db._insert_track_in(conn, track, owner_id=db.owner_id, fingerprinter_present=False, stat=STAT)
        assert conn.in_transaction
        conn.rollback()
    finally:
        conn.close()

    assert sql(db, "SELECT uuid_id FROM tracks") == []
    assert sql(db, "SELECT uuid_id FROM track_audio_identity") == []


def test_the_helper_raises_where_add_track_answers_false(db, tmp_path):
    """A malformed carried print raises out of the helper (plan D10); through
    add_track the same failure is the old ``False`` with nothing stored."""
    bad = AudioIdentity(
        exact=ExactAudioHash("pcm_sha256", DIGEST, 44100, 2, 16), tool_versions="ffmpeg 8.1",
        computed_at=1700,
        fingerprint=FingerprintIdentity("current", "fpcalc", "chromaprint-2", -1.0, (1, 2, 3)),
    )
    first = _track(_master(tmp_path, "a.flac"), identity=bad)
    with pytest.raises(ValueError):
        with db._connection(commit=True) as conn:
            db._insert_track_in(conn, first, owner_id=db.owner_id, fingerprinter_present=True, stat=STAT)
    assert sql(db, "SELECT uuid_id FROM tracks") == []

    second = _track(_master(tmp_path, "b.flac"), identity=bad)
    assert db.add_track(second, fingerprinter_present=True) is False
    assert sql(db, "SELECT uuid_id FROM tracks") == []


def test_add_track_still_stores_the_masters_stat(db, tmp_path):
    master = _master(tmp_path)
    track = _track(master)

    assert db.add_track(track) is True

    st = os.stat(master)
    assert _stat_of(db, track.uuid_id) == (st.st_size, st.st_mtime_ns, st.st_ino)


def test_add_track_takes_the_stat_before_it_holds_the_write_lock(db, tmp_path, monkeypatch):
    """D9: the stat is taken before the transaction. Proof: while it is taken,
    another connection can still start a write transaction."""
    master = _master(tmp_path)
    track = _track(master)
    real = audio_identity.stat_snapshot
    seen = []

    def probing_stat(path):
        other = sqlite3.connect(db.context.database_path, timeout=0)
        try:
            other.execute("BEGIN IMMEDIATE")
            other.rollback()
            seen.append("free")
        except sqlite3.OperationalError:
            seen.append("locked")
        finally:
            other.close()
        return real(path)

    monkeypatch.setattr(audio_identity, "stat_snapshot", probing_stat)

    assert db.add_track(track) is True
    assert seen == ["free"]
