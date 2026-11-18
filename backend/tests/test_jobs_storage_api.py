"""Phase 7A.2a: POST /jobs answers a storage refusal with the SC-22 envelope.

507, a stable code, retryable, the needed byte count, and never a path.
Review r2 7-R2-06: no ``available`` figure (it moves with other users'
reservations); unknown free space has its own code, never 0.
"""

from types import SimpleNamespace

from tests.jobs_api_fixtures import _post_job
from tests.test_jobs_api import (
    _add_track_with_file,
    client,
    held_client,
)

MIB = 1024 * 1024


def _disk(client, fn):
    client.app.state.conversion_orchestrator.storage_ledger._disk_usage = fn


def test_a_conversion_without_room_answers_507_with_the_typed_envelope(held_client, tmp_path):
    client = held_client
    track = _add_track_with_file(client, tmp_path, codec="flac")
    _disk(client, lambda _p: SimpleNamespace(free=1))

    r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

    assert r.status_code == 507, r.text
    detail = r.json()["detail"]
    floor = client.app.state.settings.storage_free_space_floor_bytes
    assert {k: detail[k] for k in ("error", "retryable")} == {
        "error": "insufficient_storage", "retryable": True,
    }
    assert "available" not in detail  # review r2 7-R2-06: no server-wide figure
    # 1.0 s of 192 kbps AAC = 24000 bytes; x2.2 + 16 MiB headroom.
    assert detail["needed"] == int(24000 * 2.2) + 16 * MIB
    assert floor > 1  # the floor alone already refuses
    assert str(tmp_path) not in r.text and "/" not in detail["message"]
    assert client.held.submitted == []
    assert client.get("/jobs").json()["data"] == []


def test_unknown_free_space_answers_507_with_available_null(held_client, tmp_path):
    client = held_client
    track = _add_track_with_file(client, tmp_path, codec="flac")

    def unreadable(path):
        raise OSError(5, "I/O error", str(path))

    _disk(client, unreadable)

    r = _post_job(client, track.uuid_id, "aac", track.revision, 192)

    assert r.status_code == 507, r.text
    detail = r.json()["detail"]
    assert (detail["error"], detail["retryable"]) == ("free_space_unknown", True)
    assert "available" not in detail  # unknown is never reported as 0 either
    assert str(tmp_path) not in r.text
    assert client.held.submitted == []


def test_a_refusal_carries_no_figure_that_moves_with_other_users(held_client, tmp_path):
    """Review r2 7-R2-06 (as 7-R1-19 for uploads): the caller learns what is
    needed, never the free room, which moves with other users' reservations."""
    from app.services.storage_ledger import CONVERSION
    from tests.owned_database import add_test_user

    client = held_client
    track = _add_track_with_file(client, tmp_path, codec="flac")
    floor = client.app.state.settings.storage_free_space_floor_bytes
    _disk(client, lambda _p: SimpleNamespace(free=floor + 10 * MIB))  # some room, not enough
    first = _post_job(client, track.uuid_id, "aac", track.revision, 192)

    other = add_test_user(client.app.state.database, "bob")
    client.app.state.storage_ledger.reserve(owner_id=other, purpose=CONVERSION, nbytes=4 * MIB)
    second = _post_job(client, track.uuid_id, "aac", track.revision, 192)

    assert first.status_code == second.status_code == 507
    assert first.json() == second.json()
    detail = first.json()["detail"]
    assert "available" not in detail
    assert str(10 * MIB) not in detail["message"] and str(6 * MIB) not in detail["message"]
    assert detail["needed"] == int(24000 * 2.2) + 16 * MIB
