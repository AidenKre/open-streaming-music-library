"""Phase M.1b (M-U13, SC-28 rule 4, spec §5.4 "Route-derived foreign-ID
matrix"): every ID a route takes looks absent when it is another user's.

The required probes are derived from ``app.routes``: every **path parameter**
of every app route, plus every query parameter that carries an ID (``*_id``
and ``cursor``), plus the listed body IDs (``POST /jobs``, ``POST
/tracks/warm``, ``POST /history``). A route or parameter without a probe fails
``test_every_route_derived_id_has_a_probe``; a later phase adding an ID-taking
route adds its probe here.

The caller is **alex**, a non-first, non-admin user; the victim is **sam**,
another non-admin. Neither is the master admin (user 1), so an endpoint that
silently acts as user 1 cannot pass.
"""

import base64
import json
import sqlite3
import uuid
from io import BytesIO
from pathlib import Path

import pytest
from fastapi.routing import APIRoute
from PIL import Image

from app.library import Library
from app.models import Track, TrackMetaData
from app.models.history import HistoryEvent
from app.services.encoder_coordinator import PrefetchOutcome
from tests.auth_helpers import create_session
from tests.conftest import bearer
from tests.owned_database import add_test_user

# Spec §5.4: the query and body parameters that carry IDs.
LISTED_QUERY_IDS = {
    ("GET", "/tracks", "artist_id"),
    ("GET", "/tracks", "album_id"),
    ("GET", "/tracks", "cursor"),
    ("GET", "/jobs", "uuid_id"),
    ("GET", "/albums", "artist_id"),
}
# 7A.1d: keyset cursors that carry an upload uuid (``after`` is not an ID
# by name: /history/changes' ``after`` is a revision number).
LISTED_CURSOR_IDS = {
    ("GET", "/tracks/uploads", "after"),
    ("GET", "/tracks/uploads/{batch_uuid:uuid}/items", "after"),
    # 8A.2b: the deletion receipt cursor carries an operation uuid.
    ("GET", "/tracks/deletions", "after"),
    # 8A.4: the duplicates list's cursor carries the pair's two track uuids.
    ("GET", "/tracks/duplicates", "after"),
}
LISTED_BODY_IDS = {
    ("POST", "/jobs", "body"),
    ("POST", "/tracks/warm", "body"),
    ("POST", "/history", "body"),
    # 7A.1d: the allocation's batch and item uuids (decision O2).
    ("POST", "/tracks/uploads", "body"),
    # 7A.3a: the commit's acknowledged library tracks and staged items.
    ("POST", "/tracks/uploads/items/{item_uuid:uuid}/commit", "body"),
    # 7A.3b: the resolve-duplicate request's chosen track and operation uuid.
    ("POST", "/tracks/uploads/items/{item_uuid:uuid}/resolve-duplicate", "body"),
    # 8A.2b: the deletion preview's target uuids (plan D21).
    ("POST", "/tracks/deletions/preview", "body"),
    # 8A.2b: the job's operation uuid and target uuids.
    ("POST", "/tracks/deletions", "body"),
    # 8A.4: the dismissed or restored pair's two track uuids.
    ("POST", "/tracks/duplicates/dismiss", "body"),
    ("POST", "/tracks/duplicates/restore", "body"),
}


def _is_id_query(name: str) -> bool:
    return name.endswith("_id") or name == "cursor"


def required_probes(routes) -> set[tuple[str, str, str]]:
    """(method, path, parameter) for every ID a route takes."""
    required = set(LISTED_BODY_IDS) | LISTED_CURSOR_IDS
    for route in routes:
        if not isinstance(route, APIRoute):
            continue
        for method in route.methods:
            for name in route.param_convertors:
                required.add((method, route.path, name))
            for param in route.dependant.query_params:
                if _is_id_query(param.name):
                    required.add((method, route.path, param.name))
    return required


# ── the world: sam's data, probed by alex ───────────────────────────────────

def _png(color) -> bytes:
    buf = BytesIO()
    Image.new("RGB", (8, 8), color).save(buf, format="PNG")
    return buf.getvalue()


def _track(source, title, cover_art_id=None):
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_bytes(b"not really flac")
    return Track(
        file_path=source,
        metadata=TrackMetaData(
            title=title, artist="Radiohead", album="OK Computer", codec="flac",
            duration=1.0, bitrate_kbps=900.0, sample_rate_hz=44100, channels=2,
            track_number=1, disc_number=1,
            has_album_art=cover_art_id is not None, cover_art_id=cover_art_id,
        ),
    )


def _history_event():
    return {
        "event_uuid": str(uuid.uuid4()), "kind": "listen", "entity_type": "track",
        "entity_ref": "t", "occurred_at": 1, "seconds_played": 1.0, "track_length": 2.0,
    }


class _RecordingCoordinator:
    def __init__(self, outcome):
        self.outcome = outcome
        self.enqueued = []

    def enqueue_prefetch(self, uuid_id, quality, source_bitrate_kbps=None):
        self.enqueued.append(uuid_id)
        return self.outcome

    def shutdown(self):
        pass


