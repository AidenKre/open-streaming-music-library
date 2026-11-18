"""Phase 6.5B.2b: the worker's matching step uses the fingerprint layer (spec §6.4
"Matching"; review 6.5-U09/U10; live cases L03 fingerprint half and L10, here at
unit level).

Tracks get different exact digests (different bytes) and stored synthetic
prints, so any pair can only come from the fingerprint layer. A step matches
the subject's stored print against its owner's library and stores every
fingerprint match with its band (1 strong, 2 possible) and score.
"""

import pytest

from app.config import Settings
from app.services.audio_identity import KIND_PCM
from app.services.duplicate_detection import MatcherParams
from app.services.fingerprinter import pack_fingerprint
from tests.fingerprint_fixtures import ALGO, BASE, noisy, pin_matcher_settings, random_print
from tests.identity_worker_fakes import bytes_digest, make_worker
from tests.identity_worker_fixtures import add_track, identity, make_db, sql
from tests.owned_database import add_test_user

V1 = "matcher-v1"


@pytest.fixture(autouse=True)
def _explicit_matcher_settings(monkeypatch):
    # U09-B-06: these tests prove matching at stated settings, not at the defaults.
    pin_matcher_settings(monkeypatch)


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    root = tmp_path / "music"
    root.mkdir()
    return root


def printed(db, music, name, items=BASE, *, state="current", duration=200.0, owner_id=None):
    """A track with its own bytes and its own current exact digest, waiting
    only for matching, with a stored print in ``state`` (no blob for too_short)."""
    path = music / f"{name}.flac"
    path.write_bytes(name.encode())
    uuid_id = add_track(db, path, owner_id=owner_id,
                        identity={"exact_state": "current", "exact_kind": KIND_PCM,
                                  "exact_digest": bytes_digest(path), "sample_rate_hz": 44100,
                                  "channels": 2, "fp_state": state, "fp_algorithm": ALGO})
    if items is not None:
        sql(db, "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
                "VALUES (?, 'fpcalc', ?, ?, ?, ?)",
            (uuid_id, ALGO, duration, len(items), pack_fingerprint(items)))
    return uuid_id


def drain(worker, limit=200):
    for _ in range(limit):
        if worker.process_one().outcome == "idle":
            return
    raise AssertionError("worker never went idle")


def pairs(db):
    return {frozenset((r["uuid_a"], r["uuid_b"])): r for r in sql(db, "SELECT * FROM track_duplicate_candidates")}


def test_two_tracks_with_the_same_print_get_one_strong_fingerprint_pair(db, music):
    x = printed(db, music, "x")
    y = printed(db, music, "y")

    drain(make_worker(db, matcher_version=V1))

    [row] = pairs(db).values()
    assert {row["uuid_a"], row["uuid_b"]} == {x, y}
    assert (row["kind"], row["band_rank"], row["sort_score"], row["status"]) == ("fingerprint", 1, 1.0, "open")
    assert row["matcher_version"] == V1
    assert identity(db, x)["match_state"] == identity(db, y)["match_state"] == "current"


def test_a_possible_match_is_stored_with_its_band_and_score(db, music):
    printed(db, music, "x")
    printed(db, music, "y", noisy(BASE, 4))

    drain(make_worker(db, matcher_version=V1))

    [row] = pairs(db).values()
    assert row["band_rank"] == 2
    assert row["sort_score"] == pytest.approx(1 - 4 / 32)


def test_a_copy_with_a_longer_lead_in_is_paired_by_the_worker(db, music):
    # s7-fingerprint-search: 30 extra items of lead-in (30 * 1365 / 11025 s = 3.71 s
    # longer, inside the window) sit beyond today's +-24 items; the stored durations
    # point the search at them.
    x = printed(db, music, "x")
    y = printed(db, music, "y", random_print(79, 30) + BASE, duration=200.0 + 30 * 1365 / 11025)

    drain(make_worker(db, matcher_version=V1))

    [row] = pairs(db).values()
    assert {row["uuid_a"], row["uuid_b"]} == {x, y}
    assert (row["kind"], row["band_rank"], row["sort_score"]) == ("fingerprint", 1, 1.0)


