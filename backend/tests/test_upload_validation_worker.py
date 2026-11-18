"""7A.2c S3 (spec §5 "Duplicate check": validation of each audio item ends with
the duplicate check, run in the same bounded validation worker after the
probe; §3 `validating` → `review_ready` "only after its duplicate check has
completed"; SC-16d claims by boot id; plan D35): one worker step takes the next
item, probes it, computes its identity, and in one transaction stores the
identity, the detected metadata and the report and moves it to review_ready."""

import json

import pytest

from app.services.storage_ledger import UPLOAD_SOURCE
from app.services.upload_validation import staged_identity_columns
from tests.identity_worker_fixtures import sql
from tests.upload_validation_fixtures import (
    BOOT,
    DEAD_BOOT,
    FINGERPRINTER,
    FakeCompute,
    FakeProbe,
    detected,
    identity_row,
    item_row,
    make_worker,
    report_of,
    source_rows,
    stage_item,
)

EMPTY_COVERAGE = {"library_pending": 0, "library_failed": 0, "library_not_comparable": 0}


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


def test_an_item_waiting_for_validation_has_no_report_and_no_detected_metadata(db, root):
    staged = stage_item(db, root)

    row = item_row(db, staged)
    assert (row["state"], row["duplicate_report"], row["detected_metadata"]) == ("validating", None, None)
    assert identity_row(db, staged) is None


def test_one_step_validates_the_next_item_into_review_ready(db, root):
    staged = stage_item(db, root, content=b"audio-A")
    compute = FakeCompute()
    worker = make_worker(db, root, compute=compute)

    worker.process_one()

    row = item_row(db, staged)
    assert row["state"] == "review_ready"
    assert row["kind"] == "audio"
    assert row["lease_boot_id"] is None
    assert row["review_version"] == 0
    assert (row["error_code"], row["error_message"], row["error_retryable"]) == (None, None, None)
    assert json.loads(row["detected_metadata"]) == detected()
    # The stored identity is exactly the SC-25 columns of what was computed.
    expected = staged_identity_columns(compute(staged["source"], "flac"), fingerprinter_present=False)
    stored = identity_row(db, staged)
    assert {k: stored[k] for k in expected} == expected
    assert report_of(db, staged) == {
        "v": 1, "status": "complete",
        "exact": {"subject_state": "current", **EMPTY_COVERAGE},
        "fingerprint": {"subject_state": "unavailable", **EMPTY_COVERAGE},
        "matches": [],
    }


def test_validation_leaves_the_source_and_its_quota_row_in_place(db, root):
    staged = stage_item(db, root, content=b"audio-A")

    make_worker(db, root).process_one()

    assert staged["source"].read_bytes() == b"audio-A"
    assert item_row(db, staged)["source_path"] == str(staged["source"])
    assert source_rows(db, staged) == [{"purpose": UPLOAD_SOURCE, "bytes": 7}]


def test_the_identity_is_computed_from_the_staged_source_with_the_probed_codec_and_duration(db, root):
    staged = stage_item(db, root)
    compute = FakeCompute()
    worker = make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER,
                         probe=FakeProbe(detected("alac", duration_s=31.25, mime="audio/mp4",
                                                  container="mov,mp4,m4a,3gp,3g2,mj2")))

    worker.process_one()

    [call] = compute.calls
    assert call["path"] == staged["source"]
    assert call["codec_hint"] == "alac"
    assert call["fingerprinter"] is FINGERPRINTER
    assert call["known_duration_s"] == 31.25
    assert call["low_priority"] is True


def test_an_unknown_probed_duration_is_passed_as_unknown_never_zero(db, root):
    stage_item(db, root)
    compute = FakeCompute()

    make_worker(db, root, compute=compute, probe=FakeProbe(detected(duration_s=None))).process_one()

    assert compute.calls[0]["known_duration_s"] is None


def test_the_probe_reads_the_staged_source(db, root):
    staged = stage_item(db, root)
    probe = FakeProbe()

    make_worker(db, root, probe=probe).process_one()

    [call] = probe.calls
    assert call["path"] == staged["source"]


def test_with_nothing_to_validate_a_step_is_idle_and_changes_nothing(db, root):
    staged = stage_item(db, root, state="review_ready")
    before = item_row(db, staged)
    probe = FakeProbe()

    outcome = make_worker(db, root, probe=probe).process_one()

    assert outcome == "idle"
    assert probe.calls == []
    assert item_row(db, staged) == before


def test_an_item_held_by_this_process_is_not_taken_again(db, root):
    stage_item(db, root, lease=BOOT)
    probe = FakeProbe()

    assert make_worker(db, root, probe=probe).process_one() == "idle"
    assert probe.calls == []


def test_an_item_left_by_a_dead_process_is_taken(db, root):
    staged = stage_item(db, root, lease=DEAD_BOOT)

    make_worker(db, root).process_one()

    assert item_row(db, staged)["state"] == "review_ready"


def test_items_are_validated_in_the_order_their_bytes_arrived(db, root):
    later = stage_item(db, root, content=b"later", progress_at=2000)
    first = stage_item(db, root, content=b"first", progress_at=1000)
    probe = FakeProbe()
    worker = make_worker(db, root, probe=probe)

    worker.process_one()
    assert (item_row(db, first)["state"], item_row(db, later)["state"]) == ("review_ready", "validating")
    worker.process_one()
    assert [c["path"] for c in probe.calls] == [first["source"], later["source"]]


def test_the_claim_stamps_this_process_while_the_item_is_worked_on(db, root):
    staged = stage_item(db, root)
    seen = []
    probe = FakeProbe()
    probe.mid = lambda: seen.append(sql(
        db, "SELECT state, lease_boot_id FROM upload_items WHERE item_uuid = ?", (staged["item_uuid"],)
    ))

    make_worker(db, root, probe=probe).process_one()

    assert seen == [[{"state": "validating", "lease_boot_id": BOOT}]]


def test_an_item_of_another_owner_is_validated_as_that_owners(db, root):
    from tests.owned_database import add_test_user

    sam = add_test_user(db, "sam")
    staged = stage_item(db, root, owner_id=sam)

    make_worker(db, root).process_one()

    assert item_row(db, staged)["state"] == "review_ready"
    assert identity_row(db, staged)["owner_id"] == sam
