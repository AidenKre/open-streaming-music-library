"""7A.3c S7 (spec §3: "seven days since meaningful user/transfer progress ...
Polling does not renew expiry"): an explicit retry and an accepted commit are
meaningful progress and renew ``progress_at``; reading an item, its batch or a
batch list never does, so a polled item still expires on time."""

import uuid

import pytest

from app.services.upload_janitor import UploadJanitor
from tests.identity_worker_fixtures import sql
from tests.upload_validation_fixtures import FakeProbe, detected, item_row, make_worker, stage_item

DAY = 86_400
T0 = 1_900_000_000


class Clock:
    def __init__(self, now):
        self.now = now

    def __call__(self):
        return self.now


@pytest.fixture
def clock():
    return Clock(T0)


@pytest.fixture
def env(app_client, clock):
    from app.routers.uploads import upload_clock

    app_client.app.dependency_overrides[upload_clock] = lambda: clock.now
    app_client.app.state.upload_commit_worker = None
    app_client.app.state.upload_validation_worker = None
    db = app_client.app.state.database
    root = app_client.app.state.upload_receipt.uploads_root
    root.mkdir(parents=True, exist_ok=True)
    return app_client, db, root, app_client.app.state.admin_user_id


def ready(db, root, owner):
    staged = stage_item(db, root, owner_id=owner, progress_at=T0)
    assert make_worker(db, root, probe=FakeProbe(detected())).process_one() == "review_ready"
    sql(db, "UPDATE upload_items SET progress_at = ? WHERE item_uuid = ?", (T0, staged["item_uuid"]))
    return staged


def janitor(client, root, now):
    return UploadJanitor(client.app.state.database, uploads_root=root,
                         music_library_dir=root.parent, cover_art=None, clock=lambda: now)


def test_polling_does_not_renew_expiry(env, clock):
    client, db, root, owner = env
    staged = ready(db, root, owner)

    for day in range(1, 7):
        clock.now = T0 + day * DAY
        assert client.get(f"/tracks/uploads/items/{staged['item_uuid']}").status_code == 200
        assert client.get(f"/tracks/uploads/{staged['batch_uuid']}").status_code == 200
        assert client.get(f"/tracks/uploads/{staged['batch_uuid']}/items").status_code == 200
        assert client.get("/tracks/uploads").status_code == 200

    assert item_row(db, staged)["progress_at"] == T0
    janitor(client, root, T0 + 7 * DAY).run_once()
    assert item_row(db, staged)["state"] == "expired"


def test_an_accepted_commit_renews_progress(env, clock):
    client, db, root, owner = env
    staged = ready(db, root, owner)
    clock.now = T0 + 5 * DAY

    response = client.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit", json={
        "operation_uuid": str(uuid.uuid4()), "base_review_version": 0, "edits": {},
        "write_tags": False, "acknowledged_duplicates": {"library_tracks": [], "staged_items": []}})

    assert response.status_code == 202, response.text
    assert item_row(db, staged)["progress_at"] == T0 + 5 * DAY


@pytest.mark.parametrize("state", ["duplicate_conflict", "failed"])
def test_a_retry_renews_progress(env, clock, state):
    client, db, root, owner = env
    staged = ready(db, root, owner)
    extra = ", error_code = 'x', error_retryable = 1" if state == "failed" else ""
    sql(db, f"UPDATE upload_items SET state = ?{extra} WHERE item_uuid = ?", (state, staged["item_uuid"]))
    clock.now = T0 + 6 * DAY

    response = client.post(f"/tracks/uploads/items/{staged['item_uuid']}/retry",
                           json={"expected_review_version": 0})

    assert response.status_code == 200, response.text
    assert item_row(db, staged)["progress_at"] == T0 + 6 * DAY
    janitor(client, root, T0 + 7 * DAY).run_once()
    assert item_row(db, staged)["state"] != "expired"


def test_a_refused_retry_does_not_renew_progress(env, clock):
    client, db, root, owner = env
    staged = ready(db, root, owner)
    clock.now = T0 + 6 * DAY

    response = client.post(f"/tracks/uploads/items/{staged['item_uuid']}/retry",
                           json={"expected_review_version": 0})

    assert response.status_code == 409
    assert item_row(db, staged)["progress_at"] == T0
