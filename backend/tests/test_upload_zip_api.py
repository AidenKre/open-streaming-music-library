"""7A.2d S8 (wire shape and counts): every item DTO carries ``kind`` and
``skipped_members`` (null = unknown, never 0). Exit proof "1000/1001 audio
children; mixed valid/invalid children report exact counts"; review 7-L22
"ZIP with >100 children: complete deterministic item-keyset order, no
duplicate/skipped child"."""

import zipfile

import pytest

from app.services import upload_errors
from app.services.upload_validation import ValidationFailed, probe_upload
from tests.identity_worker_fixtures import make_db, sql
from tests.test_uploads_api import allocate, batch, item
from tests.tool_call_capture import tool_call
from tests.upload_validation_fixtures import FakeProbe, detected, item_row, make_worker, stage_item
from tests.upload_zip_fixtures import (
    Entry, children_of, files_under, make_expander, stage_zip, tiny_limits, zip_worker,
)

NOW = 1_700_000_000


class ContentProbe(FakeProbe):
    """Per-file probe stand-in: content starting with b"BAD" is invalid audio."""

    def __call__(self, path, **kwargs):
        self.calls.append({**tool_call(probe_upload, path, **kwargs), "path": path})
        if open(path, "rb").read(3) == b"BAD":
            raise ValidationFailed(upload_errors.upload_invalid_audio())
        return detected()


@pytest.fixture
def client(app_client):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: NOW
    app_client.app.state.upload_receipt.uploads_root.mkdir(parents=True, exist_ok=True)
    return app_client


class Env:
    def __init__(self, client, tmp_path):
        self.client, self.tmp = client, tmp_path
        self.db = client.app.state.database
        self.owner = client.app.state.admin_user_id
        self.root = client.app.state.upload_receipt.uploads_root

    def stage_zip(self, entries, **kw):
        return stage_zip(self.db, self.root, self.tmp, entries, owner_id=self.owner, **kw)

    def run(self, probe=None, limit=50):
        expander = make_expander(self.db, self.root, self.tmp, limits=tiny_limits(max_audio_items_per_batch=20))
        worker = zip_worker(self.db, self.root, self.tmp, expander=expander, probe=probe or ContentProbe())
        for _ in range(limit):
            if worker.process_one() == "idle":
                return
        raise AssertionError("worker never went idle")

    def get(self, uid):
        response = self.client.get(f"/tracks/uploads/items/{uid}")
        assert response.status_code == 200, response.text
        return response.json()


@pytest.fixture
def env(client, tmp_path):
    return Env(client, tmp_path)


def good(i, n=30):
    return Entry(f"m{i}.flac", bytes([i + 1]) * n)


def test_item_dtos_carry_kind_and_skipped_members(env):
    zipped = env.stage_zip([good(1), good(0), Entry("cover.jpg", b"j"), Entry("notes.txt", b"t"),
                            Entry("disc", is_dir=True)])
    direct = stage_item(env.db, env.root, owner_id=env.owner)
    waiting = env.client.post("/tracks/uploads", json=batch([item(1)])).json()["items"][0]
    assert (waiting["kind"], waiting["skipped_members"]) == (None, None)
    assert (env.get(waiting["item_uuid"])["kind"], env.get(waiting["item_uuid"])["skipped_members"]) == (None, None)
    before = env.get(zipped["item_uuid"])
    assert (before["kind"], before["skipped_members"]) == (None, None)

    env.run()

    parent = env.get(zipped["item_uuid"])
    assert (parent["kind"], parent["skipped_members"], parent["state"], parent["parent_item_uuid"]) == (
        "zip", 2, "expanded", None)
    kids = children_of(env.db, zipped)
    assert [k["filename"] for k in kids] == ["m0.flac", "m1.flac"]
    for k in kids:
        body = env.get(k["item_uuid"])
        assert (body["parent_item_uuid"], body["kind"], body["skipped_members"], body["state"]) == (
            zipped["item_uuid"], "audio", None, "review_ready")
        assert body["filename"] == k["filename"]
    one = env.get(direct["item_uuid"])
    assert (one["kind"], one["skipped_members"]) == ("audio", None)


def test_mixed_children_report_exact_counts(env):
    zipped = env.stage_zip([good(0), Entry("bad1.flac", b"BAD-one"), good(1), Entry("bad2.flac", b"BAD-two"),
                            good(2), Entry("a.txt", b"a"), Entry("b.jpg", b"b")])
    env.run()
    page = env.client.get(f"/tracks/uploads/{zipped['batch_uuid']}").json()
    assert page["state_counts"] == {"expanded": 1, "review_ready": 3, "failed": 2}
    assert page["item_count"] == 6
    failed = [k for k in children_of(env.db, zipped) if k["state"] == "failed"]
    assert len(failed) == 2
    for k in failed:
        assert env.get(k["item_uuid"])["error"]["code"] == "upload_invalid_audio"
    assert env.get(zipped["item_uuid"])["skipped_members"] == 2


def test_children_page_in_deterministic_order_without_gaps(env):
    names = [f"m{i}.flac" for i in (4, 1, 6, 0, 5, 2, 3)]
    zipped = env.stage_zip([Entry(n, n.encode() * 5) for n in names])
    env.run()
    seen, after = [], None
    for _ in range(20):
        params = {"limit": 2, **({"after": after} if after else {})}
        page = env.client.get(f"/tracks/uploads/{zipped['batch_uuid']}/items", params=params).json()
        seen += page["items"]
        after = page["next_after"]
        if after is None:
            break
    assert [i["item_uuid"] for i in seen][0] == zipped["item_uuid"]
    assert [i["filename"] for i in seen[1:]] == sorted(names)
    assert len({i["item_uuid"] for i in seen}) == len(seen) == 8


# ── the audio-child limit and one more (worker level) ───────────────────────
# Review r1 7-R1-31: the bound is proven with a small injected limit (the same
# code path as the default 1000, which test_upload_limits pins as the default).

LIMIT = 6
AT_LIMIT = dict(max_audio_items_per_batch=LIMIT, max_archive_members=2 * LIMIT)


def _members(n):
    return [Entry(f"{i:04d}.flac", b"x") for i in range(n)]


def test_audio_children_up_to_the_limit_expand(tmp_path):
    db = make_db(tmp_path)
    root = tmp_path / "music" / ".uploads"
    root.mkdir(parents=True)
    staged = stage_zip(db, root, tmp_path, _members(LIMIT))
    expander = make_expander(db, root, tmp_path, limits=tiny_limits(**AT_LIMIT))
    assert zip_worker(db, root, tmp_path, expander=expander).process_one() == "expanded"
    assert len(children_of(db, staged)) == LIMIT
    assert len(files_under(root)) == LIMIT


def test_one_audio_member_over_the_limit_is_rejected(tmp_path):
    db = make_db(tmp_path)
    root = tmp_path / "music" / ".uploads"
    root.mkdir(parents=True)
    staged = stage_zip(db, root, tmp_path, _members(LIMIT + 1))
    expander = make_expander(db, root, tmp_path, limits=tiny_limits(**AT_LIMIT))
    assert zip_worker(db, root, tmp_path, expander=expander).process_one() == "failed"
    row = item_row(db, staged)
    assert (row["state"], row["error_code"]) == ("failed", "upload_archive_too_many_audio")
    assert children_of(db, staged) == [] and files_under(root) == set()
