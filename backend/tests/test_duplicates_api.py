"""Phase 8A.4: the duplicates API (spec §3 "Possible duplicates needs no
switch", §4 duplicates rows; SC-25 with DEV-6.5-02; SC-16l; SC-22; review
8-U10).

Pairs are planted with plain SQL for the app's master admin (the client's
user); expected orders and shapes are written out here, never derived from
the production code.
"""

import base64
import json
from types import SimpleNamespace

import pytest

from app.services.audio_identity import KIND_PCM
from tests.identity_worker_fakes import FakeCompute, bytes_digest, make_worker
from tests.identity_worker_fixtures import add_track, identity, set_identity, sql
from tests.owned_database import add_test_user
from tests.pending_deletion import mark_pending_deletion

BANDS = {0: "exact", 1: "strong", 2: "possible"}


class Lib:
    """The admin's tracks and pairs in the running app's database."""

    def __init__(self, client, tmp_path):
        self.client = client
        self.db = client.app.state.database
        self.owner = client.app.state.admin_user_id
        self.tmp_path = tmp_path
        self.count = 0

    def track(self, *, on_disk=False, owner=None):
        self.count += 1
        # Fix round 1 (8-R1-29): masters live under the owner's root, as in
        # production; master_present now uses the worker's path check.
        folder = self.db.get_user(owner or self.owner)["library_folder"]
        path = self.tmp_path / "music" / folder / f"t{self.count}.flac"
        if on_disk:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"not really flac")
        return add_track(self.db, path, owner_id=owner or self.owner)

    def plant(self, a, b, *, kind="exact", band_rank=0, score=1.0, status="open", owner=None,
              detected_at=100):
        ua, ub = sorted((a, b))
        sql(self.db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, "
                     "band_rank, sort_score, matcher_version, detected_at, status) "
                     "VALUES (?, ?, ?, ?, ?, ?, 'm', ?, ?)",
            (owner or self.owner, ua, ub, kind, band_rank, score, detected_at, status))
        return (band_rank, score, ua, ub)


@pytest.fixture
def lib(app_client, tmp_path):
    return Lib(app_client, tmp_path)


def all_pairs(uuids):
    return [(a, b) for i, a in enumerate(uuids) for b in uuids[i + 1:]]


def expected_order(keys):
    return sorted(keys, key=lambda k: (k[0], -k[1], k[2], k[3]))


def wire_key(pair):
    """The keyset position of a listed pair, rebuilt from its public fields."""
    rank = {v: k for k, v in BANDS.items()}[pair["band"]]
    return (rank, 1.0 if pair["score"] is None else pair["score"], pair["uuid_a"], pair["uuid_b"])


def cursor(*key) -> str:
    raw = json.dumps(list(key), separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def decode(text: str):
    return json.loads(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)))


def traverse(client, limit, status=None):
    pages, after = [], None
    for _ in range(1000):
        params = {"limit": limit}
        if status is not None:
            params["status"] = status
        if after is not None:
            params["after"] = after
        r = client.get("/tracks/duplicates", params=params)
        assert r.status_code == 200, r.text
        body = r.json()
        assert set(body) == {"pairs", "next_after"}
        pages.append(body["pairs"])
        after = body["next_after"]
        if after is None:
            return pages
    raise AssertionError("the traversal never ended")


def planted_tiers(lib):
    """More than 25 exact pairs at sort_score 1.0, fingerprint pairs tied at
    0.95 and 0.9 in band 1 and at 0.7 in band 2."""
    pairs = all_pairs([lib.track() for _ in range(12)])  # 66 pairs
    keys = [lib.plant(a, b) for a, b in pairs[:30]]
    keys += [lib.plant(a, b, kind="fingerprint", band_rank=1, score=0.95 if i % 2 else 0.9)
             for i, (a, b) in enumerate(pairs[30:50])]
    keys += [lib.plant(a, b, kind="fingerprint", band_rank=2, score=0.7) for a, b in pairs[50:]]
    return keys


# --- GET /tracks/duplicates ---------------------------------------------------------------------


