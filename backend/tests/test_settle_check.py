"""Live gate m-L-08, decision DEV-M-15 ("settle check").

A loose file whose copy paused for longer than the quiet window was imported
from the partial file; the copy then kept writing into the moved library file.
After a file is organized into the library, the import records the size and
modification time it was read at. A deferred check re-reads them after a
settle window much longer than the quiet window; if they changed, the track is
refreshed (row fields re-read, caches dropped, the admin's re-warmed) and the
check repeats until one full window passes with no change. It uses the
injected clock, is stopped by the stop flag and holds no lock while waiting.
"""

import os
import threading
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from app.database import DatabaseContext
from app.models import TrackMetaData
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.file_watcher import STABILITY_QUIET_WINDOW_S
from app.services.import_outcome import ImportOutcome, file_signature
from app.services.pipeline import make_pipeline
from app.services.settle_check import SETTLE_WINDOW_S, SettleCheck
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL


class FakeClock:
    def __init__(self, now: float = 1000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def _file(tmp_path: Path, data: bytes = b"partial") -> Path:
    path = tmp_path / "music" / "song.flac"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def _grow(path: Path, data: bytes = b" more") -> None:
    with open(path, "ab") as f:
        f.write(data)


@pytest.fixture
def setup(tmp_path):
    clock = FakeClock()
    refresh = MagicMock(return_value=True)
    check = SettleCheck(refresh=refresh, clock=clock, stop_event=threading.Event())
    return check, refresh, clock, tmp_path


def test_the_settle_window_is_one_constant_much_longer_than_the_quiet_window():
    assert 20 <= SETTLE_WINDOW_S <= 60
    assert SETTLE_WINDOW_S >= 10 * STABILITY_QUIET_WINDOW_S


def test_an_unchanged_file_is_dropped_after_one_window_without_a_refresh(setup):
    check, refresh, clock, tmp = setup
    path = _file(tmp)
    check.schedule("u1", 7, path, file_signature(path))

    clock.advance(SETTLE_WINDOW_S - 0.1)
    check.run_due()
    assert check.pending() == ["u1"]  # not due yet

    clock.advance(0.2)
    check.run_due()
    refresh.assert_not_called()
    assert check.pending() == []


def test_a_file_that_changed_is_refreshed_and_checked_again_until_quiet(setup):
    check, refresh, clock, tmp = setup
    path = _file(tmp)
    check.schedule("u1", 7, path, file_signature(path))

    _grow(path)  # the copy resumed into the library file
    clock.advance(SETTLE_WINDOW_S)
    check.run_due()
    refresh.assert_called_once_with("u1", 7, path)
    assert check.pending() == ["u1"]

    _grow(path)  # still writing one window later
    clock.advance(SETTLE_WINDOW_S)
    check.run_due()
    assert refresh.call_count == 2
    assert check.pending() == ["u1"]

    clock.advance(SETTLE_WINDOW_S)  # one full window with no change
    check.run_due()
    assert refresh.call_count == 2
    assert check.pending() == []


def test_a_change_is_measured_against_the_signature_the_import_read(setup):
    """The file grew between the read and the schedule: still a change."""
    check, refresh, clock, tmp = setup
    path = _file(tmp)
    read_at = file_signature(path)
    _grow(path)
    check.schedule("u1", 7, path, read_at)

    clock.advance(SETTLE_WINDOW_S)
    check.run_due()
    refresh.assert_called_once_with("u1", 7, path)


def test_a_modification_time_change_alone_counts(setup):
    check, refresh, clock, tmp = setup
    path = _file(tmp)
    check.schedule("u1", 7, path, file_signature(path))
    st = os.stat(path)
    os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000))

    clock.advance(SETTLE_WINDOW_S)
    check.run_due()
    refresh.assert_called_once()


def test_a_file_gone_from_its_path_is_dropped_without_a_refresh(setup):
    """Deleted or re-organized (moved) meanwhile."""
    check, refresh, clock, tmp = setup
    path = _file(tmp)
    check.schedule("u1", 7, path, file_signature(path))
    path.rename(path.with_name("moved.flac"))

    clock.advance(SETTLE_WINDOW_S)
    check.run_due()
    refresh.assert_not_called()
    assert check.pending() == []


def test_a_track_the_refresh_no_longer_finds_is_dropped(setup):
    check, refresh, clock, tmp = setup
    refresh.return_value = False  # the row is gone or points elsewhere
    path = _file(tmp)
    check.schedule("u1", 7, path, file_signature(path))
    _grow(path)

    clock.advance(SETTLE_WINDOW_S)
    check.run_due()
    refresh.assert_called_once()
    assert check.pending() == []


