"""Phase M.2a (M-U16, spec §6.3 "Scanning", decision O2 / DEV-M-02).

- At startup the server creates a ``USER_IMPORT_DIR/<folder>/`` for every user
  (the master admin's included), then scans ``IMPORT_DIR`` and every user
  folder, so a file dropped while the server was down is imported.
- ``IMPORT_DIR`` still feeds the master admin.
- Files that fail are retried once per restart and logged.
"""

import logging

import pytest
from fastapi.testclient import TestClient

from tests.import_startup_fixtures import WATCH, _drain_imports, _tone, requires_ffmpeg
from tests.owned_database import add_test_user


pytestmark = pytest.mark.usefixtures("fast_stability_poll")


def _titles(library):
    return sorted(t.metadata.title for t in library.get_tracks())


def test_startup_creates_an_import_folder_for_every_user(configure_app, tmp_path):
    with TestClient(configure_app().app) as c:
        add_test_user(c.app.state.database, "sam")

    with TestClient(configure_app().app) as c:
        admin_folder = c.app.state.database.get_user(c.app.state.admin_user_id)[
            "library_folder"
        ]

    assert (tmp_path / "import-users" / admin_folder).is_dir()
    assert (tmp_path / "import-users" / "sam").is_dir()


@requires_ffmpeg
def test_files_dropped_while_the_server_was_down_are_imported_at_startup(
    configure_app, tmp_path
):
    from app.library import Library

    with TestClient(configure_app().app) as c:
        sam_id = add_test_user(c.app.state.database, "sam")
        admin_folder = c.app.state.database.get_user(c.app.state.admin_user_id)[
            "library_folder"
        ]
    _tone(tmp_path / "import" / "Airbag.mp3", "Airbag")
    _tone(tmp_path / "import-users" / "Sam" / "Lucky.mp3", "Lucky")
    _tone(tmp_path / "import-users" / admin_folder / "Karma Police.mp3", "Karma Police")

    with TestClient(configure_app(env=WATCH).app) as c:
        _drain_imports(c)
        admin = c.app.state.admin_library
        sam = Library(c.app.state.database, sam_id)

        assert _titles(admin) == ["Airbag", "Karma Police"]
        assert _titles(sam) == ["Lucky"]


def test_a_file_that_fails_is_logged_and_retried_at_the_next_startup(
    configure_app, tmp_path, caplog
):
    bad = tmp_path / "import-users" / "sam" / "broken.mp3"
    with TestClient(configure_app().app) as c:
        sam = add_test_user(c.app.state.database, "sam")
    bad.parent.mkdir(parents=True, exist_ok=True)
    bad.write_bytes(b"not audio")

    for _ in range(2):
        caplog.clear()
        with caplog.at_level(logging.INFO):
            with TestClient(configure_app(env=WATCH).app) as c:
                _drain_imports(c)
        # Logged at each start: the file by its name in the import folder and
        # the user it belongs to, never by its full path.
        messages = [r.getMessage() for r in caplog.records if "broken.mp3" in r.getMessage()]
        assert f"import failed: broken.mp3 of user {sam} (fails_check)" in messages, messages
        assert not any(str(tmp_path) in m or str(tmp_path.resolve()) in m for m in messages)
        assert bad.exists()


def test_each_watcher_starts_before_its_startup_scan(configure_app, monkeypatch):
    """Review r1 m-R1-11: a file created between the scan and the observer
    start would wait for the next restart. Observing first, then scanning,
    leaves no gap (``_submit_new`` dedupes a file seen by both)."""
    from app.services.file_watcher import FileWatcher

    calls = []
    real_start, real_scan = FileWatcher.start_file_watcher, FileWatcher.scan_existing

    def start(self):
        calls.append(("start", self.import_dir.name))
        return real_start(self)

    def scan(self, directory=None):
        calls.append(("scan", self.import_dir.name))
        return real_scan(self, directory)

    monkeypatch.setattr(FileWatcher, "start_file_watcher", start)
    monkeypatch.setattr(FileWatcher, "scan_existing", scan)

    with TestClient(configure_app(env=WATCH).app):
        pass

    for name in ("import", "import-users"):
        assert calls.index(("start", name)) < calls.index(("scan", name)), calls


def test_the_workspace_sweep_runs_before_any_watcher_or_scan(configure_app, monkeypatch):
    """Pre-merge A2-04: the sweep deletes every unpack folder, which is safe only
    while no import runs. Run after a watcher or the start-up scan, it could
    remove the folder of an archive that scan is unpacking."""
    from app.services.file_watcher import FileWatcher

    calls = []
    main = configure_app(env=WATCH)
    real_sweep = main.sweep_workspace
    real_start, real_scan = FileWatcher.start_file_watcher, FileWatcher.scan_existing

    def sweep(root):
        calls.append("sweep")
        return real_sweep(root)

    def start(self):
        calls.append("start " + self.import_dir.name)
        return real_start(self)

    def scan(self, directory=None):
        calls.append("scan " + self.import_dir.name)
        return real_scan(self, directory)

    monkeypatch.setattr(main, "sweep_workspace", sweep)
    monkeypatch.setattr(FileWatcher, "start_file_watcher", start)
    monkeypatch.setattr(FileWatcher, "scan_existing", scan)

    with TestClient(main.app):
        pass

    assert calls[0] == "sweep", calls
    assert calls.count("sweep") == 1, calls
    assert {"start import", "start import-users", "scan import", "scan import-users"} <= set(calls), calls


@requires_ffmpeg
def test_admin_tracks_imported_by_the_startup_scan_are_prewarmed(
    configure_app, tmp_path, monkeypatch
):
    """Live gate m-L-02 (M-L02, spec §6.1): the startup pre-warm snapshot is
    taken before the scans, yet the admin's tracks they import are warmed at
    the admin's quality on that same start. A friend's import never is."""
    from app.library import Library
    from app.services.encoder_coordinator import EncoderCoordinator
    from tests.quality_fixtures import _store_quality

    with TestClient(configure_app().app) as c:
        sam_id = add_test_user(c.app.state.database, "sam")
        _store_quality(c, "192")
    _tone(tmp_path / "import" / "Airbag.mp3", "Airbag")
    _tone(tmp_path / "import-users" / "Sam" / "Lucky.mp3", "Lucky")
    warmed = []
    monkeypatch.setattr(
        EncoderCoordinator,
        "_warm_one",
        lambda self, uuid_id, quality, generation: warmed.append((uuid_id, quality)),
    )

    with TestClient(configure_app(env=WATCH).app) as c:
        _drain_imports(c)
        c.app.state.encoder_coordinator.drain()
        admin_uuids = [t.uuid_id for t in c.app.state.admin_library.get_tracks()]
        sam_uuids = [t.uuid_id for t in Library(c.app.state.database, sam_id).get_tracks()]

    assert len(admin_uuids) == 1 and len(sam_uuids) == 1
    assert set(warmed) == {(admin_uuids[0], "192")}