@pytest.mark.parametrize("limit", [7, 25, 100])
def test_tied_pairs_are_traversed_completely_over_http(lib, limit):
    keys = planted_tiers(lib)

    pages = traverse(lib.client, limit)

    seen = [wire_key(p) for page in pages for p in page]
    assert seen == expected_order(keys)
    assert all(len(page) == limit for page in pages[:-1])
    assert len(pages[-1]) <= limit


def test_the_default_page_is_25_open_pairs_with_a_next_cursor_of_the_keyset_only(lib):
    keys = expected_order(planted_tiers(lib))

    body = lib.client.get("/tracks/duplicates").json()

    assert [wire_key(p) for p in body["pairs"]] == keys[:25]
    band, score, a, b = decode(body["next_after"])
    assert (band, score, a, b) == keys[24]
    assert type(band) is int and type(score) is float


def test_exact_and_fingerprint_rows_report_kind_band_and_score_as_stored(lib):
    t = [lib.track() for _ in range(4)]
    lib.plant(t[0], t[1], detected_at=1700000001)
    lib.plant(t[0], t[2], kind="fingerprint", band_rank=1, score=0.93, detected_at=1700000002)
    lib.plant(t[0], t[3], kind="fingerprint", band_rank=2, score=0.61, detected_at=1700000003)

    pairs = lib.client.get("/tracks/duplicates").json()["pairs"]

    assert [(p["kind"], p["band"], p["score"], p["status"], p["detected_at"]) for p in pairs] == [
        ("exact", "exact", None, "open", 1700000001),
        ("fingerprint", "strong", 0.93, "open", 1700000002),
        ("fingerprint", "possible", 0.61, "open", 1700000003),
    ]


def test_a_pair_carries_both_track_summaries_with_unknowns_null_and_no_path(lib):
    present = lib.track(on_disk=True)
    missing = lib.track()
    sql(lib.db, "UPDATE trackmetadata SET title = 'Lucky', artist = 'Radiohead', "
                "album = 'OK Computer', codec = 'flac', bitrate_kbps = 912.5, sample_rate_hz = 44100, "
                "channels = 2, duration = 259.4 WHERE uuid_id = ?", (present,))
    sql(lib.db, "UPDATE trackmetadata SET codec = NULL WHERE uuid_id = ?", (missing,))
    sql(lib.db, "UPDATE tracks SET revision = 41, created_at = 1700000000 WHERE uuid_id = ?", (present,))
    sql(lib.db, "UPDATE tracks SET revision = 42, created_at = 1700000500 WHERE uuid_id = ?", (missing,))
    lib.plant(present, missing)

    r = lib.client.get("/tracks/duplicates")

    [pair] = r.json()["pairs"]
    assert set(pair) == {"uuid_a", "uuid_b", "kind", "band", "score", "status", "detected_at",
                         "track_a", "track_b"}
    by_uuid = {pair["track_a"]["uuid_id"]: pair["track_a"], pair["track_b"]["uuid_id"]: pair["track_b"]}
    assert pair["track_a"]["uuid_id"] == pair["uuid_a"] < pair["uuid_b"] == pair["track_b"]["uuid_id"]
    assert by_uuid[present] == {
        "uuid_id": present, "revision": 41, "title": "Lucky", "artist": "Radiohead",
        "album": "OK Computer", "codec": "flac", "bitrate_kbps": 912.5, "sample_rate_hz": 44100,
        "channels": 2, "duration_s": 259.4, "added_at": 1700000000, "master_present": True}
    assert by_uuid[missing] == {
        "uuid_id": missing, "revision": 42, "title": None, "artist": None, "album": None,
        "codec": None, "bitrate_kbps": None, "sample_rate_hz": None, "channels": None,
        "duration_s": None, "added_at": 1700000500, "master_present": False}
    assert str(lib.tmp_path) not in r.text and "file_path" not in r.text


