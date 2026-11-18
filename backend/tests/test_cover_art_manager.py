from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import hashlib
import sqlite3
from io import BytesIO
from pathlib import Path
from threading import Barrier
from unittest.mock import patch

import pytest
from PIL import Image

from tests.owned_database import OwnedTestDatabase
from app.database.database import Database, DatabaseContext
from app.services.cover_art_manager import CoverArtContext, CoverArtManager


def _create_database(tmp_path: Path) -> Database:
    database_path = tmp_path / "database.db"
    context = DatabaseContext(
        database_path=database_path,
        init_sql_path=Path(__file__).parent.parent / "app" / "database" / "init.sql",
    )
    db = OwnedTestDatabase(context=context)
    db.initialize()
    return db


def _create_manager(tmp_path: Path, database: Database | None = None) -> CoverArtManager:
    if database is None:
        database = _create_database(tmp_path)
    cover_art_dir = tmp_path / "cover_art"
    ctx = CoverArtContext(cover_art_dir=cover_art_dir, database=database)
    return CoverArtManager(ctx=ctx)


def _make_png_bytes(width: int = 100, height: int = 100, color: tuple = (255, 0, 0)) -> bytes:
    """Create a PNG with a gradient pattern to produce a unique phash per color."""
    img = Image.new("RGB", (width, height))
    for x in range(width):
        for y in range(height):
            r = (color[0] * x) // max(width - 1, 1)
            g = (color[1] * y) // max(height - 1, 1)
            b = (color[2] * (x + y)) // max(width + height - 2, 1)
            img.putpixel((x, y), (r, g, b))
    buf = BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _make_jpeg_bytes(width: int = 100, height: int = 100, color: tuple = (0, 255, 0)) -> bytes:
    """Create a JPEG with a gradient pattern."""
    img = Image.new("RGB", (width, height))
    for x in range(width):
        for y in range(height):
            r = (color[0] * x) // max(width - 1, 1)
            g = (color[1] * y) // max(height - 1, 1)
            b = (color[2] * (x + y)) // max(width + height - 2, 1)
            img.putpixel((x, y), (r, g, b))
    buf = BytesIO()
    img.save(buf, format="JPEG")
    return buf.getvalue()


class TestCoverArtManagerInit:
    def test_creates_cover_art_directory(self, tmp_path: Path):
        cover_art_dir = tmp_path / "cover_art"
        assert not cover_art_dir.exists()

        db = _create_database(tmp_path)
        ctx = CoverArtContext(cover_art_dir=cover_art_dir, database=db)
        CoverArtManager(ctx=ctx)

        assert cover_art_dir.is_dir()

    def test_does_not_fail_if_directory_already_exists(self, tmp_path: Path):
        cover_art_dir = tmp_path / "cover_art"
        cover_art_dir.mkdir()

        db = _create_database(tmp_path)
        ctx = CoverArtContext(cover_art_dir=cover_art_dir, database=db)
        manager = CoverArtManager(ctx=ctx)

        assert manager is not None


