from __future__ import annotations

import hashlib
import sqlite3
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

import pytest
from PIL import Image

from app.database.database import Database, DatabaseContext
from app.services.cover_art_manager import CoverArtContext, CoverArtManager


def _create_database(tmp_path: Path) -> Database:
    database_path = tmp_path / "database.db"
    context = DatabaseContext(
        database_path=database_path,
        init_sql_path=Path(__file__).parent.parent / "app" / "database" / "init.sql",
    )
    db = Database(context=context)
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


class TestRemoveAlbumArt:
    def test_removes_existing_art_and_returns_true(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        result = manager.remove_album_art(cover_art_id)

        assert result is True

    def test_file_is_deleted_from_disk(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        path = manager.get_album_art(cover_art_id)
        assert path is not None and path.exists()

        manager.remove_album_art(cover_art_id)

        assert not path.exists()

    def test_get_returns_none_after_removal(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        manager.remove_album_art(cover_art_id)

        assert manager.get_album_art(cover_art_id) is None

    def test_raises_value_error_for_nonexistent_id(self, tmp_path: Path):
        manager = _create_manager(tmp_path)

        with pytest.raises(ValueError):
            manager.remove_album_art(999)

    def test_can_add_same_image_again_after_removal(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()

        first_id = manager.add_album_art(png_bytes)
        manager.remove_album_art(first_id)

        second_id = manager.add_album_art(png_bytes)

        assert isinstance(second_id, int)
        assert manager.get_album_art(second_id) is not None

    def test_removing_one_does_not_affect_another(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        red = _make_png_bytes(color=(255, 0, 0))
        blue = _make_png_bytes(color=(0, 0, 255))

        id_red = manager.add_album_art(red)
        id_blue = manager.add_album_art(blue)

        manager.remove_album_art(id_red)

        assert manager.get_album_art(id_red) is None
        assert manager.get_album_art(id_blue) is not None

    def test_remove_clears_references_on_tracks(self, tmp_path: Path):
        """Removing cover art should set cover_art_id to NULL on referencing tracks."""
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

        manager.remove_album_art(cover_art_id)

        tracks = db.get_tracks()
        assert len(tracks) == 1
        assert tracks[0].metadata.cover_art_id is None

    def test_file_already_missing_from_disk_still_succeeds(self, tmp_path: Path):
        manager = _create_manager(tmp_path)
        png_bytes = _make_png_bytes()
        cover_art_id = manager.add_album_art(png_bytes)

        # Manually delete the file before calling remove
        path = manager.get_album_art(cover_art_id)
        assert path is not None
        path.unlink()

        result = manager.remove_album_art(cover_art_id)

        assert result is True
        assert manager.get_album_art(cover_art_id) is None


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