# Sign-off OPEN-A-11 alternative 1 (with OPEN-8-07 row 2, DEV-8-17 item 18):
# ``master_present`` is three-valued. A path the server refuses to judge (a
# symlink on the way, a folder where the file should be, a path outside the
# owner's root, a library root that is not there) is unknown (null), never
# "missing": the same answer as the deletion preview's ``master_exists``.


def _copies(lib):
    [pair] = lib.client.get("/tracks/duplicates").json()["pairs"]
    return {pair["track_a"]["uuid_id"]: pair["track_a"], pair["track_b"]["uuid_id"]: pair["track_b"]}


def test_a_symlinked_master_is_unknown(lib):
    """8-R1-29 / U13 B-02: one master check for the preview, this list and the
    worker: a symlink to a file outside the root is not judged."""
    outside = lib.tmp_path / "elsewhere" / "real.flac"
    outside.parent.mkdir(parents=True)
    outside.write_bytes(b"real bytes")
    linked = lib.track()
    other = lib.track(on_disk=True)
    path = lib.tmp_path / "music" / lib.db.get_user(lib.owner)["library_folder"] / "t1.flac"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(outside)
    lib.plant(linked, other)

    by_uuid = _copies(lib)

    assert by_uuid[linked]["master_present"] is None
    assert by_uuid[other]["master_present"] is True


def _root(lib):
    return lib.tmp_path / "music" / lib.db.get_user(lib.owner)["library_folder"]


def test_a_master_under_a_symlinked_folder_is_unknown(lib):
    """Review r2 8-R2-05(b): a symlink in a parent folder counts too."""
    outside = lib.tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "real.flac").write_bytes(b"real bytes")
    _root(lib).mkdir(parents=True, exist_ok=True)
    (_root(lib) / "Sub").symlink_to(outside, target_is_directory=True)
    linked = add_track(lib.db, _root(lib) / "Sub" / "real.flac", owner_id=lib.owner)
    assert (_root(lib) / "Sub" / "real.flac").exists()
    other = lib.track(on_disk=True)
    lib.plant(linked, other)

    by_uuid = _copies(lib)

    assert by_uuid[linked]["master_present"] is None
    assert by_uuid[other]["master_present"] is True


def test_a_directory_where_the_master_should_be_is_unknown(lib):
    folder = lib.track()  # t1.flac
    (_root(lib) / "t1.flac").mkdir(parents=True)
    other = lib.track(on_disk=True)
    lib.plant(folder, other)

    by_uuid = _copies(lib)

    assert by_uuid[folder]["master_present"] is None
    assert by_uuid[other]["master_present"] is True


def test_a_master_outside_the_owners_root_is_unknown(lib):
    stray = lib.tmp_path / "elsewhere" / "stray.flac"
    stray.parent.mkdir(parents=True)
    stray.write_bytes(b"stray bytes")
    outside = add_track(lib.db, stray, owner_id=lib.owner)
    other = lib.track(on_disk=True)
    lib.plant(outside, other)

    by_uuid = _copies(lib)

    assert by_uuid[outside]["master_present"] is None
    assert by_uuid[other]["master_present"] is True


def test_a_library_root_that_is_not_there_makes_every_copy_unknown(lib):
    """An unmounted library volume: the files may be intact, so no copy is
    reported missing (the case the audit found: every pair said missing)."""
    a, b = lib.track(), lib.track()
    lib.plant(a, b)
    assert not _root(lib).exists()

    by_uuid = _copies(lib)

    assert (by_uuid[a]["master_present"], by_uuid[b]["master_present"]) == (None, None)


def test_a_library_root_that_is_a_file_makes_every_copy_unknown(lib):
    a, b = lib.track(), lib.track()
    lib.plant(a, b)
    _root(lib).parent.mkdir(parents=True, exist_ok=True)
    _root(lib).write_bytes(b"not a folder")

    by_uuid = _copies(lib)

    assert (by_uuid[a]["master_present"], by_uuid[b]["master_present"]) == (None, None)


def test_a_master_really_gone_from_a_present_root_is_missing(lib):
    gone = lib.track()
    other = lib.track(on_disk=True)  # the root exists
    lib.plant(gone, other)

    by_uuid = _copies(lib)

    assert by_uuid[gone]["master_present"] is False
    assert by_uuid[other]["master_present"] is True


