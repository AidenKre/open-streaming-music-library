"""Phase 6.5A.2d: one step of the audio-identity worker (spec §6.4; review 6.5-U06).

``process_one()`` takes the next queued row (priority, then rowid), stat()s
the master, computes the pending exact layer and writes it with a CAS on the
generation, the master path, a second equal stat() and no ``edit_journal``
row. The digest oracle is the SHA-256 of the file bytes (see
``identity_worker_fakes``), so expectations never come from the code under
test.
"""

import logging
import os
import sqlite3

import pytest

from app.database.database import Database
from app.services.audio_identity import (
    KIND_PACKETS,
    AudioIdentity,
    ExactAudioHash,
    ExactUnavailable,
)
from tests.identity_worker_fakes import (
    T0,
    TOOLS,
    FakeClock,
    FakeCompute,
    bytes_digest,
    hash_of,
    make_worker,
)
from tests.identity_worker_fixtures import (
    DIGEST_A,
    add_track,
    identity,
    set_identity,
    sql,
)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def _file(music, name, content=b"audio-1"):
    path = music / name
    path.write_bytes(content)
    return path


def _stat(path):
    st = os.stat(path)
    return {"stat_size": st.st_size, "stat_mtime_ns": st.st_mtime_ns, "stat_inode": st.st_ino}


def _revision(db, uuid_id):
    return sql(db, "SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,))[0]["revision"]


# --- a successful step ---------------------------------------------------------------------


def test_a_pending_exact_layer_is_computed_and_written_current(db, music):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path, codec="flac", identity={
        "generation": 4, "attempts": 2, "next_attempt_at": T0 - 1, "failure_reason": "timeout",
    })
    compute = FakeCompute()
    worker = make_worker(db, compute=compute)

    worker.process_one()

    row = identity(db, uuid_id)
    assert {k: row[k] for k in (
        "exact_state", "exact_kind", "exact_digest", "sample_rate_hz", "channels",
        "bits_per_sample", "attempts", "next_attempt_at", "failure_reason",
        "computed_at", "tool_versions", "generation",
    )} == {
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path),
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16, "attempts": 0,
        "next_attempt_at": None, "failure_reason": None, "computed_at": T0,
        "tool_versions": TOOLS, "generation": 4,
    }
    assert {k: row[k] for k in ("stat_size", "stat_mtime_ns", "stat_inode")} == _stat(path)
    # match_state stays pending until 6.5A.3; the fingerprint is not touched.
    assert (row["match_state"], row["fp_state"]) == ("pending", "unavailable")
    [call] = compute.calls
    assert (call["path"], call["codec_hint"], call["low_priority"]) == (str(path), "flac", True)
    assert call["registry"] is worker.registry and call["job_id"] is not None


def test_new_and_changed_tracks_are_computed_before_the_backfill(db, music):
    backfill = add_track(db, _file(music, "1.flac"), identity={"priority": 1})
    new = add_track(db, _file(music, "2.flac"), identity={"priority": 0})
    compute = FakeCompute()
    worker = make_worker(db, compute=compute)

    # 6.5A.3: each track takes an exact step, then its match step.
    for _ in range(4):
        worker.process_one()

    assert compute.paths() == [str(music / "2.flac"), str(music / "1.flac")]
    assert identity(db, new)["exact_state"] == identity(db, backfill)["exact_state"] == "current"


def test_with_nothing_to_do_a_step_computes_nothing(db, music):
    add_track(db, _file(music, "1.flac"), identity={
        "exact_state": "current", "fp_state": "pending", "match_state": "current"})
    compute = FakeCompute()
    worker = make_worker(db, compute=compute)

    result = worker.process_one()

    assert compute.calls == []
    assert result.delay_s > 0  # the loop waits; it never spins


def test_an_unsupported_codec_is_stored_unsupported_and_leaves_the_queue(db, music):
    uuid_id = add_track(db, _file(music, "a.opus"), codec="opus")
    compute = FakeCompute()
    compute.results.append(ExactUnavailable("unsupported", None))
    worker = make_worker(db, compute=compute)

    worker.process_one()
    worker.process_one()

    assert identity(db, uuid_id)["exact_state"] == "unsupported"
    assert identity(db, uuid_id)["attempts"] == 0
    assert len(compute.calls) == 1


def test_a_lossy_hash_has_no_bit_depth(db, music):
    path = _file(music, "a.mp3")
    uuid_id = add_track(db, path, codec="mp3")
    compute = FakeCompute()
    compute.results.append(ExactAudioHash(KIND_PACKETS, DIGEST_A, 44100, 2, None))
    make_worker(db, compute=compute).process_one()

    row = identity(db, uuid_id)
    assert (row["exact_kind"], row["exact_digest"], row["bits_per_sample"]) == (KIND_PACKETS, DIGEST_A, None)


