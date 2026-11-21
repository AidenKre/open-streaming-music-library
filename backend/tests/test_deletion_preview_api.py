"""Piece 8A.2b S3 (spec §4 preview row and para 3, SC-16b, SC-22, SC-28 rule 4;
review 8-U02 body cap, 8-U03): ``POST /tracks/deletions/preview``.

``{targets: [{uuid_id, base_revision}]}``, 1–100 distinct UUIDs, read through a
64 KiB bounded body. Each target answers, in request order, its current
title/artist/album/revision, whether its master exists and its size, and the
flags ``unknown`` / ``already_deleted`` / ``missing_master`` / ``conflict`` /
``busy``. Another user's track or tombstone answers exactly like an unknown
UUID. The preview writes nothing and the response carries no path.
"""

import json
import sqlite3
import uuid

import pytest

from app.library import Library
from app.models import Track, TrackMetaData
from tests.owned_database import add_test_user
from tests.pending_deletion import mark_pending_deletion
from tests.track_removal import delete_track

PATH = "/tracks/deletions/preview"
UNKNOWN = "00000000-0000-4000-8000-0000000000ee"
KEYS = {
    "uuid_id", "base_revision", "revision", "title", "artist", "album",
    "master_exists", "master_size", "unknown", "already_deleted",
    "missing_master", "conflict", "busy",
}


@pytest.fixture
def client(open_app_client):
    with open_app_client(env={"LIBRARY_DELETE_ENABLED": "true"}) as client:
        yield client


@pytest.fixture
def me(client):
    return Library(client.app.state.database, client.app.state.admin_user_id)


@pytest.fixture
def sam(client):
    db = client.app.state.database
    return Library(db, add_test_user(db, "sam"))


def _root(library, tmp_path):
    """The owner's library root (MUSIC_LIBRARY_DIR is ``tmp_path / "music"``)."""
    return tmp_path / "music" / library.unbound_database.get_user(library.owner_id)["library_folder"]


def _add(library, tmp_path, title, *, content=b"0123456789", write=True):
    # Fix round 1 (8-R1-29): masters live under the owner's root, as in
    # production; the preview now judges them with the worker's path check.
    path = _root(library, tmp_path) / "masters" / f"{title}.flac"
    _root(library, tmp_path).mkdir(parents=True, exist_ok=True)  # an owner's root exists
    if write:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
    track = Track(
        file_path=path,
        metadata=TrackMetaData(title=title, artist="Radiohead", album="OK Computer",
                               codec="flac", duration=1.0),
    )
    assert library.add_track(track=track)
    return library.get_track_by_uuid(track.uuid_id)


def _preview(client, *targets):
    return client.post(PATH, json={"targets": [
        {"uuid_id": u, "base_revision": r} for u, r in targets
    ]})


def _dump(db):
    conn = sqlite3.connect(db.context.database_path)
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            " ORDER BY name")]
        return {t: conn.execute(f"SELECT * FROM {t}").fetchall() for t in tables}
    finally:
        conn.close()


def _unknown_row(uuid_id, base_revision):
    return {
        "uuid_id": uuid_id, "base_revision": base_revision, "revision": None,
        "title": None, "artist": None, "album": None,
        "master_exists": None, "master_size": None,
        "unknown": True, "already_deleted": False, "missing_master": False,
        "conflict": False, "busy": False,
    }


# ── what each target answers ────────────────────────────────────────────────

def test_a_live_track_with_its_master(client, me, tmp_path):
    track = _add(me, tmp_path, "Airbag", content=b"x" * 1234)

    response = _preview(client, (track.uuid_id, track.revision))

    assert response.status_code == 200, response.text
    assert response.json() == {"targets": [{
        "uuid_id": track.uuid_id, "base_revision": track.revision, "revision": track.revision,
        "title": "Airbag", "artist": "Radiohead", "album": "OK Computer",
        "master_exists": True, "master_size": 1234,
        "unknown": False, "already_deleted": False, "missing_master": False,
        "conflict": False, "busy": False,
    }]}