def test_the_status_filter_lists_dismissed_pairs(lib):
    a, b, c = (lib.track() for _ in range(3))
    lib.plant(a, b)
    dismissed = lib.plant(a, c, status="dismissed")

    pages = traverse(lib.client, 25, status="dismissed")

    assert [wire_key(p) for page in pages for p in page] == [dismissed]
    assert pages[0][0]["status"] == "dismissed"


def test_a_pair_with_a_member_pending_deletion_is_not_listed(lib):
    a, b, c = (lib.track() for _ in range(3))
    lib.plant(a, b)
    kept = lib.plant(a, c)

    mark_pending_deletion(lib.db.context.database_path, b)

    assert [wire_key(p) for p in lib.client.get("/tracks/duplicates").json()["pairs"]] == [kept]


def test_the_list_works_with_the_delete_switch_off(lib):
    assert lib.client.app.state.settings.library_delete_enabled is False
    key = lib.plant(lib.track(), lib.track())

    r = lib.client.get("/tracks/duplicates")

    assert r.status_code == 200, r.text
    assert [wire_key(p) for p in r.json()["pairs"]] == [key]


def test_the_largest_cursor_is_accepted(lib):
    lib.plant(lib.track(), lib.track(), kind="fingerprint", band_rank=2, score=0.7)
    largest = cursor(2, -1.7976931348623157e308, "ffffffff-ffff-ffff-ffff-ffffffffffff",
                     "ffffffff-ffff-ffff-ffff-ffffffffffff")

    r = lib.client.get("/tracks/duplicates", params={"after": largest, "limit": 100})

    assert r.status_code == 200, r.text
    assert r.json() == {"pairs": [], "next_after": None}


@pytest.mark.parametrize("after", [
    "not base64!",
    cursor(0, 1.0, "00000000-0000-4000-8000-000000000001"),  # too short
    cursor(0.0, 1.0, "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"),
    cursor(True, 1.0, "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"),
    cursor(0, "1.0", "00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"),
    cursor(0, 1.0, "not-a-uuid", "00000000-0000-4000-8000-000000000002"),
    base64.urlsafe_b64encode(b'[0,Infinity,"00000000-0000-4000-8000-000000000001",'
                             b'"00000000-0000-4000-8000-000000000002"]').decode(),
    base64.urlsafe_b64encode(b'[0,NaN,"00000000-0000-4000-8000-000000000001",'
                             b'"00000000-0000-4000-8000-000000000002"]').decode(),
    cursor(0, 1.0, "00000000-0000-4000-8000-000000000001", "x" * 600),
])
def test_a_malformed_cursor_is_422_invalid_cursor(lib, after):
    r = lib.client.get("/tracks/duplicates", params={"after": after})

    assert r.status_code == 422, r.text
    assert r.json()["detail"]["error"] == "invalid_cursor"


@pytest.mark.parametrize("params", [{"status": "deleted"}, {"limit": 0}, {"limit": 101}])
def test_a_bad_status_or_limit_is_422(lib, params):
    assert lib.client.get("/tracks/duplicates", params=params).status_code == 422


# --- GET /tracks/duplicates/summary -------------------------------------------------------------


def summary(lib):
    r = lib.client.get("/tracks/duplicates/summary")
    assert r.status_code == 200, r.text
    return r.json()


def test_the_summary_counts_pairs_per_band_and_status_with_real_zeros(lib):
    t = [lib.track() for _ in range(4)]
    lib.plant(t[0], t[1])
    lib.plant(t[0], t[2], status="dismissed")
    lib.plant(t[0], t[3], kind="fingerprint", band_rank=2, score=0.7)

    assert summary(lib)["bands"] == {
        "exact": {"open": 1, "dismissed": 1},
        "strong": {"open": 0, "dismissed": 0},
        "possible": {"open": 1, "dismissed": 0},
    }