# --- the fingerprint rule and the tag-write anomaly (spec §6.4 "Computation") ----------------


def test_an_unchanged_digest_after_a_tag_write_keeps_the_fingerprint(db, music, caplog):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path, identity={
        "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path), "fp_state": "current",
        "fp_algorithm": "chromaprint-2",
    })
    with caplog.at_level(logging.WARNING):
        make_worker(db).process_one()

    row = identity(db, uuid_id)
    assert (row["exact_state"], row["fp_state"], row["fp_algorithm"]) == ("current", "current", "chromaprint-2")
    assert not [r for r in caplog.records if r.levelno >= logging.WARNING]


def test_a_changed_digest_after_a_tag_write_is_an_anomaly_and_recomputes_the_fingerprint(db, music, caplog):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path, identity={
        "exact_kind": "pcm_sha256", "exact_digest": DIGEST_A, "fp_state": "current",
    })
    with caplog.at_level(logging.WARNING):
        make_worker(db).process_one()

    row = identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"], row["fp_state"]) == ("current", bytes_digest(path), "pending")
    warnings = [r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING]
    assert len(warnings) == 1 and uuid_id in warnings[0] and str(path) not in warnings[0]


def test_a_changed_digest_never_claims_a_fingerprinter_exists(db, music):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path, identity={"exact_digest": DIGEST_A, "fp_state": "unavailable"})
    make_worker(db).process_one()
    assert identity(db, uuid_id)["fp_state"] == "unavailable"


def test_a_first_digest_leaves_a_pending_fingerprint_pending(db, music):
    uuid_id = add_track(db, _file(music, "a.flac"), identity={"exact_digest": None, "fp_state": "pending"})
    make_worker(db).process_one()
    assert (identity(db, uuid_id)["exact_state"], identity(db, uuid_id)["fp_state"]) == ("current", "pending")


@pytest.mark.parametrize("reason", ["tag_write", "conversion", "settle"])
def test_every_stale_mark_is_recomputed(db, music, reason):
    """DEV-6.5-03 and the tag-write / conversion / recovery marks: whatever made
    the layer stale, the worker brings it back to current for the bytes now
    at the master path."""
    path = _file(music, "a.flac", b"old")
    uuid_id = add_track(db, path, identity={
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": bytes_digest(path),
        "fp_state": "current", "generation": 2,
    })
    path.write_bytes(b"new bytes")
    with db._connection(commit=True) as conn:
        assert Database._mark_audio_identity_stale_in(conn, uuid_id, reason)

    make_worker(db).process_one()

    row = identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"], row["generation"]) == ("current", bytes_digest(path), 3)
    assert row["fp_state"] == "pending"


# --- the CAS: a writer racing the compute (spec §6.4 "Write (CAS)"; 6.5-U06) ----------------


def test_a_relocation_mid_compute_discards_the_result_and_recomputes(db, music):
    old = _file(music, "old.flac", b"before the tag write")
    uuid_id = add_track(db, old)
    new = music / "new.flac"
    compute = FakeCompute()

    def relocate():  # TrackEditor._relocate: journal -> move -> commit (bump) -> unlink -> journal delete
        journal = db.insert_journal_entry("relocate", uuid_id, old_path=str(old), new_path=str(new))
        new.write_bytes(b"after the tag write")
        db.apply_track_metadata_edit(uuid_id, {"title": "New"}, _revision(db, uuid_id),
                                     new_file_path=str(new), master_rewritten=True)
        old.unlink()
        db.delete_journal_entry(journal)

    compute.mid = relocate
    worker = make_worker(db, compute=compute)

    worker.process_one()
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"], row["attempts"]) == ("pending", None, 0)

    worker.process_one()
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"]) == ("current", bytes_digest(new))
    assert compute.paths() == [str(old), str(new)]


def test_an_in_place_tag_write_mid_compute_discards_the_result_and_recomputes(db, music):
    path = _file(music, "a.flac", b"before")
    uuid_id = add_track(db, path)
    compute = FakeCompute()

    def inplace():  # TrackEditor._inplace: commit -> journal -> os.replace -> mark -> journal delete
        db.apply_track_metadata_edit(uuid_id, {"title": "New"}, _revision(db, uuid_id))
        journal = db.insert_journal_entry("inplace", uuid_id, old_path=str(path))
        staged = music / "staged.tmp"
        staged.write_bytes(b"after the in-place tag write")
        os.replace(staged, path)
        db.mark_audio_identity_stale(uuid_id, "tag_write")
        db.delete_journal_entry(journal)

    compute.mid = inplace
    worker = make_worker(db, compute=compute)

    worker.process_one()
    assert identity(db, uuid_id)["exact_state"] == "pending"
    worker.process_one()
    assert (identity(db, uuid_id)["exact_state"], identity(db, uuid_id)["exact_digest"]) == (
        "current", bytes_digest(path))