class World:
    def __init__(self, client, tmp_path):
        self.client = client
        db = client.app.state.database
        self.db = db
        admin = client.app.state.admin_user_id
        self.sam_id = add_test_user(db, "sam")
        self.alex_id = add_test_user(db, "alex")
        assert len({admin, self.sam_id, self.alex_id}) == 3
        assert admin not in (self.sam_id, self.alex_id)
        self.sam = Library(db, self.sam_id)
        self.alex = Library(db, self.alex_id)
        # Requests go out as alex only; the fixture's admin header is dropped.
        client.headers.pop("Authorization")
        self.headers = bearer(create_session(db, self.alex_id).token)

        art = tmp_path / "data" / "cover_art" / "theirs.png"
        art.parent.mkdir(parents=True, exist_ok=True)
        art.write_bytes(_png((200, 0, 0)))
        self.cover_art_id = db.insert_cover_art(
            sha256="theirs", phash="0" * 16, phash_prefix="00", file_path=str(art)
        )
        self.theirs = _track(tmp_path / "music" / "sam" / "Lucky.flac", "Lucky", self.cover_art_id)
        mine_art = tmp_path / "data" / "cover_art" / "mine.png"
        mine_art.write_bytes(_png((0, 200, 0)))
        self.my_cover_art_id = db.insert_cover_art(
            sha256="mine", phash="1" * 16, phash_prefix="11", file_path=str(mine_art)
        )
        self.mine = _track(
            tmp_path / "music" / "alex" / "Airbag.flac", "Airbag", self.my_cover_art_id
        )
        assert self.sam.add_track(self.theirs)
        assert self.alex.add_track(self.mine)
        self.theirs = self.sam.get_track_by_uuid(self.theirs.uuid_id)
        self.artist_id, self.album_id = self.one(
            "SELECT artist_id, album_id FROM trackmetadata WHERE uuid_id = ?",
            (self.theirs.uuid_id,),
        )
        self.my_artist_id, self.my_album_id = self.one(
            "SELECT artist_id, album_id FROM trackmetadata WHERE uuid_id = ?",
            (self.mine.uuid_id,),
        )
        self.job_id = self.sam.insert_conversion_job(self.theirs.uuid_id, "aac", "m4a", 192)
        self.my_job_id = self.alex.insert_conversion_job(self.mine.uuid_id, "aac", "m4a", 192)
        conn = sqlite3.connect(db.context.database_path)
        try:
            conn.execute("UPDATE conversion_jobs SET batch_id = 'sams-batch' WHERE id = ?", (self.job_id,))
            conn.execute("UPDATE conversion_jobs SET batch_id = 'alex-batch' WHERE id = ?", (self.my_job_id,))
            conn.commit()
        finally:
            conn.close()
        self.event = _history_event()
        self.sam.insert_history_events([HistoryEvent(**self.event)])
        # 7A.1d: one upload batch each; alex's is the control.
        self.sam_batch, self.sam_item = _allocate(self.sam, "5a")
        self.my_batch, self.my_item = _allocate(self.alex, "a1")

    def rows(self, sql, params=()):
        conn = sqlite3.connect(self.db.context.database_path)
        try:
            return conn.execute(sql, params).fetchall()
        finally:
            conn.close()

    def one(self, sql, params=()):
        [row] = self.rows(sql, params)
        return row

    def request(self, method, path, **kwargs):
        return self.client.request(method, path, headers=self.headers, **kwargs)

    def sams_title(self):
        return self.one(
            "SELECT title FROM trackmetadata WHERE uuid_id = ?", (self.theirs.uuid_id,)
        )[0]


def _upload_body(prefix, label=None):
    body = {
        "batch_uuid": f"{prefix}000000-0000-4000-8000-000000000001",
        "items": [{
            "item_uuid": f"{prefix}000000-0000-4000-8000-000000000002",
            "filename": "Lucky.flac", "byte_length": 10, "sha256": "ab" * 32,
        }],
    }
    if label is not None:
        body["label"] = label
    return body


def _allocate(library, prefix):
    from app.models.uploads import AllocationRequest

    body = _upload_body(prefix)
    assert library.allocate_upload_batch(AllocationRequest.model_validate(body), now=1)
    return body["batch_uuid"], body["items"][0]["item_uuid"]


@pytest.fixture
def world(app_client, tmp_path):
    return World(app_client, tmp_path)


# ── probes: each asserts the spec §4.2 shape and that sam's data is intact ──

def _get_track(w):
    assert w.request("GET", f"/tracks/{w.mine.uuid_id}").status_code == 200  # control
    assert w.request("GET", f"/tracks/{w.theirs.uuid_id}").status_code == 404


def _patch_track(w):
    for write_mode in ("db_only", "db_and_master"):
        r = w.request("PATCH", f"/tracks/{w.theirs.uuid_id}", json={
            "base_revision": w.theirs.revision, "title": "Stolen", "write_mode": write_mode,
        })
        assert r.status_code == 404, r.text
    assert w.sams_title() == "Lucky"
    mine = w.alex.get_track_by_uuid(w.mine.uuid_id)
    r = w.request("PATCH", f"/tracks/{w.mine.uuid_id}", json={  # control
        "base_revision": mine.revision, "title": "Mine", "write_mode": "db_only",
    })
    assert r.status_code == 200, r.text


def _stream(w):
    params = {"quality": "original"}
    assert w.request("GET", f"/tracks/{w.mine.uuid_id}/stream", params=params).status_code == 200
    assert w.request("GET", f"/tracks/{w.theirs.uuid_id}/stream", params=params).status_code == 404


def _cover_art(w):
    assert w.request("GET", f"/cover_art/{w.my_cover_art_id}").status_code == 200  # control
    assert w.request("GET", f"/cover_art/{w.cover_art_id}").status_code == 404


def _delete_job(w):
    r = w.request("DELETE", f"/jobs/{w.job_id}")
    assert (r.status_code, r.json()) == (200, {"cancelled": False})
    assert w.one("SELECT status FROM conversion_jobs WHERE id = ?", (w.job_id,)) == ("queued",)
    r = w.request("DELETE", f"/jobs/{w.my_job_id}")  # control
    assert (r.status_code, r.json()) == (200, {"cancelled": True})


def _my_uuids(response):
    assert response.status_code == 200, response.text
    return [t["uuid_id"] for t in response.json()["data"]]