def test_without_a_fingerprinter_the_summary_says_null_and_reports_coverage_as_stored(lib):
    assert lib.client.app.state.fingerprinter is None  # AUDIO_FINGERPRINT_BACKEND=off
    lib.track()  # pending exact, fingerprint unavailable, match pending
    lib.track()
    add_track(lib.db, lib.tmp_path / "printed.flac", owner_id=lib.owner, identity={
        "exact_state": "current", "fp_state": "current", "match_state": "current"})
    add_track(lib.db, lib.tmp_path / "never-checked.flac", owner_id=lib.owner,
              identity={"_none": True})  # no identity row: unknown, so pending

    body = summary(lib)

    assert body["fingerprinter"] is None
    assert body["coverage"] == {
        "exact": {"pending": 3, "current": 1, "failed": 0, "unsupported": 0},
        "fingerprint": {"pending": 1, "current": 1, "unavailable": 2, "too_short": 0,
                        "low_information": 0, "failed": 0},
        "match": {"pending": 3, "current": 1},
    }
    assert set(body) == {"bands", "coverage", "fingerprinter"}


def test_with_a_fingerprinter_the_summary_names_it(lib):
    lib.client.app.state.fingerprinter = SimpleNamespace(name="fpcalc")

    assert summary(lib)["fingerprinter"] == "fpcalc"


def test_the_summary_leaves_out_pending_deletion_tracks_and_other_users(lib):
    sam = add_test_user(lib.db, "sam")
    s1, s2 = lib.track(owner=sam), lib.track(owner=sam)
    lib.plant(s1, s2, owner=sam)
    a, b, c = (lib.track() for _ in range(3))
    lib.plant(a, b)
    lib.plant(a, c, status="dismissed")

    mark_pending_deletion(lib.db.context.database_path, b)
    body = summary(lib)

    assert body["bands"]["exact"] == {"open": 0, "dismissed": 1}
    assert body["coverage"]["exact"]["pending"] == 2  # a and c; b is being deleted, sam's are not ours


def test_the_summary_works_with_the_delete_switch_off(lib):
    assert lib.client.app.state.settings.library_delete_enabled is False

    assert summary(lib)["bands"]["exact"] == {"open": 0, "dismissed": 0}


# --- POST /tracks/duplicates/dismiss and /restore -----------------------------------------------

UNKNOWN_A = "00000000-0000-4000-8000-0000000000a1"
UNKNOWN_B = "00000000-0000-4000-8000-0000000000b2"


def stored(lib, a, b):
    ua, ub = sorted((a, b))
    [row] = sql(lib.db, "SELECT status, status_changed_at FROM track_duplicate_candidates "
                        "WHERE uuid_a = ? AND uuid_b = ?", (ua, ub))
    return row


def post(lib, action, a, b):
    return lib.client.post(f"/tracks/duplicates/{action}", json={"uuid_a": a, "uuid_b": b})


def test_dismiss_takes_the_pair_in_reverse_order_and_is_idempotent(lib):
    a, b = lib.track(), lib.track()
    lib.plant(a, b)
    lo, hi = sorted((a, b))

    first = post(lib, "dismiss", hi, lo)

    assert first.status_code == 200, first.text
    assert first.json() == {"uuid_a": lo, "uuid_b": hi, "status": "dismissed"}
    changed = stored(lib, a, b)
    assert changed["status"] == "dismissed" and changed["status_changed_at"] is not None
    # Back-date the change: a rewrite in the same second would keep the time.
    sql(lib.db, "UPDATE track_duplicate_candidates SET status_changed_at = 1 "
                "WHERE uuid_a = ? AND uuid_b = ?", (lo, hi))
    changed = stored(lib, a, b)
    again = post(lib, "dismiss", lo, hi)
    assert (again.status_code, again.json()) == (200, first.json())
    assert stored(lib, a, b) == changed  # nothing rewritten
    listed = lib.client.get("/tracks/duplicates", params={"status": "dismissed"}).json()["pairs"]
    assert [(p["uuid_a"], p["uuid_b"]) for p in listed] == [(lo, hi)]
    assert lib.client.get("/tracks/duplicates").json()["pairs"] == []


