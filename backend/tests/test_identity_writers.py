"""Phase 6.5A.2b: the audio identity writers (spec §6.2, SC-25 writers, SC-16a).

The post-commit wake-up signal, the two transaction primitives
``_insert_audio_identity_in`` / ``_mark_audio_identity_stale_in`` and the
``add_track`` insertion path. Rows are read back with plain SQL.
"""

import contextlib
import sqlite3
import threading
import uuid
from pathlib import Path

import pytest

from app.database import DatabaseContext
from app.database.database import Database
from app.library import Library
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.audio_identity import (
    KIND_PCM,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
)
from app.services.identity_wakeup import IdentityWakeup
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL

DIGEST = "ab" * 32


@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def _sql(db, query, params=()):
    conn = sqlite3.connect(db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        rows = [dict(r) for r in conn.execute(query, params)]
        conn.commit()
        return rows
    finally:
        conn.close()


def _bare_track(db, owner_id=None) -> str:
    """A tracks row with no identity row (plain SQL, no writer involved)."""
    uuid_id = str(uuid.uuid4())
    _sql(db, "INSERT INTO tracks (uuid_id, file_path, owner_id) VALUES (?, ?, ?)",
         (uuid_id, f"/m/{uuid_id}.flac", owner_id or db.owner_id))
    return uuid_id


def _identity(db, uuid_id):
    rows = _sql(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,))
    return rows[0] if rows else None


def _current(tool="ffmpeg 9.0.2", computed_at=1_700_000_000):
    return AudioIdentity(
        exact=ExactAudioHash(KIND_PCM, DIGEST, 44100, 2, 24),
        tool_versions=tool, computed_at=computed_at,
    )


def _insert(db, uuid_id, identity, *, fingerprinter_present=False, commit=True):
    with db._connection(commit=commit) as conn:
        Database._insert_audio_identity_in(
            conn, uuid_id, identity, fingerprinter_present=fingerprinter_present
        )


# --- the wake-up signal ---------------------------------------------------------------


def test_a_wait_without_a_notify_times_out():
    assert IdentityWakeup().wait(0) is False


def test_a_notify_wakes_the_next_wait_once():
    wakeup = IdentityWakeup()
    wakeup.notify()
    wakeup.notify()  # several writers before the worker looks: one wake-up

    assert wakeup.wait(0) is True
    assert wakeup.wait(0) is False


def test_a_notify_from_another_thread_ends_a_blocked_wait():
    wakeup = IdentityWakeup()
    woke = []
    waiter = threading.Thread(target=lambda: woke.append(wakeup.wait(10)))
    waiter.start()
    wakeup.notify()
    waiter.join(10)

    assert woke == [True]


# --- _insert_audio_identity_in (spec §6.2 ingest row) -------------------------------

LIFECYCLE = {"match_state": "pending", "priority": 0, "attempts": 0, "next_attempt_at": None}


def test_a_computed_exact_layer_is_written_current(db):
    uuid_id = _bare_track(db)
    _insert(db, uuid_id, _current())

    row = _identity(db, uuid_id)
    assert {k: row[k] for k in (
        "exact_state", "exact_kind", "exact_digest", "sample_rate_hz", "channels",
        "bits_per_sample", "failure_reason", "computed_at", "tool_versions", "fp_state",
        "fp_algorithm", "generation", *LIFECYCLE,
    )} == {
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": DIGEST,
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 24,
        "failure_reason": None, "computed_at": 1_700_000_000,
        "tool_versions": "ffmpeg 9.0.2", "fp_state": "unavailable", "fp_algorithm": None,
        "generation": 1, **LIFECYCLE,
    }


def test_the_fingerprint_layer_is_pending_only_when_a_fingerprinter_is_present(db):
    with_tool, without = _bare_track(db), _bare_track(db)
    _insert(db, with_tool, _current(), fingerprinter_present=True)
    _insert(db, without, _current(), fingerprinter_present=False)

    assert _identity(db, with_tool)["fp_state"] == "pending"
    assert _identity(db, without)["fp_state"] == "unavailable"


def test_a_failed_hash_is_stored_pending_never_failed(db):
    """Plan D12: a compute failure at ingest (ffmpeg missing, timeout, kill)
    leaves the exact layer pending for the worker; unknown, not failed."""
    uuid_id = _bare_track(db)
    _insert(db, uuid_id, AudioIdentity(
        exact=ExactUnavailable("failed", "tool_missing"), tool_versions=None, computed_at=5,
    ))

    row = _identity(db, uuid_id)
    assert (row["exact_state"], row["exact_kind"], row["exact_digest"], row["failure_reason"]) \
        == ("pending", None, None, None)
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE


def test_an_unsupported_codec_is_stored_unsupported(db):
    uuid_id = _bare_track(db)
    _insert(db, uuid_id, AudioIdentity(
        exact=ExactUnavailable("unsupported", None), tool_versions="ffmpeg 9.0.2", computed_at=5,
    ))

    row = _identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"]) == ("unsupported", None)


