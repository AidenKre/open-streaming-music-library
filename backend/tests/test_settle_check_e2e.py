"""Live gate m-L-08, decision DEV-M-15, end to end through the real app.

A loose FLAC is imported while its copy is paused for longer than the quiet
window (the partial file passes every check), the admin's pre-warm encodes
the partial file, then the copy resumes into the moved library file. After
the settle window (an injected clock, no real waits) the row's duration and
bitrate equal a reference import of the whole file, the admin's cache entry
is rebuilt from the whole file and a friend's track is never put into
``default_cache``.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.library import Library
from app.services.encoder_coordinator import EncoderCoordinator
from app.services.file_watcher import FileWatcher
from app.services.import_outcome import ImportOutcome
from app.services.settle_check import SETTLE_WINDOW_S, SettleCheck
from tests.owned_database import add_test_user
from tests.quality_fixtures import _store_quality
from tests.track_paths import set_track_path

pytestmark = [
    pytest.mark.usefixtures("fast_stability_poll"),
    pytest.mark.requires_ffmpeg,  # registered marker (plan D16)
]

WATCH = {"ENABLE_FILE_WATCHER": "true"}
QUALITY = "128"


class FakeClock:
    def __init__(self, now: float = 1000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


def _noisy_flac(path: Path) -> bytes:
    """4 s of sine + pink noise: a bitrate well above the 128 kbps pre-warm."""
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
         "-f", "lavfi", "-i", "anoisesrc=color=pink:duration=4:amplitude=0.3",
         "-filter_complex", "amix=inputs=2:duration=shortest",
         "-metadata", "artist=Radiohead", "-metadata", "album=OK Computer",
         "-metadata", "title=Lucky", "-c:a", "flac", str(path)],
        check=True,
    )
    return path.read_bytes()


def _decoded_seconds(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout
    return float(json.loads(out)["format"]["duration"])


@pytest.fixture
def app(configure_app, tmp_path, monkeypatch):
    with TestClient(configure_app().app) as c:
        sam = add_test_user(c.app.state.database, "sam")
        _store_quality(c, QUALITY)
    # Deterministic: the test drives the check and the warm pool itself.
    monkeypatch.setattr(SettleCheck, "start", lambda self: None)
    # The watchers are built (the test calls their on_file) but never observe
    # the folders: a real watcher would race the direct ingests (7-R1-07).
    monkeypatch.setattr(FileWatcher, "start_file_watcher", lambda self: None)
    monkeypatch.setattr(
        EncoderCoordinator,
        "_submit_warm",
        lambda self, uuid_id, quality, generation: self._warm_one(uuid_id, quality, generation),
    )
    with TestClient(configure_app(env=WATCH).app) as c:
        clock = FakeClock()
        c.app.state.settle_check.clock = clock
        yield c, sam, clock, tmp_path


def test_the_fixture_runs_no_real_file_watcher(app):
    """Review r1 7-R1-07: a real watcher would race the direct ingest calls
    below (its stable check ingests the file first, the direct call then
    meets an existing destination). The test drives every ingest itself."""
    c, *_ = app
    for watcher in (c.app.state.file_watcher, c.app.state.user_file_watcher):
        assert watcher.observer is None or not watcher.observer.is_alive()


def _only_track(library, title_file: str):
    (track,) = [t for t in library.get_tracks(limit=1000) if Path(t.file_path).name == title_file]
    return track


def test_a_partial_import_is_corrected_after_the_copy_resumes(app):
    c, sam, clock, tmp = app
    whole = _noisy_flac(tmp / "fixtures" / "lucky.flac")
    cut = len(whole) // 4
    admin = c.app.state.admin_library
    friend = Library(c.app.state.database, sam)
    default_cache = c.app.state.default_cache

    # Reference imports of the whole file (another name: not a duplicate).
    (tmp / "import" / "ref.flac").write_bytes(whole)
    assert c.app.state.ingestor.ingest(tmp / "import" / "ref.flac") is ImportOutcome.IMPORTED
    (tmp / "import-users" / "sam" / "ref.flac").write_bytes(whole)
    c.app.state.user_file_watcher.on_file(tmp / "import-users" / "sam" / "ref.flac")
    admin_ref = _only_track(admin, "ref.flac")
    friend_ref = _only_track(friend, "ref.flac")

    # The copy pauses after a quarter: the partial file is imported.
    (tmp / "import" / "loose.flac").write_bytes(whole[:cut])
    assert c.app.state.ingestor.ingest(tmp / "import" / "loose.flac") is ImportOutcome.IMPORTED
    (tmp / "import-users" / "sam" / "loose.flac").write_bytes(whole[:cut])
    c.app.state.user_file_watcher.on_file(tmp / "import-users" / "sam" / "loose.flac")
    admin_partial = _only_track(admin, "loose.flac")
    friend_partial = _only_track(friend, "loose.flac")

    # Preconditions: the partial import is wrong and so is the admin's warm.
    assert admin_partial.metadata.bitrate_kbps != admin_ref.metadata.bitrate_kbps
    warmed = default_cache.get(admin_partial.uuid_id, QUALITY)
    assert warmed is not None
    assert _decoded_seconds(warmed) < _decoded_seconds(Path(admin_ref.file_path)) - 1
    assert not default_cache.has(friend_partial.uuid_id, QUALITY)

    # The copy resumes into the moved library files.
    for track in (admin_partial, friend_partial):
        with open(track.file_path, "ab") as f:
            f.write(whole[cut:])

    clock.now += SETTLE_WINDOW_S - 1
    c.app.state.settle_check.run_due()
    assert admin.get_track_by_uuid(admin_partial.uuid_id).metadata.bitrate_kbps == (
        admin_partial.metadata.bitrate_kbps
    ), "nothing happens before the settle window"

    clock.now += 2
    c.app.state.settle_check.run_due()

    for library, partial, ref in ((admin, admin_partial, admin_ref), (friend, friend_partial, friend_ref)):
        fixed = library.get_track_by_uuid(partial.uuid_id)
        assert fixed.metadata.duration == ref.metadata.duration
        assert fixed.metadata.bitrate_kbps == ref.metadata.bitrate_kbps
        assert fixed.metadata.codec == ref.metadata.codec
        assert fixed.metadata.title == "Lucky"
        assert fixed.revision > partial.revision  # clients sync the correction

    rebuilt = default_cache.get(admin_partial.uuid_id, QUALITY)
    assert rebuilt is not None
    assert abs(_decoded_seconds(rebuilt) - _decoded_seconds(Path(admin_ref.file_path))) < 0.2
    assert not default_cache.has(friend_partial.uuid_id, QUALITY)
    assert not any(friend_partial.uuid_id in p.name for p in default_cache.ctx.cache_dir.iterdir())

    # One more quiet window ends the check for every track.
    clock.now += SETTLE_WINDOW_S + 1
    c.app.state.settle_check.run_due()
    assert c.app.state.settle_check.pending() == []


def test_a_track_deleted_during_the_window_is_skipped(app):
    c, sam, clock, tmp = app
    whole = _noisy_flac(tmp / "fixtures" / "lucky.flac")
    (tmp / "import" / "loose.flac").write_bytes(whole[: len(whole) // 4])
    assert c.app.state.ingestor.ingest(tmp / "import" / "loose.flac") is ImportOutcome.IMPORTED
    track = _only_track(c.app.state.admin_library, "loose.flac")
    with open(track.file_path, "ab") as f:
        f.write(whole[len(whole) // 4:])
    assert c.app.state.admin_library.delete_track(track.uuid_id)

    clock.now += SETTLE_WINDOW_S + 1
    c.app.state.settle_check.run_due()

    assert c.app.state.admin_library.get_track_by_uuid(track.uuid_id) is None
    assert not c.app.state.default_cache.has(track.uuid_id, QUALITY)
    assert c.app.state.settle_check.pending() == []


def test_a_track_relocated_by_an_edit_during_the_window_is_skipped(app, monkeypatch):
    c, sam, clock, tmp = app
    whole = _noisy_flac(tmp / "fixtures" / "lucky.flac")
    (tmp / "import" / "loose.flac").write_bytes(whole[: len(whole) // 4])
    assert c.app.state.ingestor.ingest(tmp / "import" / "loose.flac") is ImportOutcome.IMPORTED
    track = _only_track(c.app.state.admin_library, "loose.flac")
    old_path = Path(track.file_path)
    # The row now points elsewhere (as after an edit that re-organized it),
    # while something still grows the old path.
    moved = old_path.with_name("elsewhere.flac")
    shutil.copy(old_path, moved)
    set_track_path(c, track.uuid_id, moved)
    with open(old_path, "ab") as f:
        f.write(whole[len(whole) // 4:])
    refreshed = c.app.state.admin_library.get_track_by_uuid(track.uuid_id)

    clock.now += SETTLE_WINDOW_S + 1
    c.app.state.settle_check.run_due()

    after = c.app.state.admin_library.get_track_by_uuid(track.uuid_id)
    assert after.revision == refreshed.revision
    assert after.metadata.bitrate_kbps == track.metadata.bitrate_kbps
    assert c.app.state.settle_check.pending() == []