def test_restore_reopens_a_dismissed_pair_and_is_idempotent(lib):
    a, b = lib.track(), lib.track()
    lib.plant(a, b, status="dismissed")
    lo, hi = sorted((a, b))

    for _ in range(2):
        r = post(lib, "restore", hi, lo)
        assert (r.status_code, r.json()) == (200, {"uuid_a": lo, "uuid_b": hi, "status": "open"})
        assert stored(lib, a, b)["status"] == "open"


# --- sign-off OPEN-8-02: Restore re-checks the pair ---------------------------------------------
# A pair marked "Not duplicates" is never matched again. Restore sends both of
# its tracks back to matching in the same transaction and wakes the identity
# worker, so a pair whose tracks no longer match leaves the list (or takes its
# true type) once the worker has run.


def settled(lib, name, content):
    """A track on disk whose exact identity is current (digest of its bytes,
    as the fake hasher computes it) and whose matching is done."""
    lib.count += 1
    path = _root(lib) / f"{name}.flac"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return add_track(lib.db, path, owner_id=lib.owner, identity={
        "exact_state": "current", "exact_kind": KIND_PCM, "exact_digest": bytes_digest(path),
        "sample_rate_hz": 44100, "channels": 2, "bits_per_sample": 16,
        "fp_state": "unavailable", "match_state": "current"})


def match_states(lib, *uuids):
    return [identity(lib.db, u)["match_state"] for u in uuids]


def candidate(lib, a, b):
    ua, ub = sorted((a, b))
    rows = sql(lib.db, "SELECT kind, band_rank, status FROM track_duplicate_candidates "
                       "WHERE uuid_a = ? AND uuid_b = ?", (ua, ub))
    return rows[0] if rows else None


def run_identity_worker(lib):
    worker = make_worker(lib.db, compute=FakeCompute())
    for _ in range(50):
        if worker.process_one().outcome == "idle":
            return
    raise AssertionError("the identity worker never went idle")


def woken(lib) -> bool:
    return lib.client.app.state.identity_wakeup.wait(0)


def test_a_pair_restored_after_one_track_changed_is_removed_once_the_worker_has_run(lib):
    a = settled(lib, "a", b"the same audio")
    b = settled(lib, "b", b"the same audio")
    lib.plant(a, b, status="dismissed")
    # A conversion changes b's audio while the pair is dismissed: the worker
    # hashes b again and keeps the dismissed pair with its old type.
    (_root(lib) / "b.flac").write_bytes(b"converted audio")
    assert lib.db.mark_audio_identity_stale(b, "conversion", owner_id=lib.owner)
    run_identity_worker(lib)
    assert candidate(lib, a, b) == {"kind": "exact", "band_rank": 0, "status": "dismissed"}
    assert match_states(lib, a, b) == ["current", "current"]
    woken(lib)  # clear earlier signals

    r = post(lib, "restore", a, b)

    assert r.status_code == 200, r.text
    assert match_states(lib, a, b) == ["pending", "pending"]
    assert woken(lib), "restore wakes the identity worker after its commit"
    run_identity_worker(lib)
    assert candidate(lib, a, b) is None
    assert lib.client.get("/tracks/duplicates").json()["pairs"] == []


def test_a_restored_pair_that_still_matches_keeps_its_type_after_the_worker_has_run(lib):
    a = settled(lib, "a", b"the same audio")
    b = settled(lib, "b", b"the same audio")
    lib.plant(a, b, status="dismissed")

    assert post(lib, "restore", a, b).status_code == 200
    assert match_states(lib, a, b) == ["pending", "pending"]
    run_identity_worker(lib)

    assert candidate(lib, a, b) == {"kind": "exact", "band_rank": 0, "status": "open"}
    [pair] = lib.client.get("/tracks/duplicates").json()["pairs"]
    assert (pair["kind"], pair["band"], pair["status"]) == ("exact", "exact", "open")