def test_no_identity_writes_a_pending_row(db):
    uuid_id = _bare_track(db)
    _insert(db, uuid_id, None)

    row = _identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"], row["computed_at"], row["tool_versions"]) \
        == ("pending", None, None, None)
    assert row["generation"] == 1
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE


def test_a_second_insert_bumps_the_generation_and_replaces_the_values(db):
    uuid_id = _bare_track(db)
    _insert(db, uuid_id, None)
    _sql(db, "UPDATE track_audio_identity SET priority = 1, attempts = 2, "
             "next_attempt_at = 99, match_state = 'current' WHERE uuid_id = ?", (uuid_id,))
    _insert(db, uuid_id, _current())

    row = _identity(db, uuid_id)
    assert (row["generation"], row["exact_state"], row["exact_digest"]) == (2, "current", DIGEST)
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE


def test_the_insert_primitive_never_commits(db):
    """SC-16a: ``_<verb>_in`` never opens, commits or closes a connection."""
    uuid_id = _bare_track(db)
    _insert(db, uuid_id, _current(), commit=False)

    assert _identity(db, uuid_id) is None


# --- add_track: the one insertion path writes the identity in its transaction ------


def _new_track(title="Lucky", identity=None):
    track = Track(
        file_path=Path(f"/m/{title}.flac"),
        metadata=TrackMetaData(title=title, artist="Radiohead", codec="flac", duration=1.0),
    )
    if identity is not None:
        track.audio_identity = identity
    return track


def test_add_track_writes_a_pending_identity_row_when_nothing_was_computed(db):
    track = _new_track()
    assert db.add_track(track)

    row = _identity(db, track.uuid_id)
    assert (row["exact_state"], row["fp_state"], row["generation"]) == ("pending", "unavailable", 1)
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE


def test_add_track_writes_the_computed_exact_layer_current(db):
    track = _new_track(identity=_current())
    assert db.add_track(track)

    row = _identity(db, track.uuid_id)
    assert (row["exact_state"], row["exact_kind"], row["exact_digest"]) == ("current", "pcm_sha256", DIGEST)
    assert {k: row[k] for k in LIFECYCLE} == LIFECYCLE


def test_the_owners_library_passes_the_fingerprinter_flag(db):
    track = _new_track()
    assert Library(db, db.owner_id).add_track(track, fingerprinter_present=True)

    assert _identity(db, track.uuid_id)["fp_state"] == "pending"


def test_a_failure_before_commit_leaves_neither_the_track_nor_its_identity(db, monkeypatch):
    """Exit proof: identity and track commit together or not at all."""
    real = Database._insert_audio_identity_in

    def insert_then_crash(conn, uuid_id, identity, *, fingerprinter_present):
        real(conn, uuid_id, identity, fingerprinter_present=fingerprinter_present)
        raise RuntimeError("crash before commit")

    monkeypatch.setattr(Database, "_insert_audio_identity_in", staticmethod(insert_then_crash))
    track = _new_track(identity=_current())

    assert db.add_track(track) is False
    assert _sql(db, "SELECT uuid_id FROM tracks WHERE uuid_id = ?", (track.uuid_id,)) == []
    assert _identity(db, track.uuid_id) is None


def test_the_identity_is_written_last_in_the_insert_transaction(db, monkeypatch):
    """The identity insert sees the track row it references (same transaction)."""
    seen = []
    real = Database._insert_audio_identity_in

    def spy(conn, uuid_id, identity, **kwargs):
        seen.append(conn.execute("SELECT count(*) FROM trackmetadata WHERE uuid_id = ?",
                                 (uuid_id,)).fetchone()[0])
        real(conn, uuid_id, identity, **kwargs)

    monkeypatch.setattr(Database, "_insert_audio_identity_in", staticmethod(spy))
    track = _new_track()
    assert db.add_track(track)
    assert seen == [1]


def test_the_carried_identity_never_reaches_a_serialized_track():
    track = _new_track(identity=_current())
    assert "audio_identity" not in track.model_dump()
    assert "audio_identity" not in track.model_dump_json()


# --- _mark_audio_identity_stale_in (spec §6.2 Phase 1 rows, plan D8/D13) ----------


def _settled_row(db, fp_state="current", owner_id=None):
    """A track whose identity the worker has fully computed and matched."""
    uuid_id = _bare_track(db, owner_id)
    _insert(db, uuid_id, _current())
    _sql(db, "UPDATE track_audio_identity SET fp_state = ?, fp_algorithm = 'chromaprint-2', "
             "match_state = 'current', matcher_version = 'm1', priority = 1, attempts = 2, "
             "next_attempt_at = 99, failure_reason = 'decode_error', generation = 7 "
             "WHERE uuid_id = ?", (fp_state, uuid_id))
    return uuid_id


def _mark(db, uuid_id, reason, *, commit=True):
    with db._connection(commit=commit) as conn:
        return Database._mark_audio_identity_stale_in(conn, uuid_id, reason)


STALE = {"generation": 8, "exact_state": "pending", "match_state": "pending", "priority": 0,
         "attempts": 0, "next_attempt_at": None, "failure_reason": None}
