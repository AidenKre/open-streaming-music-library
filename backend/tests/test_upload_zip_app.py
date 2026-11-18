"""7A.2d S9 (app wiring): the app built by ``main`` gives its validation
worker a ZipExpander, so a received ZIP expands instead of failing
``upload_archive_unsupported``. No sleeps: the test waits on an event set
after the worker's expansion write, and snapshots the result there (before
any child is validated)."""

import hashlib
import threading
from pathlib import Path

from fastapi.testclient import TestClient

from tests.conftest import bearer, log_in
from tests.identity_worker_fixtures import sql
from tests.upload_stream import put
from tests.upload_zip_fixtures import Entry, build_zip

WAIT_S = 10
ON = {"ENABLE_UPLOAD_VALIDATION_WORKER": "true"}


def test_a_received_zip_is_expanded_by_the_apps_worker(configure_app, tmp_path):
    data = build_zip(tmp_path / "in.zip", [Entry("one.flac", b"A" * 20), Entry("two.flac", b"B" * 25),
                                           Entry("cover.jpg", b"j")]).read_bytes()
    batch, parent = "d1000000-0000-4000-8000-000000000001", "d1000000-0000-4000-8000-000000000002"
    body = {"batch_uuid": batch, "items": [{"item_uuid": parent, "filename": "album.zip",
                                            "byte_length": len(data), "sha256": hashlib.sha256(data).hexdigest()}]}
    with TestClient(configure_app(env=ON).app) as c:
        c.headers.update(bearer(log_in(c)["token"]))
        db, owner = c.app.state.database, c.app.state.admin_user_id
        library_root = Path(c.app.state.settings.music_library_dir).resolve()
        snapshot, done = {}, threading.Event()
        real = db.finish_upload_expansion

        def finish(**kwargs):
            result = real(**kwargs)
            snapshot["rows"] = sql(db, "SELECT * FROM upload_items WHERE owner_id = ? ORDER BY member_order_key",
                                   (owner,))
            snapshot["files"] = {r["item_uuid"]: Path(r["source_path"]).read_bytes()
                                 for r in snapshot["rows"] if r["source_path"] and r["parent_item_uuid"]}
            done.set()
            return result

        db.finish_upload_expansion = finish
        try:
            assert c.post("/tracks/uploads", json=body).status_code == 201
            assert put(c, parent, [data]).status == 200
            assert done.wait(WAIT_S)
        finally:
            c.app.state.upload_validation_worker.stop(timeout=WAIT_S)

    rows = {r["item_uuid"]: r for r in snapshot["rows"]}
    assert (rows[parent]["state"], rows[parent]["kind"], rows[parent]["skipped_members"]) == ("expanded", "zip", 1)
    kids = [r for r in snapshot["rows"] if r["parent_item_uuid"] == parent]
    assert [k["member_order_key"] for k in kids] == ["one.flac", "two.flac"]
    for k in kids:
        expected = library_root / ".uploads" / str(owner) / batch / k["item_uuid"] / "source"
        assert Path(k["source_path"]) == expected
    assert sorted(snapshot["files"].values()) == [b"A" * 20, b"B" * 25]