def _tracks_by_artist(w):
    mine = w.request("GET", "/tracks", params={"artist_id": w.my_artist_id})
    assert _my_uuids(mine) == [w.mine.uuid_id]  # control
    r = w.request("GET", "/tracks", params={"artist_id": w.artist_id})
    assert (r.status_code, r.json()["data"]) == (200, [])


def _tracks_by_album(w):
    # album_id alone is a 400 for everyone ("album_id requires artist_id").
    r = w.request("GET", "/tracks", params={"artist_id": w.artist_id, "album_id": w.album_id})
    assert (r.status_code, r.json()["data"]) == (200, [])
    mine = w.request("GET", "/tracks", params={
        "artist_id": w.my_artist_id, "album_id": w.my_album_id,
    })
    assert _my_uuids(mine) == [w.mine.uuid_id]  # control


def _tracks_cursor(w):
    def cursor(uuid_id, artist_id, album_id):
        return json.dumps({
            "order_parameters": [{"column": "uuid_id", "isAscending": True}],
            "row_filter_parameters": [],
            "search_parameters": [{"column": "uuid_id", "operator": "=", "value": uuid_id}],
            "artist_id": artist_id,
            "album_id": album_id,
        })

    r = w.request("GET", "/tracks", params={
        "cursor": cursor(w.theirs.uuid_id, w.artist_id, w.album_id),
    })
    assert (r.status_code, r.json()["data"]) == (200, [])
    mine = w.request("GET", "/tracks", params={
        "cursor": cursor(w.mine.uuid_id, w.my_artist_id, w.my_album_id),
    })
    assert _my_uuids(mine) == [w.mine.uuid_id]  # control


def _jobs_by_uuid(w):
    r = w.request("GET", "/jobs", params={"uuid_id": w.theirs.uuid_id})
    assert (r.status_code, r.json()["data"]) == (200, [])
    mine = w.request("GET", "/jobs", params={"uuid_id": w.mine.uuid_id})
    assert [j["job_id"] for j in mine.json()["data"]] == [w.my_job_id]  # control
    assert [j["job_id"] for j in w.request("GET", "/jobs").json()["data"]] == [w.my_job_id]


def _albums_by_artist(w):
    r = w.request("GET", "/albums", params={"artist_id": w.artist_id})
    assert (r.status_code, r.json()["data"]) == (200, [])
    mine = w.request("GET", "/albums", params={"artist_id": w.my_artist_id})
    assert [a["id"] for a in mine.json()["data"]] == [w.my_album_id]  # control


def _artists_cursor(w):
    cursor = json.dumps({
        "order_parameters": [{"column": "name", "isAscending": True}],
        "row_filter_parameters": [],
    })
    r = w.request("GET", "/artists", params={"cursor": cursor})
    assert r.status_code == 200, r.text
    ids = [a["id"] for a in r.json()["data"]]
    assert ids and w.artist_id not in ids  # alex's own "Radiohead" only


def _albums_cursor(w):
    cursor = json.dumps({
        "order_parameters": [{"column": "name", "isAscending": True}],
        "row_filter_parameters": [],
        "artist_id": w.artist_id,
    })
    r = w.request("GET", "/albums", params={"cursor": cursor})
    assert (r.status_code, r.json()["data"]) == (200, [])
    mine = w.request("GET", "/albums", params={"cursor": cursor.replace(
        f'"artist_id": {w.artist_id}', f'"artist_id": {w.my_artist_id}'
    )})
    assert [a["id"] for a in mine.json()["data"]] == [w.my_album_id]  # control


def _jobs_cursor(w):
    for cursor in (0, w.job_id - 1):
        r = w.request("GET", "/jobs", params={"cursor": cursor})
        assert r.status_code == 200
        assert [j["job_id"] for j in r.json()["data"]] == [w.my_job_id]  # never sam's


def _jobs_by_batch(w):
    r = w.request("GET", "/jobs", params={"batch_id": "sams-batch"})
    assert (r.status_code, r.json()["data"]) == (200, [])
    mine = w.request("GET", "/jobs", params={"batch_id": "alex-batch"})
    assert [j["job_id"] for j in mine.json()["data"]] == [w.my_job_id]  # control


def _post_job(w):
    r = w.request("POST", "/jobs", json={
        "type": "conversion",
        "uuid_id": w.theirs.uuid_id,
        "params": {"target_codec": "aac", "target_bitrate_kbps": 192},
        "base_revision": w.theirs.revision,
    })
    assert r.status_code == 404, r.text
    assert w.rows("SELECT id FROM conversion_jobs ORDER BY id") == [(w.job_id,), (w.my_job_id,)]
    r = w.request("POST", "/jobs", json={  # control: alex's own track is found (already queued)
        "type": "conversion",
        "uuid_id": w.mine.uuid_id,
        "params": {"target_codec": "aac", "target_bitrate_kbps": 192},
        "base_revision": w.alex.get_track_by_uuid(w.mine.uuid_id).revision,
    })
    assert r.status_code == 409, r.text


def _warm(w):
    for outcome in (PrefetchOutcome.QUEUED, PrefetchOutcome.ALREADY_CACHED):
        coordinator = _RecordingCoordinator(outcome)
        w.client.app.state.encoder_coordinator = coordinator
        r = w.request("POST", "/tracks/warm", json={
            "current_index": 0, "quality": "128", "count": 3,
            "track_uuids": [w.theirs.uuid_id, w.mine.uuid_id, "no-such-track"],
        })
        assert r.status_code == 200, r.text
        assert coordinator.enqueued == [w.mine.uuid_id]
        assert r.json()["prefetch_queued"] + r.json()["prefetch_skipped"] == 1


