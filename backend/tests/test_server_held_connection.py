"""The server holds one idle database connection
from start-up to shutdown (``Database.hold_open`` / ``close``; the rules of
the held connection itself are in ``test_database_held_connection.py``).

- While the server runs, a call's close is never the last: the write-ahead log
  stays in place between requests.
- The shutdown closes it; that close is the last, so it checkpoints: the log
  is empty or gone, every row is in the database file and no descriptor is left open.
- A failed start-up closes it too (it runs the shutdown's teardown).
- A second start in the same process holds a connection of its own.

The place of the close among the stop steps is pinned with the others in
``test_worker_teardown.py``.
"""

import pytest
from fastapi.testclient import TestClient

from tests.database_file_probes import (
    file_identities,
    log_bytes,
    open_in_this_process,
    setting_in_the_main_file_alone,
)


@pytest.fixture
def database_path(tmp_path):
    return tmp_path / "data" / "database" / "database.db"


def test_the_running_server_keeps_the_log_between_requests(open_app_client, database_path, tmp_path):
    with open_app_client() as client:  # signing in wrote a session row
        assert client.get("/").status_code == 200

        assert log_bytes(database_path) > 0
        assert "database.db" in open_in_this_process(file_identities(database_path))


def test_a_row_written_while_serving_is_not_checkpointed_by_its_calls_close(
        configure_app, database_path, tmp_path):
    main = configure_app()

    with TestClient(main.app):
        main.app.state.database.set_setting("probe", "written while serving")

        assert setting_in_the_main_file_alone(database_path, tmp_path) is None
        assert main.app.state.database.read_setting("probe") == "written while serving"


def test_the_shutdown_closes_it_and_that_last_close_checkpoints(configure_app, database_path, tmp_path):
    main = configure_app()

    with TestClient(main.app):
        main.app.state.database.set_setting("probe", "written while serving")
        files = file_identities(database_path)
        assert "database.db" in open_in_this_process(files)

    assert open_in_this_process(files) == []
    assert log_bytes(database_path) == 0
    assert setting_in_the_main_file_alone(database_path, tmp_path) == "written while serving"


class StartupFailed(RuntimeError):
    pass


def test_a_failed_startup_closes_it(configure_app, monkeypatch, database_path):
    main = configure_app()
    real = main._startup_locked
    seen = {}

    def startup_then_fail():
        real()
        seen["files"] = file_identities(database_path)
        seen["held"] = open_in_this_process(seen["files"])
        raise StartupFailed("a later start-up step failed")

    monkeypatch.setattr(main, "_startup_locked", startup_then_fail)

    with pytest.raises(StartupFailed):
        with TestClient(main.app):
            pass

    assert "database.db" in seen["held"]
    assert open_in_this_process(seen["files"]) == []
    assert log_bytes(database_path) == 0


def test_a_second_start_of_the_same_app_holds_a_connection_of_its_own(
        configure_app, database_path, tmp_path):
    main = configure_app()
    with TestClient(main.app):
        first = main.app.state.database
        first.set_setting("probe", "first run")

    with TestClient(main.app):
        second = main.app.state.database
        assert second is not first
        assert second.read_setting("probe") == "first run"
        second.set_setting("probe", "second run")
        assert setting_in_the_main_file_alone(database_path, tmp_path) == "first run"
        files = file_identities(database_path)

    assert open_in_this_process(files) == []
    assert log_bytes(database_path) == 0
    assert setting_in_the_main_file_alone(database_path, tmp_path) == "second run"


def test_a_second_server_started_in_the_same_process_works_on_the_same_data(
        open_app_client, database_path, tmp_path):
    """Each ``open_app_client`` loads the server module afresh, as a restart does."""
    with open_app_client() as client:
        assert client.get("/").status_code == 200
    assert log_bytes(database_path) == 0

    with open_app_client() as client:  # signs in as the admin the first start made
        assert client.get("/").status_code == 200
        assert log_bytes(database_path) > 0
        files = file_identities(database_path)

    assert open_in_this_process(files) == []
    assert log_bytes(database_path) == 0
