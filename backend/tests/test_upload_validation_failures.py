"""7A.2c S6 (spec §5: "Advisory, never a validation failure. An identity or
tool failure yields a report saying so ... and the item is still reviewable";
"Separate transport error, invalid audio, invalid archive, quota, probe-timeout
and disk failures"; §3 `failed`: "Explicit Retry ... only when underlying
source/retryability exists"; plan D10; spec §3 `duplicate_conflict`: "the
worker re-runs `find_duplicates` on the stored staged identity, without
re-hashing"): how a validation step ends when something goes wrong."""

import os
import sqlite3

import pytest

from app.services import upload_validation
from app.services.audio_identity import FingerprintIdentity
from app.services.storage_ledger import UPLOAD_SOURCE
from app.services.upload_errors import probe_timeout, upload_invalid_audio
from app.services.upload_validation import ValidationFailed, ValidationInterrupted
from tests.identity_worker_fixtures import add_track, make_db, sql
from tests.upload_validation_fixtures import (
    BOOT,
    FINGERPRINTER,
    FakeCompute,
    FakeProbe,
    detected,
    exact_for,
    identity_row,
    item_row,
    make_worker,
    report_of,
    source_rows,
    stage_item,
)


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


def _error(row):
    return (row["state"], row["error_code"], row["error_retryable"])


# ── item failures ─────────────────────────────────────────────────────────

def test_a_probe_timeout_fails_the_item_retryably_and_keeps_its_source(db, root):
    staged = stage_item(db, root, content=b"abc")

    outcome = make_worker(db, root, probe=FakeProbe(ValidationFailed(probe_timeout()))).process_one()

    row = item_row(db, staged)
    assert outcome == "failed"
    assert _error(row) == ("failed", "probe_timeout", 1)
    assert row["error_message"]
    assert row["lease_boot_id"] is None
    assert (row["duplicate_report"], row["detected_metadata"]) == (None, None)
    assert identity_row(db, staged) is None
    # Retry re-validates from the same bytes: they stay, still counted.
    assert staged["source"].read_bytes() == b"abc"
    assert row["source_path"] == str(staged["source"])
    assert source_rows(db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 3}]


def test_invalid_audio_fails_the_item_for_good_and_gives_its_bytes_back(db, root):
    staged = stage_item(db, root, content=b"abc")

    make_worker(db, root, probe=FakeProbe(ValidationFailed(upload_invalid_audio()))).process_one()

    row = item_row(db, staged)
    assert _error(row) == ("failed", "upload_invalid_audio", 0)
    assert not staged["source"].exists()
    assert row["source_path"] is None
    assert source_rows(db, staged) == []


def test_a_source_that_cannot_be_removed_stays_recorded_and_counted(db, root, monkeypatch):
    staged = stage_item(db, root, content=b"abc")

    def refuse(path):
        raise PermissionError("no")

    monkeypatch.setattr(os, "unlink", refuse)
    make_worker(db, root, probe=FakeProbe(ValidationFailed(upload_invalid_audio()))).process_one()

    row = item_row(db, staged)
    assert _error(row) == ("failed", "upload_invalid_audio", 0)
    assert staged["source"].exists()
    assert row["source_path"] == str(staged["source"])
    assert source_rows(db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 3}]


def test_a_missing_source_fails_retryably(db, root):
    staged = stage_item(db, root)
    staged["source"].unlink()
    probe = FakeProbe()

    make_worker(db, root, probe=probe).process_one()

    assert _error(item_row(db, staged)) == ("failed", "upload_source_missing", 1)
    assert probe.calls == []


def test_a_recorded_source_outside_the_uploads_tree_is_never_read_or_removed(db, root, tmp_path):
    staged = stage_item(db, root)
    outside = tmp_path / "elsewhere.flac"
    outside.write_bytes(b"not ours")
    sql(db, "UPDATE upload_items SET source_path = ? WHERE item_uuid = ?", (str(outside), staged["item_uuid"]))
    probe = FakeProbe(ValidationFailed(upload_invalid_audio()))

    make_worker(db, root, probe=probe).process_one()

    assert item_row(db, staged)["state"] == "failed"
    assert probe.calls == []
    assert outside.read_bytes() == b"not ours"


def test_an_unexpected_error_before_the_check_fails_the_item_retryably(db, root):
    staged = stage_item(db, root)

    outcome = make_worker(db, root, probe=FakeProbe(RuntimeError("boom"))).process_one()

    row = item_row(db, staged)
    assert outcome == "failed"
    assert _error(row) == ("failed", "upload_validation_failed", 1)
    assert "boom" not in row["error_message"]
    assert row["lease_boot_id"] is None


