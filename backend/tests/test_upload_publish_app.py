"""7A.3b S10: the app wires the publisher into the commit worker (spec §6 steps
3-6 run after ``prepared``; "After commit, notify normal cache/prefetch
machinery": the app's ``IdentityWakeup``), and a commit accepted through the
API ends ``imported`` with a track the owner can read. The worker is driven
with ``process_one`` (no thread), built from the kwargs the app passed."""

import uuid

import pytest
from fastapi.testclient import TestClient

from app.services import upload_commit as upload_commit_mod
from app.services.upload_commit import UploadCommitWorker
from app.services.upload_publish import UploadPublisher
from tests.test_upload_commit_app import FakeCommit
from tests.upload_commit_fixtures import FakeArt, FakeExact, FakeTagWriter
from tests.upload_commit_fixtures import ready_item
from tests.upload_validation_fixtures import FakeProbe, FakeRegistry

ON = {"ENABLE_UPLOAD_COMMIT_WORKER": "true"}


@pytest.fixture
def fake_commit(monkeypatch):
    FakeCommit.instances, FakeCommit.events = [], []
    monkeypatch.setattr(upload_commit_mod, "UploadCommitWorker", FakeCommit)
    return FakeCommit


def test_the_worker_publishes_through_the_apps_publisher(configure_app, fake_commit):
    with TestClient(configure_app(env=ON).app) as c:
        [worker] = fake_commit.instances
        publisher = worker.kwargs["after_prepared"]
        state = c.app.state
        assert isinstance(publisher, UploadPublisher)
        assert publisher._identity_signal is state.identity_wakeup
        assert publisher._cover_art is state.cover_art_manager
        assert publisher._fingerprinter_present == (state.fingerprinter is not None)
        assert publisher._uploads_root == state.upload_receipt.uploads_root
        assert publisher._music_library_dir == state.settings.music_library_dir.resolve()
        assert publisher._database is state.database


def test_a_commit_accepted_through_the_api_ends_imported(open_app_client, fake_commit):
    with open_app_client(env=ON) as c:
        state = c.app.state
        [fake] = fake_commit.instances
        staged = ready_item(state.database, state.upload_receipt.uploads_root,
                            owner_id=state.admin_user_id)
        op = str(uuid.uuid4())
        r = c.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit", json={
            "operation_uuid": op, "base_review_version": 0, "edits": {"title": "Published"},
            "write_tags": False, "acknowledged_duplicates": {"library_tracks": [], "staged_items": []}})
        assert r.status_code == 202, r.text

        kwargs = {**fake.kwargs, "probe": FakeProbe(), "compute_exact": FakeExact(),
                  "write_tags": FakeTagWriter(), "extract_art": FakeArt(None),
                  "registry": FakeRegistry()}
        assert UploadCommitWorker(state.database, **kwargs).process_one() == "imported"

        item = c.get(f"/tracks/uploads/items/{staged['item_uuid']}").json()
        assert item["state"] == "imported"
        track = c.get(f"/tracks/{item['result_track_uuid']}")
        assert track.status_code == 200, track.text
        assert track.json()["metadata"]["title"] == "Published"
        assert c.post(f"/tracks/uploads/items/{staged['item_uuid']}/commit", json={
            "operation_uuid": op, "base_review_version": 0, "edits": {"title": "Published"},
            "write_tags": False,
            "acknowledged_duplicates": {"library_tracks": [], "staged_items": []}}).status_code == 200