def _post_history(w):
    before = w.rows("SELECT * FROM history_events ORDER BY event_uuid")
    fresh = _history_event()
    r = w.request("POST", "/history", json={"events": [fresh, w.event]})  # identical payload
    assert r.status_code == 409, r.text
    detail = r.json()["detail"]
    assert detail["error"] == "history_event_conflict"
    assert detail["conflicting_event_uuids"] == [w.event["event_uuid"]]
    # The batch rolled back: alex's fresh event was not stored either.
    assert w.rows("SELECT * FROM history_events ORDER BY event_uuid") == before
    assert w.request("POST", "/history", json={"events": [fresh]}).status_code == 200  # control


def _sams_uploads(w):
    return [
        w.rows(f"SELECT * FROM {table} WHERE owner_id = ? ORDER BY 2", (w.sam_id,))
        for table in ("upload_batches", "upload_items", "operation_receipts")
    ]


def _allocate_upload(w):
    before = _sams_uploads(w)
    # sam's batch and item uuids, a different body: a fresh allocation for alex (O2).
    r = w.request("POST", "/tracks/uploads", json=_upload_body("5a", label="alex's"))
    assert r.status_code == 201, r.text
    assert r.json()["batch"]["label"] == "alex's"
    assert _sams_uploads(w) == before
    assert w.rows(
        "SELECT owner_id, label FROM upload_batches WHERE batch_uuid = ? ORDER BY owner_id",
        (w.sam_batch,),
    ) == sorted([(w.sam_id, None), (w.alex_id, "alex's")])
    # control: alex's own batch id with a different body conflicts.
    r = w.request("POST", "/tracks/uploads", json=_upload_body("a1", label="changed"))
    assert (r.status_code, r.json()["detail"]["error"]) == (409, "operation_conflict")


UNKNOWN_UPLOAD = "00000000-0000-4000-8000-0000000000ff"


def _same_as_unknown(w, method, template, foreign, code):
    theirs = w.request(method, template.format(foreign))
    unknown = w.request(method, template.format(UNKNOWN_UPLOAD))
    assert (theirs.status_code, unknown.status_code) == (404, 404), theirs.text
    assert theirs.json() == unknown.json()
    assert theirs.json()["detail"]["error"] == code


def _get_upload_batch(w):
    _same_as_unknown(w, "GET", "/tracks/uploads/{}", w.sam_batch, "upload_batch_not_found")
    assert w.request("GET", f"/tracks/uploads/{w.my_batch}").status_code == 200  # control


def _get_upload_item(w):
    _same_as_unknown(w, "GET", "/tracks/uploads/items/{}", w.sam_item, "upload_item_not_found")
    assert w.request("GET", f"/tracks/uploads/items/{w.my_item}").status_code == 200  # control