def test_a_missing_master_is_flagged_and_still_a_live_track(client, me, tmp_path):
    track = _add(me, tmp_path, "Lost", write=False)

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]

    assert (row["master_exists"], row["master_size"], row["missing_master"]) == (False, None, True)
    assert (row["unknown"], row["already_deleted"], row["title"]) == (False, False, "Lost")


def test_a_symlinked_master_is_judged_like_the_worker_judges_it(client, me, tmp_path):
    """8-R1-29 / U13 B-02: the preview uses the worker's path check, so a master
    that is a symlink to a file outside the root is neither "present" (with
    the target's size) nor "missing": the worker would refuse it."""
    outside = tmp_path / "elsewhere" / "big.flac"
    outside.parent.mkdir(parents=True)
    outside.write_bytes(b"y" * 4321)
    track = _add(me, tmp_path, "Linked", write=False)
    track.file_path.parent.mkdir(parents=True, exist_ok=True)
    track.file_path.symlink_to(outside)

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]

    assert (row["master_exists"], row["master_size"], row["missing_master"]) == (None, None, False)


def test_a_master_under_a_symlinked_folder_is_judged_like_the_worker_judges_it(
    client, me, tmp_path
):
    """Review r2 8-R2-05(b): a symlink in a parent folder, not only the final
    component, makes the master neither present nor missing."""
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "Folded.flac").write_bytes(b"y" * 4321)
    track = _add(me, tmp_path, "Folded", write=False)
    track.file_path.parent.symlink_to(outside, target_is_directory=True)  # masters/ -> elsewhere/
    assert track.file_path.exists()  # the file is reachable through the link

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]

    assert (row["master_exists"], row["master_size"], row["missing_master"]) == (None, None, False)


def test_a_directory_where_the_master_should_be_is_not_reported_present(client, me, tmp_path):
    track = _add(me, tmp_path, "Folder", write=False)
    track.file_path.mkdir(parents=True)

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]

    assert (row["master_exists"], row["master_size"], row["missing_master"]) == (None, None, False)


def test_a_master_outside_the_owners_root_is_not_reported_present(client, me, tmp_path):
    outside = tmp_path / "elsewhere" / "Stray.flac"
    outside.parent.mkdir(parents=True)
    outside.write_bytes(b"z" * 99)
    track = Track(
        file_path=outside,
        metadata=TrackMetaData(title="Stray", artist="R", album="A", codec="flac", duration=1.0),
    )
    assert me.add_track(track=track)

    [row] = _preview(client, (track.uuid_id, 1)).json()["targets"]

    assert (row["master_exists"], row["master_size"], row["missing_master"]) == (None, None, False)


def test_an_own_tombstone_is_already_deleted_with_its_revision(client, me, tmp_path):
    track = _add(me, tmp_path, "Gone")
    assert delete_track(me, track.uuid_id)
    [[tombstone_revision]] = sqlite3.connect(me.unbound_database.context.database_path).execute(
        "SELECT revision FROM track_tombstones WHERE uuid_id = ?", (track.uuid_id,)).fetchall()

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]

    assert row == {
        **_unknown_row(track.uuid_id, track.revision),
        "unknown": False, "already_deleted": True, "revision": tombstone_revision,
    }


def test_an_unknown_uuid(client):
    [row] = _preview(client, (UNKNOWN, 3)).json()["targets"]

    assert row == _unknown_row(UNKNOWN, 3)


def test_a_revision_mismatch_is_a_conflict(client, me, tmp_path):
    track = _add(me, tmp_path, "Changed")

    [row] = _preview(client, (track.uuid_id, track.revision - 1)).json()["targets"]

    assert (row["conflict"], row["revision"], row["base_revision"]) == (
        True, track.revision, track.revision - 1)
    assert row["unknown"] is False


def test_a_pending_deletion_is_busy(client, me, tmp_path):
    track = _add(me, tmp_path, "Deleting")
    mark_pending_deletion(me.unbound_database.context.database_path, track.uuid_id)

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]

    assert (row["busy"], row["conflict"], row["unknown"]) == (True, False, False)


def test_an_active_conversion_is_busy(client, me, tmp_path):
    track = _add(me, tmp_path, "Converting")
    me.insert_conversion_job(track.uuid_id, "aac", "m4a", 192)

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]

    assert row["busy"] is True