KEPT = {"exact_kind": "pcm_sha256", "exact_digest": DIGEST, "sample_rate_hz": 44100,
        "channels": 2, "fp_algorithm": "chromaprint-2", "matcher_version": "m1"}


def test_a_tag_write_marks_the_exact_layer_pending_and_keeps_digest_and_fingerprint(db):
    uuid_id = _settled_row(db)

    assert _mark(db, uuid_id, "tag_write") is True

    row = _identity(db, uuid_id)
    assert {k: row[k] for k in (*STALE, *KEPT, "fp_state")} == {**STALE, **KEPT, "fp_state": "current"}


@pytest.mark.parametrize("reason", ["conversion", "settle"])
@pytest.mark.parametrize("fp_before", ["current", "too_short", "low_information", "failed", "pending"])
def test_a_conversion_or_settle_marks_every_layer_pending(db, reason, fp_before):
    uuid_id = _settled_row(db, fp_state=fp_before)

    assert _mark(db, uuid_id, reason) is True

    row = _identity(db, uuid_id)
    assert {k: row[k] for k in (*STALE, *KEPT, "fp_state")} == {**STALE, **KEPT, "fp_state": "pending"}


@pytest.mark.parametrize("reason", ["tag_write", "conversion", "settle"])
def test_a_mark_never_claims_a_fingerprinter_exists(db, reason):
    """A row written without a fingerprinter stays ``unavailable``; only the
    startup reconcile (6.5B.1b) turns it pending when a tool appears."""
    uuid_id = _settled_row(db, fp_state="unavailable")

    _mark(db, uuid_id, reason)

    assert _identity(db, uuid_id)["fp_state"] == "unavailable"


def test_an_unknown_reason_is_refused_and_changes_nothing(db):
    uuid_id = _settled_row(db)
    before = _identity(db, uuid_id)

    with pytest.raises(ValueError):
        _mark(db, uuid_id, "retag")

    assert _identity(db, uuid_id) == before


def test_marking_a_track_with_no_identity_row_changes_nothing(db):
    uuid_id = _bare_track(db)

    assert _mark(db, uuid_id, "tag_write") is False
    assert _identity(db, uuid_id) is None


def test_the_mark_primitive_never_commits(db):
    uuid_id = _settled_row(db)
    before = _identity(db, uuid_id)

    _mark(db, uuid_id, "conversion", commit=False)

    assert _identity(db, uuid_id) == before


# --- the owned public mark (SC-28: reached only through the owner's track) ---------


def test_the_owner_marks_its_own_track_through_its_library(db):
    uuid_id = _settled_row(db)

    assert Library(db, db.owner_id).mark_audio_identity_stale(uuid_id, "tag_write") is True
    assert _identity(db, uuid_id)["generation"] == 8


def test_another_owner_can_never_mark_a_foreign_track(db):
    from tests.owned_database import add_test_user

    alex = add_test_user(db, "Alex")
    uuid_id = _settled_row(db)
    before = _identity(db, uuid_id)

    assert Library(db, alex).mark_audio_identity_stale(uuid_id, "conversion") is False
    assert _identity(db, uuid_id) == before


# --- SC-16a: no public wrapper (no second connection) inside a writer transaction ---

@pytest.fixture
def connection_depth(monkeypatch):
    """The deepest nesting of ``Database._connection`` seen on this thread."""
    real = Database._connection
    state = {"depth": 0, "max": 0}

    @contextlib.contextmanager
    def tracked(self, *args, **kwargs):
        state["depth"] += 1
        state["max"] = max(state["max"], state["depth"])
        try:
            with real(self, *args, **kwargs) as conn:
                yield conn
        finally:
            state["depth"] -= 1

    monkeypatch.setattr(Database, "_connection", tracked)
    return state


def test_no_identity_writer_opens_a_connection_inside_its_transaction(db, connection_depth):
    track = _new_track(identity=_current())
    assert db.add_track(track, fingerprinter_present=True)
    db.apply_track_metadata_edit(track.uuid_id, {"title": "New"}, track.revision, master_rewritten=True)
    db.mark_audio_identity_stale(track.uuid_id, "tag_write")
    assert db.refresh_track_audio_properties(
        track.uuid_id, codec="flac", bitrate_kbps=None, sample_rate_hz=None, channels=None,
        duration=None, owner_id=db.owner_id,
    ) is not None

    assert _identity(db, track.uuid_id)["generation"] == 4
    assert connection_depth["max"] == 1


def test_6_5a2d_the_worker_cas_write_opens_no_second_connection(db, connection_depth):
    """The worker's write (and its in-transaction stat check) never opens a
    nested connection."""
    track = _new_track(identity=_current())
    assert db.add_track(track, fingerprinter_present=False)
    generation = _identity(db, track.uuid_id)["generation"]
    assert db.update_identity_if_unchanged(
        track.uuid_id, generation=generation, file_path=str(track.file_path),
        values={"attempts": 1}, verify=lambda: True, owner_id=db.owner_id,
    ) is True
    assert connection_depth["max"] == 1