def test_an_in_place_conversion_mid_compute_keeps_the_conversions_identity(db, music):
    path = _file(music, "a.m4a", b"alac bytes")
    uuid_id = add_track(db, path, codec="alac")
    compute = FakeCompute()

    def convert():  # in-place conversion: journal -> os.replace -> identity write -> journal delete
        journal = db.insert_journal_entry("convert", uuid_id, old_path=str(path))
        staged = music / "converted.tmp"
        staged.write_bytes(b"aac bytes")
        os.replace(staged, path)
        db.write_conversion_identity(
            uuid_id, AudioIdentity(exact=hash_of(path), tool_versions=TOOLS, computed_at=T0 + 5))
        db.delete_journal_entry(journal)

    compute.mid = convert
    worker = make_worker(db, compute=compute)

    worker.process_one()
    row = identity(db, uuid_id)
    assert (row["exact_state"], row["exact_digest"], row["computed_at"]) == (
        "current", bytes_digest(path), T0 + 5)
    worker.process_one()
    assert len(compute.calls) == 1  # the conversion's identity is current: nothing to redo


def test_a_conversion_whose_hash_failed_is_recomputed_after_the_race(db, music):
    path = _file(music, "a.m4a", b"alac bytes")
    uuid_id = add_track(db, path, codec="alac")
    compute = FakeCompute()

    def convert():
        journal = db.insert_journal_entry("convert", uuid_id, old_path=str(path))
        path.write_bytes(b"aac bytes")
        db.write_conversion_identity(uuid_id, AudioIdentity(
            exact=ExactUnavailable("failed", "timeout"), tool_versions=TOOLS, computed_at=T0))
        db.delete_journal_entry(journal)

    compute.mid = convert
    worker = make_worker(db, compute=compute)
    worker.process_one()
    worker.process_one()

    assert (identity(db, uuid_id)["exact_state"], identity(db, uuid_id)["exact_digest"]) == (
        "current", bytes_digest(path))


def test_a_journal_row_left_mid_compute_discards_the_result(db, music):
    # The in-place write is between os.replace and its mark: only the journal
    # row tells the worker a file operation is in flight.
    path = _file(music, "a.flac", b"before")
    uuid_id = add_track(db, path)
    compute = FakeCompute()
    compute.mid = lambda: db.insert_journal_entry("inplace", uuid_id, old_path=str(path))
    worker = make_worker(db, compute=compute)

    worker.process_one()
    assert identity(db, uuid_id)["exact_state"] == "pending"
    worker.process_one()  # the journal row hides the track from the queue
    assert len(compute.calls) == 1


def test_bytes_replaced_before_any_db_change_discard_the_result(db, music):
    # The second stat() catches a replace whose generation bump has not
    # committed yet (or an out-of-band write).
    path = _file(music, "a.flac", b"before")
    uuid_id = add_track(db, path)
    compute = FakeCompute()

    def replace():
        staged = music / "staged.tmp"
        staged.write_bytes(b"after, a different size")
        os.replace(staged, path)

    compute.mid = replace
    clock = FakeClock()
    worker = make_worker(db, compute=compute, clock=clock)

    worker.process_one()
    assert identity(db, uuid_id)["exact_state"] == "pending"
    # Review F5: set aside for the first backoff (no back-to-back re-decode of
    # a file that changes outside OSML); a writer's mark would lift it at once.
    clock.advance(60)
    worker.process_one()
    assert (identity(db, uuid_id)["exact_state"], identity(db, uuid_id)["exact_digest"]) == (
        "current", bytes_digest(path))


def test_a_track_deleted_mid_compute_is_dropped_quietly(db, music):
    path = _file(music, "a.flac")
    uuid_id = add_track(db, path)
    other = add_track(db, _file(music, "b.flac"))
    compute = FakeCompute()
    compute.mid = lambda: db.delete_track(uuid_id)
    worker = make_worker(db, compute=compute)

    worker.process_one()
    worker.process_one()

    assert identity(db, uuid_id) is None
    assert identity(db, other)["exact_state"] == "current"