def test_another_users_live_track_and_tombstone_answer_like_unknown(client, sam, tmp_path):
    theirs = _add(sam, tmp_path, "Lucky")
    their_gone = _add(sam, tmp_path, "Exit Music")
    assert delete_track(sam, their_gone.uuid_id)

    rows = _preview(
        client, (theirs.uuid_id, theirs.revision), (their_gone.uuid_id, their_gone.revision),
        (UNKNOWN, theirs.revision),
    ).json()["targets"]

    # Identical to the unknown UUID's row except the echoed uuid and revision.
    assert rows[0] == _unknown_row(theirs.uuid_id, theirs.revision)
    assert rows[1] == _unknown_row(their_gone.uuid_id, their_gone.revision)
    assert rows[2] == _unknown_row(UNKNOWN, theirs.revision)
    assert sam.get_track_by_uuid(theirs.uuid_id) is not None


def test_targets_answer_in_request_order(client, me, tmp_path):
    tracks = [_add(me, tmp_path, f"t{i}") for i in range(5)]
    order = [tracks[3], tracks[0], tracks[4], tracks[1], tracks[2]]

    rows = _preview(client, *[(t.uuid_id, t.revision) for t in order]).json()["targets"]

    assert [r["uuid_id"] for r in rows] == [t.uuid_id for t in order]
    assert [r["title"] for r in rows] == ["t3", "t0", "t4", "t1", "t2"]


def test_the_preview_writes_nothing(client, me, sam, tmp_path):
    mine = _add(me, tmp_path, "Mine")
    gone = _add(me, tmp_path, "Gone")
    assert delete_track(me, gone.uuid_id)
    theirs = _add(sam, tmp_path, "Theirs")
    before = _dump(me.unbound_database)

    response = _preview(client, (mine.uuid_id, mine.revision), (gone.uuid_id, 1),
                        (theirs.uuid_id, 1), (UNKNOWN, 1))

    assert response.status_code == 200
    assert _dump(me.unbound_database) == before


def test_the_response_carries_no_path(client, me, tmp_path):
    track = _add(me, tmp_path, "Airbag")

    response = _preview(client, (track.uuid_id, track.revision))

    assert str(tmp_path) not in response.text
    assert "masters" not in response.text
    assert set(response.json()["targets"][0]) == KEYS


# ── shape and count (exit proof: 0/1/100/101 and duplicate IDs) ─────────────

def test_one_and_a_hundred_distinct_targets_are_accepted(client):
    one = _preview(client, (UNKNOWN, 1))
    hundred = _preview(client, *[(str(uuid.uuid4()), 1) for _ in range(100)])

    assert (one.status_code, len(one.json()["targets"])) == (200, 1)
    assert (hundred.status_code, len(hundred.json()["targets"])) == (200, 100)


@pytest.mark.parametrize("body", [
    {"targets": []},
    {"targets": [{"uuid_id": str(uuid.uuid4()), "base_revision": 1} for _ in range(101)]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": 1}, {"uuid_id": UNKNOWN, "base_revision": 2}]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": 1},
                 {"uuid_id": UNKNOWN.upper(), "base_revision": 1}]},
    {},
    {"targets": [{"uuid_id": "not-a-uuid", "base_revision": 1}]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": "1"}]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": -1}]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": 1.5}]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": 2**63}]},
    {"targets": [{"uuid_id": UNKNOWN}]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": 1, "extra": 1}]},
    {"targets": [{"uuid_id": UNKNOWN, "base_revision": 1}], "extra": 1},
    {"targets": {"uuid_id": UNKNOWN, "base_revision": 1}},
], ids=["zero", "101", "duplicate", "duplicate-case", "no-targets", "bad-uuid",
        "string-revision", "negative-revision", "float-revision", "huge-revision", "no-revision",
        "extra-target-field", "extra-field", "not-a-list"])
def test_an_invalid_body_is_422_without_echoing_input(client, body):
    response = client.post(PATH, json=body)

    assert response.status_code == 422, response.text
    detail = response.json()["detail"]
    assert isinstance(detail, list) and detail
    assert all("input" not in error for error in detail)


def test_malformed_json_is_422(client):
    response = client.post(PATH, content=b"{not json", headers={"Content-Type": "application/json"})

    assert response.status_code == 422