def test_a_database_error_at_the_finish_fails_the_item_retryably(db, root, monkeypatch):
    staged = stage_item(db, root)

    def broken(**kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(db, "finish_upload_validation", broken)
    make_worker(db, root).process_one()

    assert _error(item_row(db, staged)) == ("failed", "upload_validation_failed", 1)


def test_a_failed_item_never_blocks_the_next(db, root):
    bad = stage_item(db, root, content=b"bad", progress_at=1)
    good = stage_item(db, root, content=b"good", progress_at=2)
    probe = FakeProbe(RuntimeError("boom"))
    worker = make_worker(db, root, probe=probe)

    worker.process_one()
    probe.result = detected()
    worker.process_one()

    assert (item_row(db, bad)["state"], item_row(db, good)["state"]) == ("failed", "review_ready")
    assert worker.process_one() == "idle"


def test_an_interrupted_probe_writes_nothing(db, root):
    # A stop kills the probe (review r1 R4: a kill without a stop or cancel fails the item instead).
    staged = stage_item(db, root)
    before = item_row(db, staged)
    probe = FakeProbe(ValidationInterrupted())
    worker = make_worker(db, root, probe=probe)
    probe.mid = worker.request_stop

    outcome = worker.process_one()

    row = item_row(db, staged)
    assert outcome == "interrupted"
    assert (row["state"], row["error_code"], row["duplicate_report"]) == ("validating", None, None)
    assert {k: row[k] for k in ("detected_metadata", "review_version", "source_path")} == {
        k: before[k] for k in ("detected_metadata", "review_version", "source_path")}
    assert identity_row(db, staged) is None


# ── advisory failures: the item is still reviewable ───────────────────────

def test_an_identity_computation_that_raises_is_advisory(db, root):
    staged = stage_item(db, root)
    compute = FakeCompute()
    compute.raises = RuntimeError("boom")

    make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER).process_one()

    row = item_row(db, staged)
    assert (row["state"], row["error_code"]) == ("review_ready", None)
    report = report_of(db, staged)
    assert report["exact"]["subject_state"] == "failed"
    assert report["fingerprint"]["subject_state"] == "failed"
    assert identity_row(db, staged)["failure_reason"] == "internal_error"


def test_a_finder_error_is_advisory_and_reported_as_a_failed_check(db, root, monkeypatch):
    staged = stage_item(db, root)

    def broken(*args, **kwargs):
        raise RuntimeError("finder broke")

    monkeypatch.setattr(upload_validation, "find_duplicates", broken)
    make_worker(db, root).process_one()

    row = item_row(db, staged)
    assert (row["state"], row["error_code"]) == ("review_ready", None)
    assert report_of(db, staged) == {"v": 1, "status": "failed", "exact": None, "fingerprint": None,
                                     "matches": []}
    assert identity_row(db, staged) is not None


@pytest.mark.parametrize("duration_s", [None, 0.0, -3.0])
def test_a_print_that_would_not_read_back_is_stored_failed_never_fails_the_item(db, root, duration_s):
    # D10 / N05: a current print without a positive duration.
    staged = stage_item(db, root, content=b"a")
    compute = FakeCompute()
    compute.prints[b"a"] = FingerprintIdentity("current", "fakeprint", "chromaprint-2", duration_s, (1, 2, 3))

    make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER).process_one()

    assert item_row(db, staged)["state"] == "review_ready"
    stored = identity_row(db, staged)
    assert (stored["fp_state"], stored["fp_failure_reason"], stored["fp_data"]) == ("failed", "output_error", None)
    assert report_of(db, staged)["fingerprint"]["subject_state"] == "failed"


# ── ZIP: 7A.2d's dispatch point ───────────────────────────────────────────

@pytest.mark.parametrize("magic", [b"PK\x03\x04", b"PK\x05\x06"])
def test_a_zip_is_never_probed_as_audio_and_by_default_is_refused(db, root, magic):
    staged = stage_item(db, root, content=magic + b"rest")
    probe = FakeProbe()

    make_worker(db, root, probe=probe).process_one()

    assert _error(item_row(db, staged)) == ("failed", "upload_archive_unsupported", 0)
    assert probe.calls == []


def test_a_zip_goes_to_the_zip_handler_when_one_is_plugged_in(db, root):
    staged = stage_item(db, root, content=b"PK\x03\x04rest")
    handled = []
    probe = FakeProbe()

    make_worker(db, root, probe=probe, zip_handler=lambda item, **_: handled.append(item) or "expanded").process_one()

    [item] = handled
    assert (item["owner_id"], item["item_uuid"]) == (staged["owner_id"], staged["item_uuid"])
    assert probe.calls == []


# ── re-check from the stored identity (retry of duplicate_conflict) ───────

def test_an_item_with_a_stored_identity_is_rechecked_without_probing_or_hashing(db, root):
    staged = stage_item(db, root, content=b"audio-A")
    make_worker(db, root).process_one()
    stored = identity_row(db, staged)
    # Since the review: the same audio arrived in the library; the item is retried.
    track = add_track(db, "/m/arrived.flac", identity={
        "exact_state": "current", "exact_kind": "pcm_sha256", "exact_digest": exact_for(b"audio-A").digest,
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16, "match_state": "current"})
    sql(db, "UPDATE upload_items SET state = 'validating', duplicate_report = NULL, review_version = 1 "
            "WHERE item_uuid = ?", (staged["item_uuid"],))
    probe, compute = FakeProbe(), FakeCompute()

    make_worker(db, root, probe=probe, compute=compute).process_one()

    assert (probe.calls, compute.calls) == ([], [])
    assert identity_row(db, staged) == stored
    assert item_row(db, staged)["state"] == "review_ready"
    assert [m["id"] for m in report_of(db, staged)["matches"]] == [track]
    assert item_row(db, staged)["review_version"] == 1


def test_a_flagged_item_never_blocks_the_queue(db, root):
    # Self-audit: a validating row that carries the durable cancel flag is
    # never claimed, and the items behind it are still validated.
    flagged = stage_item(db, root, content=b"flagged", progress_at=1)
    sql(db, "UPDATE upload_items SET cancel_requested = 1 WHERE item_uuid = ?", (flagged["item_uuid"],))
    behind = stage_item(db, root, content=b"behind", progress_at=2)

    make_worker(db, root).process_one()

    assert item_row(db, behind)["state"] == "review_ready"
    assert item_row(db, flagged)["state"] == "validating"