@pytest.mark.parametrize("kind, band_rank, layer", [
    ("exact", 0, {"exact_state": "unsupported", "exact_digest": None}),
    ("fingerprint", 1, {"fp_state": "too_short"}),
    ("fingerprint", 2, {"fp_state": "low_information"}),
], ids=["exact unsupported", "print too short", "print low information"])
def test_a_restored_pair_whose_track_is_no_longer_comparable_is_removed(lib, kind, band_rank, layer):
    """Review r1: the not-comparable rule never touches a dismissed pair, so a
    track that became not comparable while its pair was dismissed must lose
    the restored pair at its next match run."""
    a = settled(lib, "a", b"the same audio")
    # A print pair is between two different encodings; an exact pair between equal audio.
    b = settled(lib, "b", b"the same audio" if kind == "exact" else b"another encoding")
    lib.plant(a, b, kind=kind, band_rank=band_rank, score=1.0 if kind == "exact" else 0.9,
              status="dismissed")
    set_identity(lib.db, b, **layer)

    assert post(lib, "restore", a, b).status_code == 200
    run_identity_worker(lib)

    assert candidate(lib, a, b) is None


def test_only_a_restore_that_reopens_the_pair_sends_it_back_to_matching(lib):
    a = settled(lib, "a", b"x")
    b = settled(lib, "b", b"x")
    lib.plant(a, b)  # already open
    woken(lib)

    assert post(lib, "restore", a, b).status_code == 200  # no change
    assert match_states(lib, a, b) == ["current", "current"]
    woken(lib)  # a spare wake-up after a restore is harmless: nothing is pending

    assert post(lib, "dismiss", a, b).status_code == 200  # dismissing never re-matches
    assert match_states(lib, a, b) == ["current", "current"]
    assert not woken(lib)


def test_restoring_another_users_pair_changes_none_of_their_matching(lib):
    sam = add_test_user(lib.db, "sam")
    s1 = add_track(lib.db, lib.tmp_path / "s1.flac", owner_id=sam,
                   identity={"exact_state": "current", "match_state": "current"})
    s2 = add_track(lib.db, lib.tmp_path / "s2.flac", owner_id=sam,
                   identity={"exact_state": "current", "match_state": "current"})
    lib.plant(s1, s2, owner=sam, status="dismissed")
    woken(lib)

    assert post(lib, "restore", s1, s2).status_code == 404
    assert match_states(lib, s1, s2) == ["current", "current"]
    assert stored(lib, s1, s2)["status"] == "dismissed"
    assert not woken(lib)


def test_uppercase_uuids_name_the_same_pair(lib):
    a, b = lib.track(), lib.track()
    lib.plant(a, b)

    r = post(lib, "dismiss", a.upper(), b.upper())

    assert r.status_code == 200, r.text
    assert stored(lib, a, b)["status"] == "dismissed"


@pytest.mark.parametrize("action", ["dismiss", "restore"])
def test_a_missing_unknown_foreign_or_pending_pair_answers_one_404(lib, action):
    sam = add_test_user(lib.db, "sam")
    s1, s2 = lib.track(owner=sam), lib.track(owner=sam)
    lib.plant(s1, s2, owner=sam, status="dismissed" if action == "restore" else "open")
    a, b, c, d = (lib.track() for _ in range(4))  # a/b: no pair; c/d: pending member
    lib.plant(c, d, status="dismissed" if action == "restore" else "open")
    mark_pending_deletion(lib.db.context.database_path, d)
    before = stored(lib, s1, s2), stored(lib, c, d)

    unknown = post(lib, action, UNKNOWN_A, UNKNOWN_B)
    answers = [post(lib, action, a, b), post(lib, action, s1, s2), post(lib, action, s2, s1),
               post(lib, action, a, s1), post(lib, action, c, d), post(lib, action, a, a)]

    assert unknown.status_code == 404, unknown.text
    assert unknown.json()["detail"]["error"] == "pair_not_found"
    for r in answers:
        assert (r.status_code, r.content) == (404, unknown.content)
    assert (stored(lib, s1, s2), stored(lib, c, d)) == before


