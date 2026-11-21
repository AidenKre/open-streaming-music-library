"""Review r2 m-R2-03: shutdown with imports in flight.

One stop flag is shared by both watchers and every ingestor. At shutdown both
watchers stop accepting work before either is drained, and they are drained
together against one deadline. A running archive ingest stops at the next
member (the archive stays; every file it put in the library has its row). If
ingests outlive the bound, the instance lock is kept until they end, logged
once, instead of being released under them.
"""

import logging
import threading
import zipfile
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient

from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock
from app.database import DatabaseContext
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.file_watcher import FileWatcher, stop_watchers
from app.services.import_outcome import ImportOutcome
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL
from tests.import_startup_fixtures import WATCH, _tone, requires_ffmpeg


def test_both_watchers_stop_accepting_work_before_either_is_drained(tmp_path):
    stop = threading.Event()
    admin = FileWatcher(tmp_path / "import", MagicMock(), stop_event=stop)
    users = FileWatcher(tmp_path / "import-users", MagicMock(), stop_event=stop)
    running = [MagicMock(done=MagicMock(return_value=False)) for _ in range(2)]
    admin._futures.add(running[0])
    users._futures.add(running[1])
    drains = []

    def drain(futures, timeout):
        drains.append((set(futures), timeout))
        # At the moment of the (single) drain neither watcher takes new work.
        for watcher in (admin, users):
            assert watcher._stopping.is_set()
            with patch.object(watcher.executor, "submit") as submit:
                watcher._submit_new(watcher.import_dir / "late.mp3")
            submit.assert_not_called()
        return set(), set(futures)

    with patch("app.services.file_watcher.wait", side_effect=drain):
        not_done = stop_watchers([admin, users], timeout=30.0)

    assert drains == [(set(running), 30.0)]
    assert not_done == set(running)


def test_a_watcher_built_without_a_shared_flag_has_its_own(tmp_path):
    a = FileWatcher(tmp_path / "a", MagicMock())
    b = FileWatcher(tmp_path / "b", MagicMock())
    assert a._stopping is not b._stopping


@pytest.fixture
def env(tmp_path):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    return db, manager, tmp_path


@requires_ffmpeg
def test_an_archive_ingest_stops_at_the_next_member_and_leaves_no_file_without_a_row(env):
    db, manager, tmp = env
    sam = add_test_user(db, "Sam")
    stop = threading.Event()
    _, ingestor = make_pipeline(
        db.get_user(sam),
        database=db,
        cover_art_manager=manager,
        music_library_dir=tmp / "music",
        workspace_root=tmp / "data" / "workspace",
        on_track_added=lambda uuid, owner: stop.set(),  # shutdown begins after the first track
        stop_event=stop,
    )
    folder = tmp / "import-users" / "sam"
    archive = folder / "album.zip"
    folder.mkdir(parents=True)
    with zipfile.ZipFile(archive, "w") as z:
        for title in ("Airbag", "Lucky"):
            song = tmp / "src" / f"{title}.mp3"
            _tone(song, title)
            z.write(song, f"{title}.mp3")

    outcome = ingestor.ingest(archive, imported_dir=folder / ".imported")

    assert outcome is ImportOutcome.STOPPED
    tracks = db.get_tracks(owner_id=sam)
    assert len(tracks) == 1
    library_files = sorted(p for p in (tmp / "music").rglob("*") if p.is_file())
    assert library_files == sorted(t.file_path for t in tracks)
    assert archive.exists() and not (folder / ".imported").exists()
    assert list((tmp / "data" / "workspace" / f"u{sam}").iterdir()) == []

    stop.clear()
    _, ingestor = make_pipeline(
        db.get_user(sam),
        database=db,
        cover_art_manager=manager,
        music_library_dir=tmp / "music",
        workspace_root=tmp / "data" / "workspace",
        stop_event=stop,
    )
    assert ingestor.ingest(archive, imported_dir=folder / ".imported") is ImportOutcome.IMPORTED
    assert sorted(t.metadata.title for t in db.get_tracks(owner_id=sam)) == ["Airbag", "Lucky"]
    # Airbag was already in the library (duplicate), so the archive is set
    # aside, not deleted (sign-off DEV-M-10: the accepted retry-after-stop case).
    assert [p.name for p in (folder / ".imported").iterdir()] == ["album.zip"]


def test_a_loose_file_is_not_organized_once_stopping(tmp_path):
    from app.services.ingestion import Ingestor, IngestorContext

    song = tmp_path / "import" / "song.mp3"
    song.parent.mkdir()
    song.write_bytes(b"audio")
    organize = MagicMock(return_value=ImportOutcome.IMPORTED)
    ingestor = Ingestor(
        IngestorContext(workspace_dir=tmp_path / "ws", organize_function=organize, should_stop=lambda: True)
    )

    with patch("app.services.ingestion.does_music_pass_quick_check", return_value=True):
        assert ingestor.ingest(song, imported_dir=song.parent / ".imported") is ImportOutcome.STOPPED

    organize.assert_not_called()
    assert song.read_bytes() == b"audio"


def test_the_lock_is_kept_until_an_ingest_that_outlives_the_bound_ends(
    configure_app, tmp_path, monkeypatch, caplog
):
    main = configure_app(env=WATCH)
    monkeypatch.setattr(main, "WATCHER_STOP_TIMEOUT_S", 0.05)
    started, release = threading.Event(), threading.Event()

    def slow_ingest(path):
        started.set()
        assert release.wait(10)
        return True

    with TestClient(main.app) as client:
        watcher = client.app.state.user_file_watcher
        watcher.on_file = slow_ingest
        with patch("app.services.file_watcher.wait_until_ready", return_value=True):
            watcher._submit_new(tmp_path / "import-users" / "x" / "a.mp3")
            assert started.wait(10)
            (future,) = list(watcher._futures)
            caplog.set_level(logging.WARNING)
    # TestClient exit ran the shutdown: the bound passed with the ingest still running.

    with pytest.raises(InstanceLockHeld):
        acquire_instance_lock(tmp_path / "data").release()
    kept = [
        r for r in caplog.records
        if "keep" in r.getMessage().lower() and "lock" in r.getMessage().lower()
    ]
    assert len(kept) == 1, [r.getMessage() for r in kept]

    release.set()
    future.result(timeout=10)
    watcher.executor.shutdown(wait=True)  # its done-callbacks have run
    lock = acquire_instance_lock(tmp_path / "data")  # released once it ended
    lock.release()