# ── the 64 KiB body cap (8-U02, SC-16b) ─────────────────────────────────────

def _padded(size: int) -> bytes:
    body = json.dumps({"targets": [{"uuid_id": UNKNOWN, "base_revision": 1}]}).encode()
    return body[:-1] + b" " * (size - len(body)) + body[-1:]


def test_a_body_of_exactly_64_kib_is_read(client):
    raw = _padded(64 * 1024)
    assert len(raw) == 64 * 1024

    response = client.post(PATH, content=raw, headers={"Content-Type": "application/json"})

    assert response.status_code == 200, response.text


def test_a_body_over_64_kib_without_content_length_is_413(client):
    raw = _padded(64 * 1024 + 1)

    response = client.post(PATH, content=iter([raw[:1000], raw[1000:]]),
                           headers={"Content-Type": "application/json"})

    assert response.status_code == 413
    assert response.json()["detail"]["error"] == "request_too_large"
    assert UNKNOWN not in response.text


# Review r2 8-R2-05(c): the other two pairings of size and framing.


def test_a_chunked_body_of_exactly_64_kib_is_read(client):
    raw = _padded(64 * 1024)

    response = client.post(PATH, content=iter([raw[:1000], raw[1000:]]),
                           headers={"Content-Type": "application/json"})

    assert response.status_code == 200, response.text


def test_a_declared_length_over_64_kib_is_413(client):
    raw = _padded(64 * 1024 + 1)

    response = client.post(PATH, content=raw, headers={"Content-Type": "application/json"})

    assert response.status_code == 413
    assert response.json()["detail"]["error"] == "request_too_large"
    assert UNKNOWN not in response.text


# ── sign-off OPEN-A-11: Possible duplicates gives the same three answers ─────


def _symlinked_file(me, tmp_path):
    outside = tmp_path / "elsewhere" / "big.flac"
    outside.parent.mkdir(parents=True)
    outside.write_bytes(b"y" * 10)
    track = _add(me, tmp_path, "Linked", write=False)
    track.file_path.parent.mkdir(parents=True, exist_ok=True)
    track.file_path.symlink_to(outside)
    return track


def _folder(me, tmp_path):
    track = _add(me, tmp_path, "Folder", write=False)
    track.file_path.mkdir(parents=True)
    return track


def _outside_root(me, tmp_path):
    outside = tmp_path / "elsewhere" / "Stray.flac"
    outside.parent.mkdir(parents=True)
    outside.write_bytes(b"z" * 10)
    track = Track(
        file_path=outside,
        metadata=TrackMetaData(title="Stray", artist="R", album="A", codec="flac", duration=1.0),
    )
    assert me.add_track(track=track)
    return me.get_track_by_uuid(track.uuid_id)


CASES = {
    "present": (lambda me, tmp_path: _add(me, tmp_path, "Here"), True),
    "missing": (lambda me, tmp_path: _add(me, tmp_path, "Lost", write=False), False),
    "symlinked file": (_symlinked_file, None),
    "folder": (_folder, None),
    "outside the root": (_outside_root, None),
}


@pytest.mark.parametrize("case", list(CASES))
def test_possible_duplicates_and_the_preview_give_the_same_answer(client, me, tmp_path, case):
    build, expected = CASES[case]
    track = build(me, tmp_path)
    partner = _add(me, tmp_path, "Partner")
    a, b = sorted((track.uuid_id, partner.uuid_id))
    conn = sqlite3.connect(me.unbound_database.context.database_path)
    try:
        conn.execute(
            "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
            "sort_score, matcher_version, detected_at, status) VALUES (?, ?, ?, 'exact', 0, 1.0, "
            "'m', 100, 'open')", (me.owner_id, a, b))
        conn.commit()
    finally:
        conn.close()

    [row] = _preview(client, (track.uuid_id, track.revision)).json()["targets"]
    [pair] = client.get("/tracks/duplicates").json()["pairs"]
    copy = pair["track_a"] if pair["track_a"]["uuid_id"] == track.uuid_id else pair["track_b"]

    assert row["master_exists"] is expected
    assert copy["master_present"] is expected