def test_at_the_defaults_the_worker_pairs_a_copy_5_s_longer_by_its_lead_in(db, music, monkeypatch):
    # s7-fingerprint-search round 2: the default window is max(7 s, 2%). 41 items of
    # lead-in = 41 * 1365 / 11025 s = 5.08 s longer, beyond the old max(3 s, 2%).
    pin_matcher_settings(monkeypatch, MatcherParams.from_settings(Settings(_env_file=None)))
    x = printed(db, music, "x")
    y = printed(db, music, "y", random_print(81, 41) + BASE, duration=200.0 + 41 * 1365 / 11025)

    drain(make_worker(db, matcher_version=V1))

    [row] = pairs(db).values()
    assert {row["uuid_a"], row["uuid_b"]} == {x, y}
    assert (row["kind"], row["band_rank"], row["sort_score"]) == ("fingerprint", 1, 1.0)


def test_unrelated_prints_and_prints_outside_the_window_give_no_pair(db, music):
    printed(db, music, "x")
    printed(db, music, "unrelated", random_print(5))
    printed(db, music, "longer", duration=260.0)

    drain(make_worker(db, matcher_version=V1))

    assert pairs(db) == {}


def test_low_information_and_too_short_tracks_are_never_paired(db, music):
    # The same stored items as x, but classified low_information: never compared.
    printed(db, music, "x")
    printed(db, music, "drone", state="low_information")
    printed(db, music, "clip", items=None, state="too_short")

    drain(make_worker(db, matcher_version=V1))

    assert pairs(db) == {}


def test_a_null_metadata_duration_does_not_stop_a_fingerprint_match(db, music):
    # add_track leaves trackmetadata.duration NULL; the print's own duration is used.
    x = printed(db, music, "x")
    y = printed(db, music, "y", duration=201.0)
    assert sql(db, "SELECT COUNT(*) AS n FROM trackmetadata WHERE duration IS NULL")[0]["n"] == 2

    drain(make_worker(db, matcher_version=V1))

    assert set(pairs(db)) == {frozenset((x, y))}


def test_two_users_with_the_same_print_get_no_pair(db, music):
    other = add_test_user(db, "other")
    printed(db, music, "mine")
    printed(db, music, "theirs", owner_id=other)

    drain(make_worker(db, matcher_version=V1))

    assert pairs(db) == {}


def test_the_subjects_stored_print_is_read_for_its_owner_only(db, music):
    x = printed(db, music, "x", duration=201.5)
    other = add_test_user(db, "other")

    stored = db.get_identity_fingerprint(x, owner_id=db.owner_id)

    assert (stored.state, stored.backend, stored.algorithm, stored.duration_s, stored.items) == (
        "current", "fpcalc", ALGO, 201.5, BASE)
    assert db.get_identity_fingerprint(x, owner_id=other) is None
    assert db.get_identity_fingerprint("no-such-uuid", owner_id=db.owner_id) is None


def test_a_store_whose_print_state_changed_since_the_read_is_discarded(db, music):
    x = printed(db, music, "x")
    printed(db, music, "y")
    sql(db, "UPDATE track_audio_identity SET exact_state = 'unsupported'")
    row = identity(db, x)
    sql(db, "UPDATE track_audio_identity SET fp_state = 'pending' WHERE uuid_id = ?", (x,))

    stored = db.store_duplicate_candidates(
        x, generation=row["generation"], exact_state=row["exact_state"], fp_state="current",
        matches=(), matcher_version=V1, now=1, owner_id=db.owner_id,
    )

    assert stored is False
    assert identity(db, x)["match_state"] == "pending"
