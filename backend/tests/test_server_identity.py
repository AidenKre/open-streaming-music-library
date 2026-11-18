"""SC-01 backend / SC-03 `server` block (5-T19 backend side, 5-T17 oracle).

The server persists a random UUID v4 ``server_instance_id`` in
``app_settings``, created for fresh databases and by the Phase 5 migration for
existing ones, never regenerated (restart, migration, settings change), and
advertises it as ``/app/info`` -> ``server: {instance_id}``.
"""

import uuid

from tests.schema_fixtures import open_database


def _assert_uuid4(value):
    assert isinstance(value, str)
    parsed = uuid.UUID(value)
    assert parsed.version == 4
    assert str(parsed) == value  # canonical lowercase hyphenated form


def test_fresh_database_gets_an_instance_id(tmp_path):
    db = open_database(tmp_path / "database.db")
    instance_id = db.get_server_instance_id()
    _assert_uuid4(instance_id)
    assert db.get_setting("server_instance_id") == instance_id


def test_instance_id_survives_restart_and_settings_writes(tmp_path):
    path = tmp_path / "database.db"
    first = open_database(path).get_server_instance_id()

    restarted = open_database(path)
    assert restarted.get_server_instance_id() == first
    restarted.set_setting("default_streaming_quality", "320")
    assert restarted.get_server_instance_id() == first
    assert open_database(path).get_server_instance_id() == first


def test_distinct_databases_have_distinct_ids(tmp_path):
    a = open_database(tmp_path / "a" / "database.db").get_server_instance_id()
    b = open_database(tmp_path / "b" / "database.db").get_server_instance_id()
    assert a != b


def test_app_info_advertises_the_server_block(open_app_client):
    with open_app_client(music_dir="data-music", import_dir="data-import") as client:
        info = client.get("/app/info").json()
        stored = client.app.state.database.get_server_instance_id()
    assert info["server"] == {"instance_id": stored}
    _assert_uuid4(info["server"]["instance_id"])
    # Existing blocks are unchanged.
    assert "track" in info["entities"]
    assert "conversion" in info


def test_app_info_instance_id_is_stable_across_app_restarts(open_app_client):
    with open_app_client(music_dir="data-music", import_dir="data-import") as client:
        first = client.get("/app/info").json()["server"]["instance_id"]
    with open_app_client(music_dir="data-music", import_dir="data-import") as client:
        second = client.get("/app/info").json()["server"]["instance_id"]
    assert first == second
