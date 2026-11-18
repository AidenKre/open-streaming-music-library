"""7A.2c S4 (spec §5 "Duplicate check (SC-25)", rules; SC-25 per owner; plan
D14, D34; exit proof): what the stored report says.

- the same audio retagged is an exact match;
- a pair of staged items is reported once, on the later-validated item, and
  the earlier report is never rewritten;
- two users' identical staged items (and tracks) never pair;
- without the fingerprint tool the layer reads ``unavailable`` and the item is
  still reviewable;
- partial library coverage is counted, never hidden.
"""

import pytest

from app.config import Settings
from app.services.audio_identity import ExactAudioHash, FingerprintUnavailable
from app.services.duplicate_detection import MatcherParams
from tests.fingerprint_fixtures import fp_track, noisy, pin_matcher_settings, random_print
from tests.identity_worker_fixtures import add_track, sql
from tests.owned_database import add_test_user
from tests.upload_validation_fixtures import (
    BOOT,
    FINGERPRINTER,
    FakeCompute,
    exact_for,
    item_row,
    make_worker,
    print_of,
    report_of,
    stage_item,
)

DIGEST = "cd" * 32


@pytest.fixture(autouse=True)
def _explicit_matcher_settings(monkeypatch):
    # U09-B-06: these tests prove matching at stated settings, not at the defaults.
    pin_matcher_settings(monkeypatch)


@pytest.fixture
def root(tmp_path):
    path = tmp_path / "music" / ".uploads"
    path.mkdir(parents=True)
    return path


def _library_track(db, *, owner_id=None, digest=DIGEST, state="current"):
    return add_track(db, f"/m/{digest[:6]}-{state}.flac", owner_id=owner_id, identity={
        "exact_state": state, "exact_kind": "pcm_sha256" if state in ("current", "pending") else None,
        "exact_digest": digest if state in ("current", "pending") else None,
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
        "fp_state": "unavailable", "match_state": "current",
    })


def _refs(report):
    return [(m["ref"], m["id"], m["kind"], m["band"]) for m in report["matches"]]


def test_the_same_audio_retagged_is_an_exact_match_with_a_library_track(db, root):
    track = _library_track(db)
    staged = stage_item(db, root, content=b"retagged bytes")
    compute = FakeCompute()
    # Different file bytes (new tags), same decoded audio.
    compute.exact[b"retagged bytes"] = ExactAudioHash("pcm_sha256", DIGEST, 44100, 2, 16)

    make_worker(db, root, compute=compute).process_one()

    assert _refs(report_of(db, staged)) == [("library_track", track, "exact", "exact")]
    assert item_row(db, staged)["state"] == "review_ready"


def test_a_staged_pair_is_reported_once_on_the_later_item(db, root):
    first = stage_item(db, root, content=b"same audio", filename="other.flac", progress_at=1000)
    later = stage_item(db, root, content=b"same audio", progress_at=2000)
    worker = make_worker(db, root)

    worker.process_one()
    earlier_report = report_of(db, first)
    worker.process_one()

    assert _refs(earlier_report) == []
    assert _refs(report_of(db, later)) == [("staged_item", first["item_uuid"], "exact", "exact")]
    assert report_of(db, first) == earlier_report  # never rewritten


@pytest.mark.parametrize("state", ["review_ready", "committing", "duplicate_conflict"])
def test_every_open_staged_item_of_the_owner_is_compared(db, root, state):
    other = stage_item(db, root, content=b"same audio", progress_at=1000)
    make_worker(db, root).process_one()
    sql(db, "UPDATE upload_items SET state = ? WHERE item_uuid = ?", (state, other["item_uuid"]))
    later = stage_item(db, root, content=b"same audio", progress_at=2000)

    make_worker(db, root).process_one()

    assert _refs(report_of(db, later)) == [("staged_item", other["item_uuid"], "exact", "exact")]


@pytest.mark.parametrize("state", ["cancelled", "expired", "imported", "duplicate", "failed", "validating"])
def test_a_closed_or_unfinished_staged_item_is_never_compared(db, root, state):
    other = stage_item(db, root, content=b"same audio", progress_at=1000)
    make_worker(db, root).process_one()
    extra = {"imported": ", result_track_uuid = 'x', result_revision = 1",
             "duplicate": ", result_track_uuid = 'x', duplicate_kind = 'exact'",
             "failed": ", error_code = 'boom'",
             # being re-checked by this very worker (a re-check after a retry)
             "validating": f", lease_boot_id = '{BOOT}'"}.get(state, "")
    sql(db, f"UPDATE upload_items SET state = ?{extra} WHERE item_uuid = ?", (state, other["item_uuid"]))
    later = stage_item(db, root, content=b"same audio", progress_at=2000)

    make_worker(db, root).process_one()

    assert _refs(report_of(db, later)) == []


def test_two_users_identical_staged_items_and_tracks_never_pair(db, root):
    sam = add_test_user(db, "sam")
    alex = add_test_user(db, "alex")
    compute = FakeCompute()
    worker = make_worker(db, root, compute=compute)
    _library_track(db, owner_id=sam, digest=exact_for(b"same audio").digest)
    sams = stage_item(db, root, owner_id=sam, content=b"same audio", progress_at=1000)
    worker.process_one()
    alexs = stage_item(db, root, owner_id=alex, content=b"same audio", progress_at=2000)

    worker.process_one()

    assert len(_refs(report_of(db, sams))) == 1  # sam's own track: the control
    assert _refs(report_of(db, alexs)) == []
    assert report_of(db, alexs)["exact"]["library_pending"] == 0  # sam's library is not even counted