class TestAddAlbumArt:
    def test_valid_png_returns_an_id(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        cover_art_id = manager.add_album_art(png_bytes)

        assert isinstance(cover_art_id, int)
        assert cover_art_id > 0

    def test_valid_jpeg_returns_an_id(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        jpeg_bytes = _make_jpeg_bytes()

        cover_art_id = manager.add_album_art(jpeg_bytes)

        assert isinstance(cover_art_id, int)
        assert cover_art_id > 0

    def test_saves_image_file_to_disk(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        manager.add_album_art(png_bytes)

        files = list(manager.ctx.cover_art_dir.iterdir())
        assert len(files) == 1
        assert files[0].read_bytes() == png_bytes

    def test_saved_file_is_named_with_sha256(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        manager.add_album_art(png_bytes)

        sha256 = hashlib.sha256(png_bytes).hexdigest()
        files = list(manager.ctx.cover_art_dir.iterdir())
        assert files[0].stem == sha256

    def test_invalid_bytes_raises_value_error(self, tmp_path: Path):
        manager = _create_manager(tmp_path)

        with pytest.raises(ValueError):
            manager.add_album_art(b"not an image at all")

    def test_empty_bytes_raises_value_error(self, tmp_path: Path):
        manager = _create_manager(tmp_path)

        with pytest.raises(ValueError):
            manager.add_album_art(b"")

    def test_same_image_twice_returns_same_id(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        id_first = manager.add_album_art(png_bytes)
        id_second = manager.add_album_art(png_bytes)

        assert id_first == id_second

    def test_same_image_twice_does_not_create_duplicate_file(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        manager.add_album_art(png_bytes)
        manager.add_album_art(png_bytes)

        files = list(manager.ctx.cover_art_dir.iterdir())
        assert len(files) == 1

    def test_add_album_art_with_status_reports_created_then_reused(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        created = manager.add_album_art_with_status(png_bytes)
        reused = manager.add_album_art_with_status(png_bytes)

        assert created.was_created is True
        assert reused.was_created is False
        assert created.cover_art_id == reused.cover_art_id

    def test_different_images_get_different_ids(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        red = _make_png_bytes(color=(255, 0, 0))
        blue = _make_png_bytes(color=(0, 0, 255))

        id_red = manager.add_album_art(red)
        id_blue = manager.add_album_art(blue)

        assert id_red != id_blue

    def test_different_images_each_saved_to_disk(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        red = _make_png_bytes(color=(255, 0, 0))
        blue = _make_png_bytes(color=(0, 0, 255))

        manager.add_album_art(red)
        manager.add_album_art(blue)

        files = list(manager.ctx.cover_art_dir.iterdir())
        assert len(files) == 2

    def test_perceptually_similar_images_return_same_id(self, tmp_path: Path):
        """A slightly resized version of the same image should be deduped by phash."""
        manager = _create_manager(tmp_path)

        # Create a distinctive image pattern
        img = Image.new("RGB", (200, 200), (0, 0, 0))
        for x in range(200):
            for y in range(100):
                img.putpixel((x, y), (255, 255, 255))

        buf1 = BytesIO()
        img.save(buf1, format="PNG")
        bytes1 = buf1.getvalue()

        # Same pattern, slightly resized — different SHA256 but same phash
        resized = img.resize((180, 180))
        buf2 = BytesIO()
        resized.save(buf2, format="PNG")
        bytes2 = buf2.getvalue()

        assert hashlib.sha256(bytes1).hexdigest() != hashlib.sha256(bytes2).hexdigest()

        id1 = manager.add_album_art(bytes1)
        id2 = manager.add_album_art(bytes2)

        assert id1 == id2

    def test_visually_different_images_get_different_ids(self, tmp_path: Path):
        """Images that look completely different should not be deduped."""
        manager = _create_manager(tmp_path)

        # All black image
        black = Image.new("RGB", (200, 200), (0, 0, 0))
        buf1 = BytesIO()
        black.save(buf1, format="PNG")

        # Checkerboard pattern
        checker = Image.new("RGB", (200, 200))
        for x in range(200):
            for y in range(200):
                checker.putpixel((x, y), (255, 255, 255) if (x // 25 + y // 25) % 2 == 0 else (0, 0, 0))
        buf2 = BytesIO()
        checker.save(buf2, format="PNG")

        id1 = manager.add_album_art(buf1.getvalue())
        id2 = manager.add_album_art(buf2.getvalue())

        assert id1 != id2

    def test_different_formats_with_same_content_dedup_via_phash(self, tmp_path: Path):
        """A PNG and JPEG of the same image should be deduped by phash."""
        manager = _create_manager(tmp_path)

        img = Image.new("RGB", (200, 200), (0, 0, 0))
        for x in range(200):
            for y in range(100):
                img.putpixel((x, y), (255, 255, 255))

        buf_png = BytesIO()
        img.save(buf_png, format="PNG")
        buf_jpeg = BytesIO()
        img.save(buf_jpeg, format="JPEG", quality=95)

        id_png = manager.add_album_art(buf_png.getvalue())
        id_jpeg = manager.add_album_art(buf_jpeg.getvalue())

        assert id_png == id_jpeg

    def test_concurrent_same_image_returns_single_id_and_keeps_file(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()
        worker_count = 8
        barrier = Barrier(worker_count)

        def add_art(_):
            barrier.wait()
            return manager.add_album_art(png_bytes)

        with ThreadPoolExecutor(max_workers=worker_count) as executor:
            ids = list(executor.map(add_art, range(worker_count)))

        assert len(set(ids)) == 1

        files = list(manager.ctx.cover_art_dir.iterdir())
        assert len(files) == 1
        assert files[0].read_bytes() == png_bytes

        sha256 = hashlib.sha256(png_bytes).hexdigest()
        row = manager.ctx.database.get_cover_art_by_sha256(sha256)
        assert row is not None
        assert row.file_path.exists()

    def test_cleans_up_file_when_db_insert_fails(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        with patch.object(
            manager.ctx.database,
            "insert_cover_art",
            side_effect=sqlite3.IntegrityError("UNIQUE constraint failed"),
        ):
            with pytest.raises(sqlite3.IntegrityError):
                manager.add_album_art(png_bytes)

        # The file should have been cleaned up
        cover_art_files = list(manager.ctx.cover_art_dir.iterdir())
        assert len(cover_art_files) == 0


class TestGetAlbumArt:
    def test_returns_path_for_existing_art(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        cover_art_id = manager.add_album_art(png_bytes)
        result = manager.get_album_art(cover_art_id)

        assert result is not None
        assert result.exists()
        assert result.read_bytes() == png_bytes

    def test_returns_none_for_nonexistent_id(self, tmp_path: Path):
        manager = _create_manager(tmp_path)

        result = manager.get_album_art(999)

        assert result is None

    def test_returns_correct_path_after_multiple_inserts(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        red = _make_png_bytes(color=(255, 0, 0))
        blue = _make_png_bytes(color=(0, 0, 255))

        id_red = manager.add_album_art(red)
        id_blue = manager.add_album_art(blue)

        path_red = manager.get_album_art(id_red)
        path_blue = manager.get_album_art(id_blue)

        assert path_red is not None
        assert path_blue is not None
        assert path_red != path_blue
        assert path_red.read_bytes() == red
        assert path_blue.read_bytes() == blue


class TestReleaseIfUnreferenced:
    """SC-16h, pulled into M.0 (spec §4.2 "Cover art", review M-U06 art):
    release removes the row and file only when no trackmetadata of any owner
    references them, and runs under CoverArtManager._lock."""

    def test_unreferenced_art_is_removed_with_its_file(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        path = manager.get_album_art(cover_art_id)
        assert path is not None and path.exists()

        assert manager.release_if_unreferenced(cover_art_id) is True

        assert not path.exists()
        assert manager.get_album_art(cover_art_id) is None

    def test_an_unknown_id_is_a_no_op(self, tmp_path: Path):
        manager = _create_manager(tmp_path)

        assert manager.release_if_unreferenced(999) is False

    def test_the_same_image_can_be_added_again_after_release(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()
        first_id = manager.add_album_art(png_bytes)
        manager.release_if_unreferenced(first_id)

        second_id = manager.add_album_art(png_bytes)

        assert manager.get_album_art(second_id).read_bytes() == png_bytes

    def test_releasing_one_does_not_affect_another(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        id_red = manager.add_album_art(_make_png_bytes(color=(255, 0, 0)))
        id_blue = manager.add_album_art(_make_png_bytes(color=(0, 0, 255)))

        manager.release_if_unreferenced(id_red)

        assert manager.get_album_art(id_red) is None
        assert manager.get_album_art(id_blue).exists()

    def test_art_another_users_track_references_is_never_stripped(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData
        from tests.owned_database import add_test_user

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        path = manager.get_album_art(cover_art_id)
        alex = add_test_user(db, "alex")
        track = Track(
            file_path=tmp_path / "music" / "alex" / "song.mp3",
            metadata=TrackMetaData(
                title="Song", artist="Artist", codec="mp3", duration=200.0,
                has_album_art=True, cover_art_id=cover_art_id,
            ),
        )
        assert db.add_track(track, owner_id=alex)
        revision = db.get_track_by_uuid(track.uuid_id, owner_id=alex).revision

        assert manager.release_if_unreferenced(cover_art_id) is False

        assert path.exists()
        assert manager.get_album_art(cover_art_id) == path
        after = db.get_track_by_uuid(track.uuid_id, owner_id=alex)
        assert after.metadata.cover_art_id == cover_art_id
        assert after.revision == revision

    def test_a_failed_file_removal_keeps_the_row_so_a_later_call_finishes(self, tmp_path: Path):
        # OPEN-8-07 row 1 (8-L-01): the row used to go first, so a retry found
        # nothing to do and the image stayed on disk for good.
        manager = _create_manager(tmp_path)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        path = manager.get_album_art(cover_art_id)
        real_unlink = Path.unlink

        def refusing_unlink(self, *args, **kwargs):
            if self == path:
                raise PermissionError(13, "Permission denied")
            return real_unlink(self, *args, **kwargs)

        with patch.object(Path, "unlink", refusing_unlink):
            with pytest.raises(PermissionError):
                manager.release_if_unreferenced(cover_art_id)

        assert path.exists()
        assert manager.get_album_art(cover_art_id) == path  # the row is still there

        assert manager.release_if_unreferenced(cover_art_id) is True
        assert not path.exists()
        assert manager.get_album_art(cover_art_id) is None

    @pytest.mark.requires_chmod_denial
    def test_a_read_only_cover_folder_keeps_the_row_until_it_is_writable(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        path = manager.get_album_art(cover_art_id)
        folder = path.parent
        folder.chmod(0o555)
        try:
            with pytest.raises(OSError):
                manager.release_if_unreferenced(cover_art_id)
            assert path.exists()
            assert manager.get_album_art(cover_art_id) == path
        finally:
            folder.chmod(0o755)

        assert manager.release_if_unreferenced(cover_art_id) is True
        assert not path.exists()
        assert manager.get_album_art(cover_art_id) is None

    def test_a_referenced_row_is_never_touched_and_its_file_never_removed(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        path = manager.get_album_art(cover_art_id)
        track = Track(
            file_path=tmp_path / "music" / "song.mp3",
            metadata=TrackMetaData(
                title="Song", artist="Artist", codec="mp3", duration=200.0,
                has_album_art=True, cover_art_id=cover_art_id,
            ),
        )
        assert db.add_track(track)
        unlinked = []
        real_unlink = Path.unlink

        def spy_unlink(self, *args, **kwargs):
            unlinked.append(self)
            return real_unlink(self, *args, **kwargs)

        with patch.object(Path, "unlink", spy_unlink):
            assert manager.release_if_unreferenced(cover_art_id) is False

        assert unlinked == []
        assert path.exists()
        assert manager.get_album_art(cover_art_id) == path

    def test_a_missing_file_still_releases_the_row(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        manager.get_album_art(cover_art_id).unlink()

        assert manager.release_if_unreferenced(cover_art_id) is True
        assert manager.get_album_art(cover_art_id) is None

    def test_the_reference_check_and_removal_run_under_the_manager_lock(self, tmp_path: Path):
        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        path = manager.get_album_art(cover_art_id)

        class _SpyLock:
            held = False

            def __enter__(self):
                _SpyLock.held = True
                return self

            def __exit__(self, *exc):
                _SpyLock.held = False
                return False

        manager._lock = _SpyLock()
        seen = []
        real_delete = db.delete_cover_art
        real_unlink = Path.unlink

        def spy_delete(*args, **kwargs):
            seen.append(("delete", _SpyLock.held))
            return real_delete(*args, **kwargs)

        def spy_unlink(self, *args, **kwargs):
            if self == path:
                seen.append(("unlink", _SpyLock.held))
            return real_unlink(self, *args, **kwargs)

        with patch.object(db, "delete_cover_art", spy_delete), \
                patch.object(Path, "unlink", spy_unlink):
            assert manager.release_if_unreferenced(cover_art_id) is True

        assert seen == [("delete", True), ("unlink", True)]


class TestCoverArtDatabaseIntegration:
    """Tests that cover_art_id flows through the track pipeline correctly."""

    def test_track_with_cover_art_id_is_stored_and_retrieved(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)

        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        metadata = TrackMetaData(
            title="Test Song",
            artist="Test Artist",
            codec="mp3",
            duration=200.0,
            bitrate_kbps=320.0,
            sample_rate_hz=44100,
            channels=2,
            cover_art_id=cover_art_id,
        )
        track = Track(file_path=tmp_path / "song.mp3", metadata=metadata)
        db.add_track(track)

        tracks = db.get_tracks()
        assert len(tracks) == 1
        assert tracks[0].metadata.cover_art_id == cover_art_id

    def test_track_without_cover_art_has_none_cover_art_id(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)

        metadata = TrackMetaData(
            title="No Art Song",
            artist="Artist",
            codec="mp3",
            duration=100.0,
            bitrate_kbps=128.0,
            sample_rate_hz=44100,
            channels=2,
        )
        track = Track(file_path=tmp_path / "song.mp3", metadata=metadata)
        db.add_track(track)

        tracks = db.get_tracks()
        assert len(tracks) == 1
        assert tracks[0].metadata.cover_art_id is None

    def test_multiple_tracks_can_share_same_cover_art(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)

        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        for i in range(3):
            metadata = TrackMetaData(
                title=f"Track {i}",
                artist="Artist",
                codec="mp3",
                duration=100.0,
                bitrate_kbps=128.0,
                sample_rate_hz=44100,
                channels=2,
                cover_art_id=cover_art_id,
            )
            track = Track(file_path=tmp_path / f"song_{i}.mp3", metadata=metadata)
            db.add_track(track)

        tracks = db.get_tracks()
        assert len(tracks) == 3
        for t in tracks:
            assert t.metadata.cover_art_id == cover_art_id


class TestGetTracksMissingCoverArt:
    def test_returns_tracks_with_has_album_art_and_no_cover_art_id(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)

        metadata = TrackMetaData(
            title="Has Art",
            artist="Artist",
            codec="mp3",
            duration=100.0,
            bitrate_kbps=128.0,
            sample_rate_hz=44100,
            channels=2,
            has_album_art=True,
        )
        track = Track(file_path=tmp_path / "song.mp3", metadata=metadata)
        db.add_track(track)

        missing = db.get_tracks_missing_cover_art()

        assert len(missing) == 1
        assert missing[0].metadata.has_album_art is True
        assert missing[0].metadata.cover_art_id is None
        assert missing[0].revision > 0

    def test_does_not_return_tracks_without_album_art(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)

        metadata = TrackMetaData(
            title="No Art",
            artist="Artist",
            codec="mp3",
            duration=100.0,
            bitrate_kbps=128.0,
            sample_rate_hz=44100,
            channels=2,
            has_album_art=False,
        )
        track = Track(file_path=tmp_path / "song.mp3", metadata=metadata)
        db.add_track(track)

        missing = db.get_tracks_missing_cover_art()

        assert len(missing) == 0

    def test_does_not_return_tracks_with_cover_art_id_already_set(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)

        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        metadata = TrackMetaData(
            title="Already Set",
            artist="Artist",
            codec="mp3",
            duration=100.0,
            bitrate_kbps=128.0,
            sample_rate_hz=44100,
            channels=2,
            has_album_art=True,
            cover_art_id=cover_art_id,
        )
        track = Track(file_path=tmp_path / "song.mp3", metadata=metadata)
        db.add_track(track)

        missing = db.get_tracks_missing_cover_art()

        assert len(missing) == 0


class TestUpdateTrackCoverArtId:
    def test_updates_cover_art_id_on_existing_track(self, tmp_path: Path):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)

        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        metadata = TrackMetaData(
            title="Song",
            artist="Artist",
            codec="mp3",
            duration=100.0,
            bitrate_kbps=128.0,
            sample_rate_hz=44100,
            channels=2,
            has_album_art=True,
        )
        track = Track(file_path=tmp_path / "song.mp3", metadata=metadata)
        db.add_track(track)

        result = db.update_track_cover_art_id(track.uuid_id, cover_art_id)

        assert result is True
        tracks = db.get_tracks()
        assert tracks[0].metadata.cover_art_id == cover_art_id

    def test_returns_false_for_nonexistent_uuid(self, tmp_path: Path):
        db = _create_database(tmp_path)

        result = db.update_track_cover_art_id("nonexistent-uuid", 1)

        assert result is False

    def test_update_bumps_tracks_last_updated(self, tmp_path: Path):
        """Cover-art backfill bumps the track's revision so incremental sync
        sees the assignment; it also keeps ``tracks.last_updated`` current for
        display freshness, which this test guards."""
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        cover_art_id = db.insert_cover_art(
            sha256="art_sha", phash="abc123", phash_prefix="abc1",
            file_path=str(tmp_path / "art.jpg"),
        )

        metadata = TrackMetaData(
            title="Song", artist="Artist", codec="mp3", duration=100.0,
            bitrate_kbps=128.0, sample_rate_hz=44100, channels=2,
            has_album_art=True,
        )
        track = Track(file_path=tmp_path / "song.mp3", metadata=metadata)
        db.add_track(track)
        # add_track stamped the current epoch second, and the product bump uses
        # SQLite unixepoch() (not patchable from Python). Backdate the row
        # instead of sleeping past a second so the bump is visible.
        with db._connection(commit=True) as conn:
            conn.execute(
                "UPDATE tracks SET last_updated = last_updated - 10 WHERE uuid_id = ?",
                (track.uuid_id,),
            )
        original = db.get_tracks()[0].last_updated

        assert db.update_track_cover_art_id(track.uuid_id, cover_art_id) is True

        bumped = db.get_tracks()[0].last_updated
        assert bumped > original
class TestDedupeReuseRace:
    """SC-16h: ``add_album_art`` hands out an existing id without holding a
    reference, and the track insert commits later. A release in between (for
    example another ingest's failure) removes the row, so the insert must
    notice the vanished art and the organizer must re-register it."""

    def _ingest_setup(self, tmp_path: Path):
        from app.library import Library
        from app.services.organizer import Organizer, OrganizerContext

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        root = tmp_path / "music" / "owner"
        library = Library(db, db.owner_id, root=root)
        return db, manager, root, library, Organizer, OrganizerContext

    def test_add_track_refuses_a_cover_art_id_that_no_longer_exists(self, tmp_path: Path):
        from app.database.database import CoverArtGone
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        cover_art_id = manager.add_album_art(_make_png_bytes())
        assert manager.release_if_unreferenced(cover_art_id)
        track = Track(
            file_path=tmp_path / "music" / "owner" / "a.mp3",
            metadata=TrackMetaData(
                title="T", artist="Gone Artist", codec="mp3", duration=1.0,
                has_album_art=True, cover_art_id=cover_art_id,
            ),
        )

        with pytest.raises(CoverArtGone):
            db.add_track(track)

        assert db.get_track_by_uuid(track.uuid_id) is None
        assert db.get_artists() == []

    def test_a_release_between_dedupe_and_insert_is_healed_by_re_registering(
        self, tmp_path: Path
    ):
        from app.models.track_meta_data import TrackMetaData

        db, manager, root, library, Organizer, OrganizerContext = self._ingest_setup(tmp_path)
        art = _make_png_bytes()
        # Another ingest just created this art and has not inserted its track.
        stale_id = manager.add_album_art(art)

        def add_after_the_other_ingest_failed(track):
            # The other ingest fails now and releases "its" art, after our
            # dedupe returned the same id but before our insert commits.
            manager.release_if_unreferenced(stale_id)
            return library.add_track(track)

        calls = []

        def add_to_database(track):
            calls.append(track.metadata.cover_art_id)
            if len(calls) == 1:
                return add_after_the_other_ingest_failed(track)
            return library.add_track(track)

        organizer = Organizer(OrganizerContext(
            music_library_dir=root,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=add_to_database,
            add_cover_art=manager.add_album_art_with_status,
            release_cover_art=manager.release_if_unreferenced,
        ))
        source = tmp_path / "import" / "song.mp3"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"audio")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=art),
        ):
            get_track_metadata.return_value = TrackMetaData(
                title="T", artist="Artist", duration=1.0, has_album_art=True,
            )
            assert organizer.organize_file(file_path=source) is True

        [track] = db.get_tracks()
        cover_art_id = track.metadata.cover_art_id
        assert cover_art_id is not None
        assert calls[0] == stale_id
        path = manager.get_album_art(cover_art_id)
        assert path is not None and path.read_bytes() == art
        assert (root / "Artist" / "song.mp3").is_file()


class TestAnOversizedImageIsRefusedLikeAnyInvalidImage:
    """Bug row U05-A-11: an image over Pillow's pixel limit raises
    DecompressionBombError, which escaped every caller (they catch the
    ValueError the docstring promises): an import broke instead of landing
    without art, and a startup backfill would abort. The limit is lowered for
    the test so a 100 x 100 image is over it."""

    @pytest.fixture(autouse=True)
    def _low_pixel_limit(self, monkeypatch):
        monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 1000)  # over 2x -> DecompressionBombError

    def test_an_oversized_image_raises_value_error_and_stores_nothing(self, tmp_path: Path):
        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        image = _make_png_bytes(100, 100)

        with pytest.raises(ValueError):
            manager.add_album_art_with_status(image)

        assert db.get_cover_art_by_sha256(hashlib.sha256(image).hexdigest()) is None
        assert list((tmp_path / "cover_art").iterdir()) == []

    def test_an_import_with_an_oversized_cover_lands_without_art(self, tmp_path: Path):
        from app.library import Library
        from app.models.track_meta_data import TrackMetaData
        from app.services.import_outcome import ImportOutcome
        from app.services.organizer import Organizer, OrganizerContext

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        root = tmp_path / "music" / "owner"
        library = Library(db, db.owner_id, root=root)
        organizer = Organizer(OrganizerContext(
            music_library_dir=root, should_organize_files=True, should_copy_files=False,
            add_to_database=library.add_track,
            add_cover_art=manager.add_album_art_with_status,
            release_cover_art=manager.release_if_unreferenced,
        ))
        source = tmp_path / "import" / "song.mp3"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"audio")

        with (
            patch("app.services.organizer.get_track_metadata", return_value=TrackMetaData(
                title="T", artist="Artist", duration=1.0, has_album_art=True)),
            patch("app.services.organizer.extract_cover_art_bytes",
                  return_value=_make_png_bytes(100, 100)),
        ):
            assert organizer.organize(source) is ImportOutcome.IMPORTED

        [track] = db.get_tracks()
        assert track.metadata.cover_art_id is None
        assert (root / "Artist" / "song.mp3").is_file()

    def test_the_backfill_skips_an_oversized_cover_and_goes_on(self, tmp_path: Path, monkeypatch):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        meta = dict(artist="Artist", codec="mp3", duration=1.0, has_album_art=True)
        bomb_track = Track(file_path=tmp_path / "a.mp3", metadata=TrackMetaData(title="A", **meta))
        good_track = Track(file_path=tmp_path / "b.mp3", metadata=TrackMetaData(title="B", **meta))
        for t in (bomb_track, good_track):
            t.file_path.write_bytes(b"audio")
            assert db.add_track(t)
        monkeypatch.setattr(Image, "MAX_IMAGE_PIXELS", 3000)  # 100 x 100 over it, 30 x 30 under
        art = {bomb_track.file_path: _make_png_bytes(100, 100), good_track.file_path: _make_png_bytes(30, 30)}
        monkeypatch.setattr("app.services.cover_art_manager.extract_cover_art_bytes",
                            lambda path: art[Path(path)])

        manager.backfill_cover_art()

        by_title = {t.metadata.title: t.metadata.cover_art_id for t in db.get_tracks()}
        assert by_title["A"] is None
        assert by_title["B"] is not None


class TestTheBackfillReleasesArtItCreated:
    """Bug row U05-A-11 (backfill part): art the backfill created for a track
    whose update is then refused (the track went away meanwhile) is released
    again instead of staying as an orphan row and file; art that already
    existed (shared) is never touched."""

    def _setup(self, tmp_path: Path, monkeypatch):
        from app.models.track import Track
        from app.models.track_meta_data import TrackMetaData

        db = _create_database(tmp_path)
        manager = _create_manager(tmp_path, database=db)
        track = Track(file_path=tmp_path / "a.mp3", metadata=TrackMetaData(
            title="A", artist="Artist", codec="mp3", duration=1.0, has_album_art=True))
        track.file_path.write_bytes(b"audio")
        assert db.add_track(track)
        image = _make_png_bytes(64, 64)
        monkeypatch.setattr("app.services.cover_art_manager.extract_cover_art_bytes",
                            lambda path: image)
        monkeypatch.setattr(db, "update_track_cover_art_id",
                            lambda uuid_id, cover_art_id, *, owner_id: False)
        return db, manager, image

    def test_created_art_is_released_when_the_track_update_is_refused(self, tmp_path, monkeypatch):
        db, manager, image = self._setup(tmp_path, monkeypatch)

        manager.backfill_cover_art()

        assert db.get_cover_art_by_sha256(hashlib.sha256(image).hexdigest()) is None
        assert list((tmp_path / "cover_art").iterdir()) == []

    def test_existing_art_is_kept_when_the_track_update_is_refused(self, tmp_path, monkeypatch):
        db, manager, image = self._setup(tmp_path, monkeypatch)
        existing = manager.add_album_art(image)

        manager.backfill_cover_art()

        assert manager.get_album_art(existing) is not None
        assert manager.get_album_art(existing).is_file()