def _upload_cursor(*key) -> str:
    raw = json.dumps(list(key), separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _list_uploads_after(w):
    # A cursor at sam's batch key lists alex's own later batches, never sam's.
    for after in (_upload_cursor(0, w.sam_batch), _upload_cursor(1, w.sam_batch)):
        r = w.request("GET", "/tracks/uploads", params={"after": after})
        assert r.status_code == 200, r.text
        assert [b["batch_uuid"] for b in r.json()["batches"]] == [w.my_batch]
    r = w.request("GET", "/tracks/uploads")  # control
    assert [b["batch_uuid"] for b in r.json()["batches"]] == [w.my_batch]


def _list_upload_items(w):
    _same_as_unknown(w, "GET", "/tracks/uploads/{}/items", w.sam_batch, "upload_batch_not_found")
    r = w.request("GET", f"/tracks/uploads/{w.my_batch}/items")  # control
    assert [i["item_uuid"] for i in r.json()["items"]] == [w.my_item]


def _list_upload_items_after(w):
    # A cursor naming sam's item pages through alex's own batch only.
    r = w.request(
        "GET", f"/tracks/uploads/{w.my_batch}/items",
        params={"after": _upload_cursor(0, "", w.sam_item)},
    )
    assert r.status_code == 200, r.text
    assert [i["item_uuid"] for i in r.json()["items"]] == [w.my_item]


def _cancel_upload_item(w):
    _same_as_unknown(w, "DELETE", "/tracks/uploads/items/{}", w.sam_item, "upload_item_not_found")
    assert w.rows(
        "SELECT state FROM upload_items WHERE owner_id = ? AND item_uuid = ?", (w.sam_id, w.sam_item)
    ) == [("allocated",)]
    r = w.request("DELETE", f"/tracks/uploads/items/{w.my_item}")  # control
    assert (r.status_code, r.json()["state"]) == (200, "cancelled")


def _put_upload_content(w):
    import hashlib

    from tests.upload_stream import put

    data = b"0123456789"  # alex's control item allocates 10 bytes
    conn = sqlite3.connect(w.db.context.database_path)
    try:
        with conn:
            conn.execute(
                "UPDATE upload_items SET expected_sha256 = ? WHERE owner_id = ? AND item_uuid = ?",
                (hashlib.sha256(data).hexdigest(), w.alex_id, w.my_item),
            )
    finally:
        conn.close()
    w.client.headers.update(w.headers)  # the driver sends the client's own header
    try:
        theirs = put(w.client, w.sam_item, [data])
        unknown = put(w.client, UNKNOWN_UPLOAD, [data])
        assert (theirs.status, unknown.status) == (404, 404), theirs.body
        assert theirs.json() == unknown.json()
        assert theirs.error == "upload_item_not_found"
        assert (theirs.reads, unknown.reads) == (0, 0)
        assert w.rows(
            "SELECT state, received_bytes FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
            (w.sam_id, w.sam_item),
        ) == [("allocated", 0)]
        assert w.rows("SELECT * FROM storage_reservations WHERE owner_id = ?", (w.sam_id,)) == []
        mine = put(w.client, w.my_item, [data])  # control
        assert (mine.status, mine.json()["state"]) == (200, "validating"), mine.body
    finally:
        w.client.headers.pop("Authorization", None)


def _retry_upload_item(w):
    # 7A.2c: a foreign retry looks exactly like an unknown one and revives nothing.
    conn = sqlite3.connect(w.db.context.database_path)
    try:
        with conn:
            conn.execute(
                "UPDATE upload_items SET state = 'failed', error_code = 'probe_timeout',"
                " error_retryable = 1 WHERE item_uuid IN (?, ?)", (w.sam_item, w.my_item),
            )
    finally:
        conn.close()
    body = {"expected_review_version": 0}
    theirs = w.request("POST", f"/tracks/uploads/items/{w.sam_item}/retry", json=body)
    unknown = w.request("POST", f"/tracks/uploads/items/{UNKNOWN_UPLOAD}/retry", json=body)
    assert (theirs.status_code, unknown.status_code) == (404, 404), theirs.text
    assert theirs.json() == unknown.json()
    assert theirs.json()["detail"]["error"] == "upload_item_not_found"
    assert w.rows(
        "SELECT state, review_version FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
        (w.sam_id, w.sam_item),
    ) == [("failed", 0)]
    r = w.request("POST", f"/tracks/uploads/items/{w.my_item}/retry", json=body)  # control
    assert (r.status_code, r.json()["review_version"]) == (200, 1), r.text


def _preview_upload_item(w):
    # 7A.2c: sam's review-ready item has no preview for alex; no byte of it leaks.
    from tests.upload_validation_fixtures import make_worker, stage_item

    root = w.client.app.state.upload_receipt.uploads_root
    theirs = stage_item(w.db, root, owner_id=w.sam_id, content=b"sams audio")
    mine = stage_item(w.db, root, owner_id=w.alex_id, content=b"alex audio")
    worker = make_worker(w.db, root)
    worker.process_one()
    worker.process_one()
    foreign = w.request("GET", f"/tracks/uploads/items/{theirs['item_uuid']}/preview")
    unknown = w.request("GET", f"/tracks/uploads/items/{UNKNOWN_UPLOAD}/preview")
    assert (foreign.status_code, unknown.status_code) == (404, 404), foreign.text
    assert foreign.json() == unknown.json()
    assert b"sams audio" not in foreign.content
    r = w.request("GET", f"/tracks/uploads/items/{mine['item_uuid']}/preview")  # control
    assert (r.status_code, r.content) == (200, b"alex audio")


def _commit_body(**acks):
    return {
        "operation_uuid": str(uuid.uuid4()), "base_review_version": 0, "edits": {},
        "write_tags": False,
        "acknowledged_duplicates": {"library_tracks": [], "staged_items": [], **acks},
    }


def _ready_items(w, owner_id, *contents):
    from tests.upload_validation_fixtures import make_worker, stage_item

    root = w.client.app.state.upload_receipt.uploads_root
    staged = [stage_item(w.db, root, owner_id=owner_id, content=c) for c in contents]
    worker = make_worker(w.db, root)
    for _ in staged:
        assert worker.process_one() == "review_ready"
    return [s["item_uuid"] for s in staged]


def _commit_upload_item(w):
    # 7A.3a: committing sam's review-ready item looks exactly like an unknown one.
    [theirs] = _ready_items(w, w.sam_id, b"sams audio")
    [mine] = _ready_items(w, w.alex_id, b"alex audio")
    path = "/tracks/uploads/items/{}/commit"
    foreign = w.request("POST", path.format(theirs), json=_commit_body())
    unknown = w.request("POST", path.format(UNKNOWN_UPLOAD), json=_commit_body())
    assert (foreign.status_code, unknown.status_code) == (404, 404), foreign.text
    assert foreign.json() == unknown.json()
    assert foreign.json()["detail"]["error"] == "upload_item_not_found"
    assert w.rows("SELECT state FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                  (w.sam_id, theirs)) == [("review_ready",)]
    assert w.rows("SELECT COUNT(*) FROM upload_commit_journal") == [(0,)]
    r = w.request("POST", path.format(mine), json=_commit_body())  # control
    assert (r.status_code, r.json()["state"]) == (202, "committing"), r.text


def _commit_upload_item_body(w):
    # 7A.3a: sam's track and staged item in alex's acknowledgements answer
    # exactly like unknown ones (frozen as given, inert, never looked up).
    [their_item] = _ready_items(w, w.sam_id, b"sams body audio")
    one, two = _ready_items(w, w.alex_id, b"alex one", b"alex two")
    path = "/tracks/uploads/items/{}/commit"
    foreign = w.request("POST", path.format(one), json=_commit_body(
        library_tracks=[w.theirs.uuid_id], staged_items=[their_item]))
    unknown = w.request("POST", path.format(two), json=_commit_body(
        library_tracks=[UNKNOWN_UPLOAD], staged_items=[UNKNOWN_UPLOAD]))
    assert (foreign.status_code, unknown.status_code) == (202, 202), foreign.text
    keys = ("state", "review_version", "error", "tag_write_supported")
    assert {k: foreign.json()[k] for k in keys} == {k: unknown.json()[k] for k in keys}
    assert w.rows("SELECT state FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                  (w.sam_id, their_item)) == [("review_ready",)]
    assert w.sam.get_track_by_uuid(w.theirs.uuid_id) is not None


def _resolve_body(track, op=None, version=0):
    return {"operation_uuid": op or str(uuid.uuid4()), "expected_review_version": version,
            "existing_track_uuid": track}


def _item_reporting(w, owner_id, track, content):
    from tests.identity_worker_fixtures import sql

    [item] = _ready_items(w, owner_id, content)
    report = {"v": 1, "status": "complete",
              "exact": {"subject_state": "current", "library_pending": 0, "library_failed": 0,
                        "library_not_comparable": 0},
              "fingerprint": {"subject_state": "current", "library_pending": 0, "library_failed": 0,
                              "library_not_comparable": 0},
              "matches": [{"ref": "library_track", "id": track, "kind": "exact", "band": "exact",
                           "score": None}]}
    sql(w.db, "UPDATE upload_items SET duplicate_report = ? WHERE owner_id = ? AND item_uuid = ?",
        (json.dumps(report), owner_id, item))
    return item


def _resolve_duplicate_item(w):
    # 7A.3b: resolving sam's review-ready item looks exactly like an unknown one.
    theirs = _item_reporting(w, w.sam_id, w.theirs.uuid_id, b"sams resolve audio")
    mine = _item_reporting(w, w.alex_id, w.mine.uuid_id, b"alex resolve audio")
    path = "/tracks/uploads/items/{}/resolve-duplicate"
    foreign = w.request("POST", path.format(theirs), json=_resolve_body(w.theirs.uuid_id))
    unknown = w.request("POST", path.format(UNKNOWN_UPLOAD), json=_resolve_body(w.theirs.uuid_id))
    assert (foreign.status_code, unknown.status_code) == (404, 404), foreign.text
    assert foreign.json() == unknown.json()
    assert foreign.json()["detail"]["error"] == "upload_item_not_found"
    assert w.rows("SELECT state FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                  (w.sam_id, theirs)) == [("review_ready",)]
    r = w.request("POST", path.format(mine), json=_resolve_body(w.mine.uuid_id))  # control
    assert (r.status_code, r.json()["state"]) == (200, "duplicate"), r.text


def _resolve_duplicate_body(w):
    # 7A.3b: sam's track named as alex's chosen match answers like an unknown uuid even when
    # alex's report (wrongly) lists it; sam's operation uuid is no handle on alex's operations.
    path = "/tracks/uploads/items/{}/resolve-duplicate"
    one = _item_reporting(w, w.alex_id, w.theirs.uuid_id, b"alex body one")
    two = _item_reporting(w, w.alex_id, UNKNOWN_UPLOAD, b"alex body two")
    foreign = w.request("POST", path.format(one), json=_resolve_body(w.theirs.uuid_id))
    unknown = w.request("POST", path.format(two), json=_resolve_body(UNKNOWN_UPLOAD))
    assert (foreign.status_code, unknown.status_code) == (409, 409), foreign.text
    assert foreign.json() == unknown.json()
    assert foreign.json()["detail"]["error"] == "upload_duplicate_match_unavailable"
    assert w.sam.get_track_by_uuid(w.theirs.uuid_id) is not None
    sams_op = str(uuid.uuid4())
    from tests.identity_worker_fixtures import sql

    sql(w.db, "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash, created_at,"
              " result_ref) VALUES (?, ?, 'upload_commit', ?, 0, ?)",
        (w.sam_id, sams_op, "0" * 64, UNKNOWN_UPLOAD))
    [mine] = [_item_reporting(w, w.alex_id, w.mine.uuid_id, b"alex body three")]
    r = w.request("POST", path.format(mine), json=_resolve_body(w.mine.uuid_id, op=sams_op))  # control
    assert (r.status_code, r.json()["state"]) == (200, "duplicate"), r.text


# ── 8A.2b: deletion preview, jobs and receipts (plan D21) ──────────────────

def _deletion_switch_on(w):
    w.client.app.state.settings.library_delete_enabled = True


def _preview_deletion_body(w):
    # sam's live track and sam's tombstone answer exactly like an unknown uuid.
    _deletion_switch_on(w)
    gone = _track(Path(str(w.theirs.file_path)).parent / "Gone.flac", "Gone")
    assert w.sam.add_track(gone)
    assert w.sam.delete_track(gone.uuid_id)
    revision = w.theirs.revision
    r = w.request("POST", "/tracks/deletions/preview", json={"targets": [
        {"uuid_id": w.theirs.uuid_id, "base_revision": revision},
        {"uuid_id": gone.uuid_id, "base_revision": revision},
        {"uuid_id": UNKNOWN_UPLOAD, "base_revision": revision},
    ]})
    assert r.status_code == 200, r.text
    rows = [{k: v for k, v in row.items() if k != "uuid_id"} for row in r.json()["targets"]]
    assert rows[0] == rows[1] == rows[2]
    assert rows[0]["unknown"] is True and rows[0]["title"] is None
    assert "Lucky" not in r.text and "Gone" not in r.text
    mine = w.alex.get_track_by_uuid(w.mine.uuid_id)
    r = w.request("POST", "/tracks/deletions/preview", json={"targets": [  # control
        {"uuid_id": mine.uuid_id, "base_revision": mine.revision}]})
    assert r.json()["targets"][0]["title"] == "Airbag"


def _deletion_job_body(op, *targets):
    return {"operation_uuid": op, "confirmed_count": len(targets),
            "targets": [{"uuid_id": u, "base_revision": r} for u, r in targets]}


def _sams_deletion_job(w, op):
    from app.models.deletions import DeletionJobRequest

    request = DeletionJobRequest.model_validate(
        _deletion_job_body(op, (w.theirs.uuid_id, w.theirs.revision)))
    assert w.sam.create_deletion_job(request, now=1)


def _create_deletion_job_body(w):
    # sam's track in alex's job is accepted exactly like an unknown uuid (frozen,
    # never looked up), and sam's operation uuid is no handle on sam's job.
    _deletion_switch_on(w)
    sams_op = "5a000000-0000-4000-8000-0000000000d1"
    _sams_deletion_job(w, sams_op)
    sams_rows = w.rows("SELECT * FROM deletion_job_items WHERE owner_id = ?", (w.sam_id,))
    revision = w.theirs.revision
    foreign = w.request("POST", "/tracks/deletions", json=_deletion_job_body(
        sams_op, (w.theirs.uuid_id, revision)))
    unknown_op = "a1000000-0000-4000-8000-0000000000d2"
    unknown = w.request("POST", "/tracks/deletions", json=_deletion_job_body(
        unknown_op, (UNKNOWN_UPLOAD, revision)))
    assert (foreign.status_code, unknown.status_code) == (202, 202), foreign.text
    def masked(r, op, target):  # created_at is the request's own clock
        body = {k: v for k, v in r.json().items() if k != "created_at"}
        return json.dumps(body, sort_keys=True).replace(op, "<op>").replace(target, "<t>")
    assert masked(foreign, sams_op, w.theirs.uuid_id) == masked(unknown, unknown_op, UNKNOWN_UPLOAD)
    assert w.rows("SELECT * FROM deletion_job_items WHERE owner_id = ?", (w.sam_id,)) == sams_rows
    assert w.sam.get_track_by_uuid(w.theirs.uuid_id) is not None
    r = w.request("POST", "/tracks/deletions", json=_deletion_job_body(  # control
        unknown_op, (w.mine.uuid_id, 1)))
    assert (r.status_code, r.json()["detail"]["error"]) == (409, "operation_conflict")


def _get_deletion_job(w):
    # sam's job answers exactly like an unknown one, also with the switch off.
    sams_op = "5a000000-0000-4000-8000-0000000000d3"
    _sams_deletion_job(w, sams_op)
    _same_as_unknown(w, "GET", "/tracks/deletions/{}", sams_op, "deletion_job_not_found")
    from app.models.deletions import DeletionJobRequest

    my_op = "a1000000-0000-4000-8000-0000000000d4"
    assert w.alex.create_deletion_job(DeletionJobRequest.model_validate(
        _deletion_job_body(my_op, (w.mine.uuid_id, 1))), now=1)
    assert w.request("GET", f"/tracks/deletions/{my_op}").status_code == 200  # control


def _list_deletions_after(w):
    # A cursor at sam's job key lists alex's own later jobs, never sam's.
    sams_op = "5a000000-0000-4000-8000-0000000000d5"
    _sams_deletion_job(w, sams_op)  # created_at 1
    from app.models.deletions import DeletionJobRequest

    my_op = "a1000000-0000-4000-8000-0000000000d6"
    assert w.alex.create_deletion_job(DeletionJobRequest.model_validate(
        _deletion_job_body(my_op, (w.mine.uuid_id, 1))), now=2)
    for after in (_upload_cursor(0, sams_op), _upload_cursor(1, sams_op)):
        r = w.request("GET", "/tracks/deletions", params={"after": after})
        assert r.status_code == 200, r.text
        assert [j["operation_uuid"] for j in r.json()["jobs"]] == [my_op]
    r = w.request("GET", "/tracks/deletions")  # control
    assert [j["operation_uuid"] for j in r.json()["jobs"]] == [my_op]


# ── 8A.4: duplicate pairs ────────────────────────────────────────────────────

def _plant_pair(w, owner_id, a, b):
    from tests.identity_worker_fixtures import sql

    ua, ub = sorted((a, b))
    sql(w.db, "INSERT INTO track_duplicate_candidates (owner_id, uuid_a, uuid_b, kind, band_rank, "
              "sort_score, matcher_version, detected_at) VALUES (?, ?, ?, 'exact', 0, 1.0, 'm', 1)",
        (owner_id, ua, ub))
    return ua, ub


def _second_track(w, owner_id, name):
    from tests.identity_worker_fixtures import add_track

    return add_track(w.db, f"/m/{name}.flac", owner_id=owner_id)


def _duplicate_pairs(w):
    """sam's pair and alex's pair; returns (sams, mine)."""
    sams = _plant_pair(w, w.sam_id, w.theirs.uuid_id, _second_track(w, w.sam_id, "sams-copy"))
    mine = _plant_pair(w, w.alex_id, w.mine.uuid_id, _second_track(w, w.alex_id, "my-copy"))
    return sams, mine


def _list_duplicates_after(w):
    # A cursor at (or before) sam's pair key pages through alex's own pairs only.
    sams, mine = _duplicate_pairs(w)
    for after in (_upload_cursor(0, 1.0, *sams), _upload_cursor(0, 2.0, *sams)):
        r = w.request("GET", "/tracks/duplicates", params={"after": after})
        assert r.status_code == 200, r.text
        listed = [(p["uuid_a"], p["uuid_b"]) for p in r.json()["pairs"]]
        assert sams not in listed
        assert set(listed) <= {mine}
    r = w.request("GET", "/tracks/duplicates")  # control
    assert [(p["uuid_a"], p["uuid_b"]) for p in r.json()["pairs"]] == [mine]


def _set_pair_status(w, action, status_before):
    # sam's pair named by alex answers byte-for-byte like an unknown pair and is untouched;
    # so does a pair of one of alex's tracks with one of sam's.
    from tests.identity_worker_fixtures import sql

    sams, mine = _duplicate_pairs(w)
    sql(w.db, "UPDATE track_duplicate_candidates SET status = ?", (status_before,))
    path = f"/tracks/duplicates/{action}"
    unknown = w.request("POST", path, json={"uuid_a": UNKNOWN_UPLOAD, "uuid_b": UNKNOWN_UPLOAD[:-2] + "fe"})
    assert unknown.status_code == 404, unknown.text
    for a, b in (sams, sams[::-1], (w.mine.uuid_id, w.theirs.uuid_id)):
        foreign = w.request("POST", path, json={"uuid_a": a, "uuid_b": b})
        assert (foreign.status_code, foreign.content) == (404, unknown.content)
    assert w.rows("SELECT status FROM track_duplicate_candidates WHERE owner_id = ?",
                  (w.sam_id,)) == [(status_before,)]
    r = w.request("POST", path, json={"uuid_a": mine[1], "uuid_b": mine[0]})  # control
    assert r.status_code == 200, r.text


def _dismiss_duplicates(w):
    _set_pair_status(w, "dismiss", "open")


def _restore_duplicates(w):
    _set_pair_status(w, "restore", "dismissed")


PROBES = {
    ("GET", "/tracks/{uuid_id:uuid}", "uuid_id"): _get_track,
    ("PATCH", "/tracks/{uuid_id:uuid}", "uuid_id"): _patch_track,
    ("GET", "/tracks/{uuid_id:uuid}/stream", "uuid_id"): _stream,
    ("GET", "/cover_art/{cover_art_id}", "cover_art_id"): _cover_art,
    ("DELETE", "/jobs/{job_id}", "job_id"): _delete_job,
    ("GET", "/tracks", "artist_id"): _tracks_by_artist,
    ("GET", "/tracks", "album_id"): _tracks_by_album,
    ("GET", "/tracks", "cursor"): _tracks_cursor,
    ("GET", "/jobs", "uuid_id"): _jobs_by_uuid,
    ("GET", "/albums", "artist_id"): _albums_by_artist,
    ("GET", "/albums", "cursor"): _albums_cursor,
    ("GET", "/artists", "cursor"): _artists_cursor,
    ("GET", "/jobs", "cursor"): _jobs_cursor,
    ("GET", "/jobs", "batch_id"): _jobs_by_batch,
    ("POST", "/jobs", "body"): _post_job,
    ("POST", "/tracks/warm", "body"): _warm,
    ("POST", "/history", "body"): _post_history,
    ("POST", "/tracks/uploads", "body"): _allocate_upload,
    ("GET", "/tracks/uploads/{batch_uuid:uuid}", "batch_uuid"): _get_upload_batch,
    ("GET", "/tracks/uploads/items/{item_uuid:uuid}", "item_uuid"): _get_upload_item,
    ("GET", "/tracks/uploads", "after"): _list_uploads_after,
    ("GET", "/tracks/uploads/{batch_uuid:uuid}/items", "batch_uuid"): _list_upload_items,
    ("GET", "/tracks/uploads/{batch_uuid:uuid}/items", "after"): _list_upload_items_after,
    ("DELETE", "/tracks/uploads/items/{item_uuid:uuid}", "item_uuid"): _cancel_upload_item,
    ("PUT", "/tracks/uploads/items/{item_uuid:uuid}/content", "item_uuid"): _put_upload_content,
    ("POST", "/tracks/uploads/items/{item_uuid:uuid}/retry", "item_uuid"): _retry_upload_item,
    ("GET", "/tracks/uploads/items/{item_uuid:uuid}/preview", "item_uuid"): _preview_upload_item,
    ("POST", "/tracks/uploads/items/{item_uuid:uuid}/commit", "item_uuid"): _commit_upload_item,
    ("POST", "/tracks/uploads/items/{item_uuid:uuid}/commit", "body"): _commit_upload_item_body,
    ("POST", "/tracks/uploads/items/{item_uuid:uuid}/resolve-duplicate", "item_uuid"): _resolve_duplicate_item,
    ("POST", "/tracks/uploads/items/{item_uuid:uuid}/resolve-duplicate", "body"): _resolve_duplicate_body,
    # 8A.2b
    ("POST", "/tracks/deletions/preview", "body"): _preview_deletion_body,
    ("POST", "/tracks/deletions", "body"): _create_deletion_job_body,
    ("GET", "/tracks/deletions/{operation_uuid:uuid}", "operation_uuid"): _get_deletion_job,
    ("GET", "/tracks/deletions", "after"): _list_deletions_after,
    # 8A.4: duplicates.
    ("GET", "/tracks/duplicates", "after"): _list_duplicates_after,
    ("POST", "/tracks/duplicates/dismiss", "body"): _dismiss_duplicates,
    ("POST", "/tracks/duplicates/restore", "body"): _restore_duplicates,
}


# ── coverage ────────────────────────────────────────────────────────────────

def test_every_route_derived_id_has_a_probe(configure_app):
    app = configure_app().app
    required = required_probes(app.routes)

    assert LISTED_QUERY_IDS <= required  # the derivation finds the spec's list
    assert set(PROBES) == required


def test_a_new_id_taking_route_without_a_probe_fails_the_coverage(configure_app):
    app = configure_app().app

    def lyrics(uuid_id: str, translation_id: int | None = None):
        return {}

    routes = [*app.routes, APIRoute("/tracks/{uuid_id}/lyrics", lyrics, methods=["GET"])]

    missing = required_probes(routes) - set(PROBES)
    assert missing == {
        ("GET", "/tracks/{uuid_id}/lyrics", "uuid_id"),
        ("GET", "/tracks/{uuid_id}/lyrics", "translation_id"),
    }


# ── the matrix ──────────────────────────────────────────────────────────────

# Review r1 R1-16: creating a job needs the real encoder probe (ffmpeg) to accept aac.
_NEEDS_FFMPEG = {("POST", "/jobs", "body")}


@pytest.mark.parametrize(
    "probe",
    [pytest.param(p, marks=pytest.mark.requires_ffmpeg) if p in _NEEDS_FFMPEG else p for p in sorted(PROBES)],
    ids=lambda p: " ".join(p),
)
def test_another_users_id_looks_absent(world, probe):
    PROBES[probe](world)