@pytest.mark.parametrize("body", [
    {"uuid_a": UNKNOWN_A},
    {"uuid_a": UNKNOWN_A, "uuid_b": "not-a-uuid"},
    {"uuid_a": UNKNOWN_A, "uuid_b": UNKNOWN_B, "status": "open"},
    [UNKNOWN_A, UNKNOWN_B],
])
def test_a_malformed_body_is_422(lib, body):
    a, b = lib.track(), lib.track()
    lib.plant(a, b)

    r = lib.client.post("/tracks/duplicates/dismiss", json=body)

    assert r.status_code == 422, r.text
    assert stored(lib, a, b)["status"] == "open"


def test_dismiss_and_restore_work_with_the_delete_switch_off(lib):
    assert lib.client.app.state.settings.library_delete_enabled is False
    a, b = lib.track(), lib.track()
    lib.plant(a, b)

    assert post(lib, "dismiss", a, b).status_code == 200
    assert post(lib, "restore", a, b).status_code == 200


# ── review r1 8-R1-11: the 64 KiB body cap and no declared body (U02d, U02e) ─


def _pair_body(lib, size: int) -> bytes:
    a, b = lib.track(), lib.track()
    lib.plant(a, b)
    body = json.dumps({"uuid_a": a, "uuid_b": b}).encode()
    return body[:-1] + b" " * (size - len(body)) + body[-1:]


@pytest.mark.parametrize("route", ["/tracks/duplicates/dismiss", "/tracks/duplicates/restore"])
def test_a_body_of_exactly_64_kib_is_read(lib, route):
    raw = _pair_body(lib, 64 * 1024)
    assert len(raw) == 64 * 1024

    r = lib.client.post(route, content=raw, headers={"Content-Type": "application/json"})

    assert r.status_code == 200, r.text


@pytest.mark.parametrize("route", ["/tracks/duplicates/dismiss", "/tracks/duplicates/restore"])
def test_a_body_over_64_kib_without_content_length_is_413_and_changes_nothing(lib, route):
    raw = _pair_body(lib, 64 * 1024 + 1)
    before = sql(lib.db, "SELECT uuid_a, uuid_b, status FROM track_duplicate_candidates")

    r = lib.client.post(route, content=iter([raw[:1000], raw[1000:]]),
                        headers={"Content-Type": "application/json"})

    assert r.status_code == 413
    assert sql(lib.db, "SELECT uuid_a, uuid_b, status FROM track_duplicate_candidates") == before


# Review r2 8-R2-05(c): the other two pairings of size and framing.


@pytest.mark.parametrize("route", ["/tracks/duplicates/dismiss", "/tracks/duplicates/restore"])
def test_a_chunked_body_of_exactly_64_kib_is_read(lib, route):
    raw = _pair_body(lib, 64 * 1024)

    r = lib.client.post(route, content=iter([raw[:1000], raw[1000:]]),
                        headers={"Content-Type": "application/json"})

    assert r.status_code == 200, r.text


@pytest.mark.parametrize("route", ["/tracks/duplicates/dismiss", "/tracks/duplicates/restore"])
def test_a_declared_length_over_64_kib_is_413_and_changes_nothing(lib, route):
    raw = _pair_body(lib, 64 * 1024 + 1)
    before = sql(lib.db, "SELECT uuid_a, uuid_b, status FROM track_duplicate_candidates")

    r = lib.client.post(route, content=raw, headers={"Content-Type": "application/json"})

    assert r.status_code == 413
    assert sql(lib.db, "SELECT uuid_a, uuid_b, status FROM track_duplicate_candidates") == before


@pytest.mark.parametrize("path", [
    "/tracks/duplicates/dismiss", "/tracks/duplicates/restore",
    "/tracks/deletions/preview", "/tracks/deletions",
])
def test_the_phase_8_posts_declare_no_pydantic_body_parameter(lib, path):
    [route] = [r for r in lib.client.app.routes
               if getattr(r, "path", None) == path and "POST" in getattr(r, "methods", ())]
    assert route.dependant.body_params == []