def test_without_the_fingerprint_tool_the_layer_is_unavailable_and_the_item_reviewable(db, root):
    staged = stage_item(db, root)

    make_worker(db, root, fingerprinter=None).process_one()

    report = report_of(db, staged)
    assert report["fingerprint"]["subject_state"] == "unavailable"
    assert item_row(db, staged)["state"] == "review_ready"
    assert item_row(db, staged)["error_code"] is None


def test_a_print_that_failed_is_reported_failed_and_the_item_stays_reviewable(db, root):
    staged = stage_item(db, root, content=b"a")
    compute = FakeCompute()
    compute.prints[b"a"] = FingerprintUnavailable("timeout")

    make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER).process_one()

    assert report_of(db, staged)["fingerprint"]["subject_state"] == "failed"
    assert item_row(db, staged)["state"] == "review_ready"


def test_a_failed_exact_hash_is_reported_failed_and_the_item_stays_reviewable(db, root):
    staged = stage_item(db, root, content=b"a")
    compute = FakeCompute()
    from app.services.audio_identity import ExactUnavailable

    compute.exact[b"a"] = ExactUnavailable("failed", "decode_error")

    make_worker(db, root, compute=compute).process_one()

    assert report_of(db, staged)["exact"]["subject_state"] == "failed"
    assert report_of(db, staged)["matches"] == []
    assert item_row(db, staged)["state"] == "review_ready"


def test_partial_library_coverage_is_counted(db, root):
    _library_track(db, digest="01" * 32, state="pending")
    _library_track(db, digest="02" * 32, state="pending")
    _library_track(db, state="failed")
    _library_track(db, state="unsupported")
    add_track(db, "/m/no-identity.flac", identity={"_none": True})
    staged = stage_item(db, root)

    make_worker(db, root).process_one()

    assert report_of(db, staged)["exact"] == {
        "subject_state": "current", "library_pending": 3, "library_failed": 1, "library_not_comparable": 1,
    }


def test_a_fingerprint_match_with_a_library_track_is_reported_with_its_band(db, root):
    items = random_print(5)
    track = fp_track(db, "song", items=noisy(items, 1), duration=200.0)
    staged = stage_item(db, root, content=b"a")
    compute = FakeCompute()
    compute.prints[b"a"] = print_of(items, 200.0)

    make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER).process_one()

    [match] = report_of(db, staged)["matches"]
    assert (match["ref"], match["id"], match["kind"], match["band"]) == ("library_track", track, "fingerprint", "strong")
    assert match["score"] == pytest.approx(1 - 1 / 32)


def test_a_library_copy_with_a_longer_lead_in_is_reported(db, root):
    # s7-fingerprint-search: the library copy has 30 extra items of lead-in
    # (30 * 1365 / 11025 s = 3.71 s longer, inside the window, beyond +-24 items).
    items = random_print(6)
    track = fp_track(db, "song", items=random_print(80, 30) + items, duration=200.0 + 30 * 1365 / 11025)
    staged = stage_item(db, root, content=b"a")
    compute = FakeCompute()
    compute.prints[b"a"] = print_of(items, 200.0)

    make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER).process_one()

    [match] = report_of(db, staged)["matches"]
    assert (match["ref"], match["id"], match["kind"], match["band"]) == ("library_track", track, "fingerprint", "strong")
    assert match["score"] == pytest.approx(1.0)


def test_at_the_defaults_a_library_copy_5_s_longer_by_its_lead_in_is_reported(db, root, monkeypatch):
    # s7-fingerprint-search round 2: window max(7 s, 2%); 41 items = 5.08 s of lead-in.
    pin_matcher_settings(monkeypatch, MatcherParams.from_settings(Settings(_env_file=None)))
    items = random_print(7)
    track = fp_track(db, "song", items=random_print(82, 41) + items, duration=200.0 + 41 * 1365 / 11025)
    staged = stage_item(db, root, content=b"a")
    compute = FakeCompute()
    compute.prints[b"a"] = print_of(items, 200.0)

    make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER).process_one()

    [match] = report_of(db, staged)["matches"]
    assert (match["ref"], match["id"], match["kind"], match["band"]) == ("library_track", track, "fingerprint", "strong")


def test_a_staged_fingerprint_pair_is_reported_on_the_later_item(db, root):
    items = random_print(9)
    compute = FakeCompute()
    compute.prints[b"one"] = print_of(items, 180.0)
    compute.prints[b"two"] = print_of(noisy(items, 2), 181.0)
    first = stage_item(db, root, content=b"one", progress_at=1000)
    later = stage_item(db, root, content=b"two", progress_at=2000)
    worker = make_worker(db, root, compute=compute, fingerprinter=FINGERPRINTER)

    worker.process_one()
    worker.process_one()

    assert report_of(db, first)["matches"] == []
    assert [(m["ref"], m["id"], m["kind"]) for m in report_of(db, later)["matches"]] == [
        ("staged_item", first["item_uuid"], "fingerprint"),
    ]