def test_a_refresh_that_raises_is_logged_and_the_check_goes_on(setup, caplog):
    check, refresh, clock, tmp = setup
    refresh.side_effect = [OSError("disk"), True]
    a, b = _file(tmp), _file(tmp / "b")
    check.schedule("ua", 7, a, file_signature(a))
    check.schedule("ub", 7, b, file_signature(b))
    _grow(a)
    _grow(b)

    clock.advance(SETTLE_WINDOW_S)
    check.run_due()
    assert refresh.call_count == 2
    assert "ua" in caplog.text


def test_entries_are_independent_and_rescheduling_replaces(setup):
    check, refresh, clock, tmp = setup
    a, b = _file(tmp), _file(tmp / "b")
    check.schedule("ua", 7, a, file_signature(a))
    clock.advance(SETTLE_WINDOW_S / 2)
    check.schedule("ub", 8, b, file_signature(b))
    check.schedule("ub", 8, b, file_signature(b))  # imported again: one entry

    clock.advance(SETTLE_WINDOW_S / 2)
    check.run_due()
    assert check.pending() == ["ub"]


def test_scheduling_never_waits_for_a_running_check(setup):
    """No lock is held while a refresh runs or while waiting."""
    check, refresh, clock, tmp = setup
    a, b = _file(tmp), _file(tmp / "b")
    entered, release = threading.Event(), threading.Event()

    def slow_refresh(uuid_id, owner_id, path):
        entered.set()
        release.wait(5)
        return True

    refresh.side_effect = slow_refresh
    check.schedule("ua", 7, a, file_signature(a))
    _grow(a)
    clock.advance(SETTLE_WINDOW_S)
    runner = threading.Thread(target=check.run_due)
    runner.start()
    assert entered.wait(5)

    scheduled = threading.Thread(target=check.schedule, args=("ub", 7, b, file_signature(b)))
    scheduled.start()
    scheduled.join(2)
    alive = scheduled.is_alive()
    release.set()
    runner.join(5)
    assert not alive
    assert sorted(check.pending()) == ["ua", "ub"]


def test_the_stop_flag_ends_the_background_check(tmp_path):
    stop = threading.Event()
    refresh = MagicMock(return_value=True)
    check = SettleCheck(refresh=refresh, clock=FakeClock(), stop_event=stop)
    path = _file(tmp_path)
    check.schedule("u1", 7, path, file_signature(path))
    check.start()

    stop.set()
    check.join(timeout=5)

    assert not check.is_running()
    refresh.assert_not_called()  # an entry pending at stop is lost, not run


# ── The import reports what it read ──────────────────────────────────────────


@pytest.fixture
def pipeline_env(tmp_path):
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    sam = add_test_user(db, "Sam")
    on_imported = MagicMock()
    organizer, _ = make_pipeline(
        db.get_user(sam),
        database=db,
        cover_art_manager=manager,
        music_library_dir=tmp_path / "music",
        workspace_root=tmp_path / "data" / "workspace",
        on_imported=on_imported,
    )
    return db, sam, organizer, on_imported, tmp_path


_META = TrackMetaData(title="Lucky", artist="Radiohead", album="OK Computer", codec="flac", duration=30.0)


def test_an_organized_file_reports_its_track_owner_library_path_and_read_signature(pipeline_env):
    db, sam, organizer, on_imported, tmp = pipeline_env
    source = tmp / "import" / "lucky.flac"
    source.parent.mkdir(parents=True)
    source.write_bytes(b"partial flac")
    read_at = file_signature(source)

    with patch("app.services.organizer.get_track_metadata", return_value=_META):
        assert organizer.organize(source) is ImportOutcome.IMPORTED

    (track,) = db.get_tracks(owner_id=sam)
    on_imported.assert_called_once()
    uuid_id, owner_id, path, signature = on_imported.call_args.args
    assert (uuid_id, owner_id) == (track.uuid_id, sam)
    assert Path(path) == Path(track.file_path) and Path(path).exists()
    assert signature == read_at


def test_a_file_that_is_not_imported_reports_nothing(pipeline_env):
    db, sam, organizer, on_imported, tmp = pipeline_env
    source = tmp / "import" / "lucky.flac"
    source.parent.mkdir(parents=True)
    source.write_bytes(b"x")

    with patch("app.services.organizer.get_track_metadata", return_value=None):
        assert organizer.organize(source) is ImportOutcome.FAILS_CHECK

    on_imported.assert_not_called()
