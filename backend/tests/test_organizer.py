from __future__ import annotations

import sqlite3

import threading
from pathlib import Path
from unittest.mock import Mock, patch

import pytest

import app.services.organizer as organizer
from app.services.cover_art_manager import CoverArtAddResult
from app.models.track_meta_data import TrackMetaData
from app.services.path_sanitize import PathEscapesRoot

class TestMoveFile:
    def test_move_file__source_does_not_exist__does_not_move_file(self, tmp_path: Path):
        file_path = tmp_path / "does_not_exist.mp3"

        destination_dir = tmp_path / "destination"
        file_destination_path = tmp_path / destination_dir / "does_not_exist.mp3"

        result =organizer.move_file(file_path, file_destination_path)

        assert result is False
        assert not file_destination_path.is_file()
        assert not destination_dir.is_dir()
    
    def test_move_file__source_does_exist__moves_files(self, tmp_path: Path):
        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"fake")

        destination_dir = Path(tmp_path / "music")
        destination_path = Path(destination_dir / "file.mp3")
        result = organizer.move_file(file_path, destination_path)

        assert result is True
        assert destination_dir.is_dir()
        assert destination_path.is_file()

    def test_move_file__blocked_while_directory_lock_is_held__then_succeeds(self, tmp_path: Path):
        dest_parent = tmp_path / "music"
        src = tmp_path / "b.mp3"
        src.write_bytes(b"B")
        dest = dest_parent / "b.mp3"

        lock = organizer._directory_locks.lock_for(organizer.directory_lock_key(dest_parent))
        lock.acquire()
        results = {}
        t = threading.Thread(
            target=lambda: results.update(ok=organizer.move_file(src, dest))
        )
        t.start()
        t.join(timeout=0.2)
        assert t.is_alive(), "move_file proceeded without acquiring the directory lock"
        lock.release()

        t.join(timeout=5)
        assert results["ok"] is True
        assert dest.read_bytes() == b"B"

    def test_move_file__concurrent_calls_to_same_destination__second_call_refuses(self, tmp_path: Path):
        src_a = tmp_path / "a.mp3"
        src_a.write_bytes(b"AAAA")
        dest = tmp_path / "music" / "song.mp3"

        # Simulates a concurrent move_file already in its critical section.
        lock = organizer._directory_locks.lock_for(organizer.directory_lock_key(dest.parent))
        lock.acquire()
        results = {}
        t = threading.Thread(
            target=lambda: results.update(a=organizer.move_file(src_a, dest))
        )
        t.start()
        t.join(timeout=0.2)
        assert t.is_alive()

        # The "other" concurrent call places a file at dest while holding the lock.
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"WINNER")
        lock.release()

        t.join(timeout=5)
        assert results["a"] is False  # correctly refuses -- dest now exists
        assert dest.read_bytes() == b"WINNER"  # untouched by the losing call
        assert src_a.exists()  # loser's source file preserved, not consumed


class TestPruneEmptyDirs:
    def test_removes_a_single_empty_directory(self, tmp_path: Path):
        empty = tmp_path / "root" / "Artist"
        empty.mkdir(parents=True)

        organizer.prune_empty_dirs(empty, tmp_path / "root")

        assert not empty.exists()

    def test_walks_up_removing_multiple_empty_ancestors(self, tmp_path: Path):
        root = tmp_path / "root"
        leaf = root / "Artist" / "Album"
        leaf.mkdir(parents=True)

        organizer.prune_empty_dirs(leaf, root)

        assert not leaf.exists()
        assert not (root / "Artist").exists()
        assert root.exists()

    def test_stops_at_the_first_non_empty_ancestor(self, tmp_path: Path):
        root = tmp_path / "root"
        leaf = root / "Artist" / "Album"
        leaf.mkdir(parents=True)
        (root / "Artist" / "other_album.txt").write_bytes(b"x")

        organizer.prune_empty_dirs(leaf, root)

        assert not leaf.exists()  # the empty leaf itself is still removed
        assert (root / "Artist").exists()  # but its non-empty parent survives

    def test_never_removes_root_even_when_passed_directly(self, tmp_path: Path):
        root = tmp_path / "root"
        root.mkdir()

        organizer.prune_empty_dirs(root, root)

        assert root.exists()

    def test_tolerates_a_directory_that_is_already_gone(self, tmp_path: Path):
        root = tmp_path / "root"
        root.mkdir()
        gone = root / "Artist"  # never created

        organizer.prune_empty_dirs(gone, root)  # must not raise

        assert root.exists()


class TestSanitizedDestinationPath:
    def test_sanitized_destination_path__unsafe_album_artist__does_not_fall_back_to_artist(self, tmp_path: Path):
        meta = TrackMetaData(album_artist="...", artist="Real Artist", album="A")
        result = organizer.sanitized_destination_path("f.mp3", meta, tmp_path)
        # Raw effective_artist picks album_artist ("..."), which
        # sanitize_path_component cannot represent as a folder name (it strips
        # entirely to dots). Must NOT silently substitute "artist" instead --
        # that would misrepresent the DB's chosen identity. Falls back to the
        # library root instead.
        assert result == tmp_path / "f.mp3"


class TestOrganizer:
    def _create_organizing_moving_organizer(
        self,
        music_dir: Path,
        *,
        add_to_database=lambda x: True,
        add_cover_art=None,
        release_cover_art=None,
    ):
        ctx = organizer.OrganizerContext(
            music_library_dir=music_dir,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=add_to_database,
            add_cover_art=add_cover_art,
            release_cover_art=release_cover_art,
        )
        return organizer.Organizer(ctx)
    
    def _create_nonorganizing_organizer(self, music_dir: Path):
        ctx = organizer.OrganizerContext(
            music_library_dir=music_dir,
            should_organize_files=False,
            should_copy_files=False,
            add_to_database=lambda x: True,
        )
        return organizer.Organizer(ctx)
    
    def test_organize_file__organizing_moving_source_does_not_exist__does_not_organize(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        organize = self._create_organizing_moving_organizer(music_dir=music_dir)
        file_path = tmp_path / "input/fake_file.mp3"

        result = organize.organize_file(file_path=file_path)

        assert result is False
        assert not music_dir.exists()
        assert not (tmp_path / "input").exists()
    
    def test_organize_file__organizing_moving_empty_song__does_not_organize(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        organize = self._create_organizing_moving_organizer(music_dir=music_dir)

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaa")

        with patch("app.services.organizer.get_track_metadata") as get_track_metadata:
            with patch.object(TrackMetaData, "is_empty", return_value=True):
                trackmetadata = TrackMetaData()
                get_track_metadata.return_value = trackmetadata

                result = organize.organize_file(file_path=file_path)

                assert result is False
                assert not music_dir.exists()
                assert not Path(music_dir / "file.mp3").exists()

    @pytest.mark.parametrize(
        "trackmeta_kwargs, expected_subdir",
        [
            ({"duration": 1.0, "artist": "artist", "album": "album"}, "artist/album"),
            ({"duration": 1.0, "artist": "artist"}, "artist"),
            ({"duration": 1.0}, ""),
            ({"duration": 1.0, "artist": "artist", "album": "album", "album_artist": "album_artist"}, "album_artist/album"),
        ],
        ids=[
            "album-and-artist",
            "artist-only",
            "no-artist-or-album",
            "album-artist"
        ]
    )
    def test_organize_file__organizing_moving_various_scenarios(self, tmp_path: Path, trackmeta_kwargs, expected_subdir):
        music_dir = Path(tmp_path / "music")
        organize = self._create_organizing_moving_organizer(music_dir=music_dir)
        
        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with patch("app.services.organizer.get_track_metadata") as get_track_metadata:
            trackmetadata = TrackMetaData(**trackmeta_kwargs)
            get_track_metadata.return_value = trackmetadata

            result = organize.organize_file(file_path=file_path)

            assert result is True

            if expected_subdir:
                organized_dir = music_dir / expected_subdir
            else:
                organized_dir = music_dir

            assert Path(organized_dir).is_dir()
            organized_file_path = Path(organized_dir / "file.mp3")
            assert organized_file_path.is_file()

    def test_organize_file__move_failure__cleans_up_new_cover_art(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        add_cover_art = Mock(return_value=CoverArtAddResult(cover_art_id=7, was_created=True))
        release_cover_art = Mock(return_value=True)
        organize = self._create_organizing_moving_organizer(
            music_dir=music_dir,
            add_cover_art=add_cover_art,
            release_cover_art=release_cover_art,
        )

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
            patch("app.services.organizer.move_file", return_value=False),
        ):
            get_track_metadata.return_value = TrackMetaData(
                duration=1.0,
                artist="artist",
                has_album_art=True,
            )

            result = organize.organize_file(file_path=file_path)

        assert result is False
        add_cover_art.assert_called_once_with(b"art")
        release_cover_art.assert_called_once_with(7)

    def test_organize_file__database_failure__rolls_back_file_and_cover_art(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        add_cover_art = Mock(return_value=CoverArtAddResult(cover_art_id=11, was_created=True))
        release_cover_art = Mock(return_value=True)
        organize = self._create_organizing_moving_organizer(
            music_dir=music_dir,
            add_to_database=lambda _: False,
            add_cover_art=add_cover_art,
            release_cover_art=release_cover_art,
        )

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
        ):
            get_track_metadata.return_value = TrackMetaData(
                duration=1.0,
                artist="artist",
                has_album_art=True,
            )

            result = organize.organize_file(file_path=file_path)

        destination_path = music_dir / "artist" / "file.mp3"
        assert result is False
        assert file_path.exists()
        assert not destination_path.exists()
        release_cover_art.assert_called_once_with(11)

    def test_organize_file__re_registration_failure__rolls_back_the_move(self, tmp_path: Path):
        # Review r1 #2: the art vanished before the insert (CoverArtGone) and
        # re-registering it fails too: the file must not be stranded in the library.
        from app.database.database import CoverArtGone

        music_dir = Path(tmp_path / "music")
        results = iter([
            CoverArtAddResult(cover_art_id=5, was_created=False),
            sqlite3.OperationalError("database is locked"),
        ])

        def add_cover_art(_):
            result = next(results)
            if isinstance(result, Exception):
                raise result
            return result

        def add_to_database(_):
            raise CoverArtGone(5)

        organize = self._create_organizing_moving_organizer(
            music_dir=music_dir,
            add_to_database=add_to_database,
            add_cover_art=add_cover_art,
            release_cover_art=Mock(return_value=True),
        )
        file_path = tmp_path / "file.mp3"
        file_path.write_bytes(b"dataaaaaaaaaa")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
        ):
            get_track_metadata.return_value = TrackMetaData(
                duration=1.0, artist="artist", has_album_art=True,
            )
            result = organize.organize_file(file_path=file_path)

        assert result is False
        assert file_path.read_bytes() == b"dataaaaaaaaaa"
        assert not (music_dir / "artist" / "file.mp3").exists()

    def test_organize_file__database_failure__does_not_remove_reused_cover_art(self, tmp_path: Path):
        music_dir = Path(tmp_path / "music")
        release_cover_art = Mock(return_value=True)
        organize = self._create_organizing_moving_organizer(
            music_dir=music_dir,
            add_to_database=lambda _: False,
            add_cover_art=lambda _: CoverArtAddResult(cover_art_id=22, was_created=False),
            release_cover_art=release_cover_art,
        )

        file_path = tmp_path / "file.mp3"
        file_path.touch()
        file_path.write_bytes(b"dataaaaaaaaaa")

        with (
            patch("app.services.organizer.get_track_metadata") as get_track_metadata,
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
        ):
            get_track_metadata.return_value = TrackMetaData(
                duration=1.0,
                artist="artist",
                has_album_art=True,
            )

            result = organize.organize_file(file_path=file_path)

        assert result is False
        release_cover_art.assert_not_called()


# ── ingest path safety (spec phase-m §3 M-P1; review M-U01) ────────────────

_WINDOWS_ILLEGAL = set(':*?"<>|\\/') | {chr(c) for c in range(0x20)}
_DEVICE_STEMS = {"con", "prn", "aux", "nul"} | {f"com{i}" for i in range(1, 10)} | {
    f"lpt{i}" for i in range(1, 10)
}


def _assert_portable(relative: Path) -> None:
    for part in relative.parts:
        assert part not in ("", ".", "..")
        assert not (set(part) & _WINDOWS_ILLEGAL), part
        assert not part.endswith((" ", ".")), part
        assert part.split(".", 1)[0].lower() not in _DEVICE_STEMS, part
        assert len(part) <= 200


def _files_under(path: Path) -> set[Path]:
    return {p for p in path.rglob("*") if p.is_file() or p.is_symlink()}


class TestOrganizeFileHostileNames:
    def _organize(self, tmp_path: Path, file_name: str, meta: TrackMetaData):
        music_dir = tmp_path / "music"
        import_dir = tmp_path / "import"
        import_dir.mkdir()
        source = import_dir / file_name
        source.write_bytes(b"audio")
        added: list = []
        ctx = organizer.OrganizerContext(
            music_library_dir=music_dir,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=lambda t: added.append(t) or True,
        )
        with patch("app.services.organizer.get_track_metadata", return_value=meta):
            result = organizer.Organizer(ctx).organize_file(file_path=source)
        return result, music_dir, source, added

    @pytest.mark.parametrize(
        "tag, folder",
        [
            ("../x", ".._x"),
            ("/abs", "_abs"),
            ("..\\x", ".._x"),
            ("a\x00b", "a_b"),
            ("a\nb", "a_b"),
            ("CON", "CON_"),
            ("Re: Stacks", "Re_ Stacks"),
        ],
        ids=["dotdot-slash", "absolute", "dotdot-backslash", "nul", "newline", "device", "colon"],
    )
    def test_hostile_artist_and_album_tags_land_inside_root_under_portable_names(
        self, tmp_path: Path, tag, folder
    ):
        meta = TrackMetaData(duration=1.0, artist=tag, album=tag)

        result, music_dir, source, added = self._organize(tmp_path, "AUX.mp3", meta)

        expected = music_dir / folder / folder / "AUX_.mp3"
        assert result is True
        assert expected.is_file()
        assert not source.exists()
        # Nothing was created anywhere except the one file in the library.
        assert _files_under(tmp_path) == {expected}
        assert {p for p in tmp_path.iterdir()} == {music_dir, tmp_path / "import"}
        _assert_portable(expected.relative_to(music_dir))
        # The DB row points at the placed file; the tags stay raw.
        assert len(added) == 1
        assert added[0].file_path == expected
        assert added[0].metadata.artist == tag
        assert added[0].metadata.album == tag

    def test_device_file_name_with_plain_tags(self, tmp_path: Path):
        meta = TrackMetaData(duration=1.0, artist="Radiohead", album="OK Computer")

        result, music_dir, _, added = self._organize(tmp_path, "AUX.mp3", meta)

        expected = music_dir / "Radiohead" / "OK Computer" / "AUX_.mp3"
        assert result is True
        assert _files_under(music_dir) == {expected}
        assert added[0].file_path == expected

    def test_reserved_characters_in_file_name(self, tmp_path: Path):
        meta = TrackMetaData(duration=1.0, artist="A")

        result, music_dir, _, _ = self._organize(tmp_path, "Re: Stacks?.mp3", meta)

        assert result is True
        assert _files_under(music_dir) == {music_dir / "A" / "Re_ Stacks_.mp3"}

    def test_album_artist_wins_and_is_sanitized(self, tmp_path: Path):
        meta = TrackMetaData(duration=1.0, artist="Plain", album_artist="AC/DC", album="Back: In Black")

        result, music_dir, _, _ = self._organize(tmp_path, "t.mp3", meta)

        assert result is True
        assert _files_under(music_dir) == {music_dir / "AC_DC" / "Back_ In Black" / "t.mp3"}

    def test_artist_that_cannot_be_a_folder_name_lands_at_the_root(self, tmp_path: Path):
        meta = TrackMetaData(duration=1.0, artist="..", album="Album")

        result, music_dir, _, _ = self._organize(tmp_path, "t.mp3", meta)

        assert result is True
        assert _files_under(music_dir) == {music_dir / "t.mp3"}

    def test_unusable_file_name_is_refused_and_nothing_is_created(self, tmp_path: Path):
        meta = TrackMetaData(duration=1.0, artist="A", album="B")

        result, music_dir, source, added = self._organize(tmp_path, "...", meta)

        assert result is False
        assert source.is_file()
        assert not music_dir.exists()
        assert added == []

    def test_create_destination_dir_is_gone(self):
        # The organizer and the editor share one builder (M-U01).
        assert not hasattr(organizer, "create_destination_dir")


class TestOrganizeFileContainment:
    """A destination that resolves outside the library root is refused before
    anything is created (spec phase-m §3 M-P1; SC-16 path containment)."""

    def _setup(self, tmp_path: Path):
        music_dir = tmp_path / "music"
        music_dir.mkdir()
        outside = tmp_path / "outside"
        outside.mkdir()
        # A folder inside the library that is really a link to somewhere else.
        (music_dir / "Evil").symlink_to(outside, target_is_directory=True)
        source = tmp_path / "import" / "t.mp3"
        source.parent.mkdir()
        source.write_bytes(b"audio")
        add_to_database = Mock(return_value=True)
        add_cover_art = Mock(return_value=CoverArtAddResult(cover_art_id=3, was_created=True))
        ctx = organizer.OrganizerContext(
            music_library_dir=music_dir,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=add_to_database,
            add_cover_art=add_cover_art,
            release_cover_art=Mock(return_value=True),
        )
        return organizer.Organizer(ctx), outside, source, add_to_database, add_cover_art

    def test_escaping_destination_raises_and_leaves_nothing_outside_the_root(self, tmp_path: Path):
        organize, outside, source, add_to_database, add_cover_art = self._setup(tmp_path)
        meta = TrackMetaData(duration=1.0, artist="Evil", album="Album", has_album_art=True)

        with (
            patch("app.services.organizer.get_track_metadata", return_value=meta),
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
            pytest.raises(PathEscapesRoot),
        ):
            organize.organize_file(file_path=source)

        assert list(outside.iterdir()) == []
        assert source.read_bytes() == b"audio"
        add_cover_art.assert_not_called()
        add_to_database.assert_not_called()

    def test_escaping_destination_at_artist_level_raises(self, tmp_path: Path):
        organize, outside, source, add_to_database, _ = self._setup(tmp_path)
        meta = TrackMetaData(duration=1.0, artist="Evil")

        with (
            patch("app.services.organizer.get_track_metadata", return_value=meta),
            pytest.raises(PathEscapesRoot),
        ):
            organize.organize_file(file_path=source)

        assert list(outside.iterdir()) == []
        assert source.is_file()
        add_to_database.assert_not_called()

    def test_root_reached_through_a_symlink_is_still_inside(self, tmp_path: Path):
        # Resolving both sides means a library root that is itself a link
        # is not mistaken for an escape.
        real_root = tmp_path / "real_music"
        real_root.mkdir()
        link_root = tmp_path / "music"
        link_root.symlink_to(real_root, target_is_directory=True)
        source = tmp_path / "t.mp3"
        source.write_bytes(b"audio")
        ctx = organizer.OrganizerContext(
            music_library_dir=link_root,
            should_organize_files=True,
            should_copy_files=False,
            add_to_database=lambda _: True,
        )
        meta = TrackMetaData(duration=1.0, artist="A")

        with patch("app.services.organizer.get_track_metadata", return_value=meta):
            assert organizer.Organizer(ctx).organize_file(file_path=source) is True

        assert (real_root / "A" / "t.mp3").is_file()


class TestImportedTextIsNfc:
    """Bug row U05-A-08: the text tags of an import are NFC-normalised once,
    before the destination is computed, so an NFD spelling ("e" + combining
    acute, as macOS tools often write) lands in the same artist row and the
    same folder as the NFC one, and the database and the folders agree."""

    NFC = "Beyoncé"
    NFD = "Beyoncé"

    def _env(self, tmp_path: Path):
        from app.database import DatabaseContext
        from app.services.cover_art_manager import CoverArtContext, CoverArtManager
        from app.services.pipeline import make_pipeline
        from tests.owned_database import OwnedTestDatabase
        from tests.schema_fixtures import INIT_SQL

        db = OwnedTestDatabase(
            DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
        )
        assert db.initialize()
        manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
        org, _ = make_pipeline(
            db.get_user(db.owner_id), database=db, cover_art_manager=manager,
            music_library_dir=tmp_path / "music", workspace_root=tmp_path / "workspace",
        )
        return db, org

    def _import(self, org, tmp_path: Path, name: str, meta: TrackMetaData):
        source = tmp_path / "import" / name
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(b"audio " + name.encode())
        with (
            patch("app.services.organizer.get_track_metadata", return_value=meta),
            patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
        ):
            return org.organize(source)

    def _rows(self, db, query):
        conn = sqlite3.connect(db.context.database_path)
        try:
            return conn.execute(query).fetchall()
        finally:
            conn.close()

    def test_an_nfd_artist_joins_the_nfc_artist_row_and_folder(self, tmp_path: Path):
        from app.services.import_outcome import ImportOutcome

        db, org = self._env(tmp_path)
        nfc = TrackMetaData(title="Halo", artist=self.NFC, album="I Am", duration=1.0)
        nfd = TrackMetaData(title="Sweet Dreams", artist=self.NFD, album="I Am", duration=1.0)

        assert self._import(org, tmp_path, "halo.mp3", nfc) is ImportOutcome.IMPORTED
        assert self._import(org, tmp_path, "dreams.mp3", nfd) is ImportOutcome.IMPORTED

        assert self._rows(db, "SELECT name FROM artists") == [(self.NFC,)]
        assert len(self._rows(db, "SELECT id FROM albums")) == 1
        folders = {t.file_path.parent for t in db.get_tracks(owner_id=db.owner_id)}
        assert folders == {org.ctx.music_library_dir / self.NFC / "I Am"}

    def test_every_text_tag_is_stored_nfc(self, tmp_path: Path):
        import unicodedata

        db, org = self._env(tmp_path)
        nfd = lambda s: unicodedata.normalize("NFD", s)  # noqa: E731
        meta = TrackMetaData(
            title=nfd("Café"), artist=nfd("Sigur Rós"), album=nfd("Ágætis byrjun"),
            album_artist=nfd("Sigur Rós"), genre=nfd("Post-rock é"), date=nfd("1999 é"),
            duration=1.0,
        )

        self._import(org, tmp_path, "cafe.mp3", meta)

        [track] = db.get_tracks(owner_id=db.owner_id)
        stored = track.metadata
        for value in (stored.title, stored.artist, stored.album, stored.album_artist,
                      stored.genre, stored.date):
            assert value == unicodedata.normalize("NFC", value)
        assert stored.title == "Café"
        assert track.file_path.parent == org.ctx.music_library_dir / "Sigur Rós" / "Ágætis byrjun"


class TestADifferentTrackGetsANumberedName:
    """Bug row U05-B-01 (A3, the owner's decisions of 2026-11-17): a different
    track whose library file name is taken is imported as ``"<stem> (N)<ext>"``
    in the same folder, with no upper limit; the same audio stays DUPLICATE.
    A name is taken when the file exists or a track's path folds to it. The
    existing file's audio comes from the hash stored for its track when that is
    current, and is decoded only when there is none; a hash missing on either
    side compares bytes. The next number is one above the highest in use for
    that name (gaps are not reused)."""

    @pytest.fixture
    def rig(self, tmp_path, monkeypatch):
        from tests.name_clash_rig import Rig

        return Rig(tmp_path, monkeypatch)

    def test_a_different_track_on_a_taken_name_is_imported_under_a_numbered_name(self, rig, caplog):
        import logging
        from app.services.import_outcome import ImportOutcome

        first = rig.source("a", "song.flac", b"one|tags")
        second = rig.source("b", "song.flac", b"two|tags")

        assert rig.organize(first) is ImportOutcome.IMPORTED
        with caplog.at_level(logging.INFO, logger="app.services.organizer"):
            assert rig.organize(second) is ImportOutcome.IMPORTED

        assert rig.names() == ["song (2).flac", "song.flac"]
        assert (rig.folder / "song.flac").read_bytes() == b"one|tags"
        assert (rig.folder / "song (2).flac").read_bytes() == b"two|tags"
        assert rig.track_names() == ["song (2).flac", "song.flac"]
        assert not second.exists()
        lines = [r.getMessage() for r in caplog.records if r.name == "app.services.organizer"]
        assert "import placed under a numbered name: a different track already uses the name" in lines
        assert not any(str(rig.tmp) in line for line in lines)

    def test_the_same_audio_under_other_tags_stays_a_duplicate(self, rig, caplog):
        import logging
        from app.services.import_outcome import ImportOutcome

        rig.seed_track("song.flac", b"one|old tags")
        again = rig.source("b", "song.flac", b"one|new tags, other bytes")

        with caplog.at_level(logging.INFO, logger="app.services.organizer"):
            assert rig.organize(again) is ImportOutcome.DUPLICATE

        assert rig.names() == ["song.flac"]
        assert again.read_bytes() == b"one|new tags, other bytes"
        assert rig.track_names() == ["song.flac"]
        lines = [r.getMessage() for r in caplog.records if r.name == "app.services.organizer"]
        assert "import refused: the same audio is already in the library under this name" in lines

    def test_a_case_only_clash_with_a_track_is_a_clash(self, rig):
        from app.services.import_outcome import ImportOutcome

        rig.seed_track("Song.flac", b"one|tags")
        other = rig.source("b", "song.flac", b"two|tags")

        assert rig.organize(other) is ImportOutcome.IMPORTED

        assert (rig.folder / "Song.flac").read_bytes() == b"one|tags"
        assert rig.track_names() == ["Song.flac", "song (2).flac"]

    def test_the_stored_hash_answers_and_the_existing_file_is_never_decoded(self, rig):
        from app.services.import_outcome import ImportOutcome

        rig.seed_track("song.flac", b"one|tags")
        other = rig.source("b", "song.flac", b"two|tags")

        assert rig.organize(other) is ImportOutcome.IMPORTED

        assert rig.decoded == [other]

    def test_150_clashes_need_no_decode_and_no_upper_limit(self, rig):
        from app.services.import_outcome import ImportOutcome

        rig.seed_track("song.flac", b"x1|t")
        for n in range(2, 151):
            rig.seed_track(f"song ({n}).flac", f"x{n}|t".encode())
        new = rig.source("b", "song.flac", b"brand new|t")

        assert rig.organize(new) is ImportOutcome.IMPORTED

        assert (rig.folder / "song (151).flac").read_bytes() == b"brand new|t"
        assert rig.decoded == [new]

    def test_the_same_audio_as_one_numbered_copy_is_a_duplicate(self, rig):
        from app.services.import_outcome import ImportOutcome

        rig.seed_track("song.flac", b"x1|t")
        for n in range(2, 151):
            rig.seed_track(f"song ({n}).flac", f"x{n}|t".encode())
        same = rig.source("b", "song.flac", b"x77|retagged")

        assert rig.organize(same) is ImportOutcome.DUPLICATE

        assert len(rig.names()) == 150
        assert rig.decoded == [same]

    def test_a_gap_in_the_numbers_is_not_reused(self, rig):
        from app.services.import_outcome import ImportOutcome

        rig.seed_track("song.flac", b"one|t")
        rig.seed_track("song (3).flac", b"three|t")
        new = rig.source("b", "song.flac", b"four|t")

        assert rig.organize(new) is ImportOutcome.IMPORTED

        assert rig.names() == ["song (3).flac", "song (4).flac", "song.flac"]

    def test_an_untracked_file_without_a_stored_hash_is_decoded_once(self, rig):
        from app.services.import_outcome import ImportOutcome

        rig.folder.mkdir(parents=True)
        (rig.folder / "song.flac").write_bytes(b"one|untracked")
        same = rig.source("b", "song.flac", b"one|tags")

        assert rig.organize(same) is ImportOutcome.DUPLICATE

        assert sorted(p.name for p in rig.decoded) == ["song.flac", "song.flac"]
        assert (rig.folder / "song.flac").read_bytes() == b"one|untracked"

    @pytest.mark.parametrize("content,outcome", [
        (b"unavailable|same bytes", "duplicate"),
        (b"unavailable|other bytes", "imported"),
    ])
    def test_without_hashes_the_bytes_decide(self, rig, content, outcome):
        from app.services.import_outcome import ImportOutcome

        rig.seed_track("song.flac", b"unavailable|same bytes", stored=False)
        incoming = rig.source("b", "song.flac", content)

        assert rig.organize(incoming) is ImportOutcome(outcome)

        assert (rig.folder / "song.flac").read_bytes() == b"unavailable|same bytes"

    def test_a_numbered_name_fits_the_byte_cap(self, rig):
        from app.services.import_outcome import ImportOutcome
        from app.services.path_sanitize import sanitize_file_name

        long_name = sanitize_file_name("曲" * 90 + ".flac")  # cut to 200 bytes
        rig.seed_track(long_name, b"one|t")
        other = rig.source("b", long_name, b"two|t")

        assert rig.organize(other) is ImportOutcome.IMPORTED

        [numbered] = [n for n in rig.names() if n != long_name]
        assert numbered.endswith(" (2).flac")
        assert len(numbered.encode("utf-8")) <= 200
        assert (rig.folder / long_name).read_bytes() == b"one|t"

    def test_two_concurrent_imports_of_one_name_end_as_two_tracks(self, rig, monkeypatch):
        """Both choose the free name; the folder lock lets one move win, the
        other's move is refused and it chooses again: never a replaced file."""
        import threading
        from app.services.import_outcome import ImportOutcome

        a = rig.source("a", "song.flac", b"one|t")
        b = rig.source("b", "song.flac", b"two|t")
        barrier = threading.Barrier(2, timeout=10)
        real_move = organizer.move_file
        first_call = threading.local()

        def move_after_both_chose(file_path, destination_path):
            if not getattr(first_call, "done", False):
                first_call.done = True
                barrier.wait()
            return real_move(file_path=file_path, destination_path=destination_path)

        monkeypatch.setattr(organizer, "move_file", move_after_both_chose)
        # The rig's per-call patches are not thread-safe: patch once, here.
        from tests.name_clash_rig import META
        monkeypatch.setattr(organizer, "get_track_metadata", lambda file_path: META)
        monkeypatch.setattr(organizer, "extract_cover_art_bytes", lambda path: None)
        outcomes = {}

        def run(path):
            outcomes[path.parent.name] = rig.organizer.organize(path)

        threads = [threading.Thread(target=run, args=(p,)) for p in (a, b)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=20)

        assert outcomes == {"a": ImportOutcome.IMPORTED, "b": ImportOutcome.IMPORTED}
        assert rig.names() == ["song (2).flac", "song.flac"]
        assert sorted((rig.folder / n).read_bytes() for n in rig.names()) == [b"one|t", b"two|t"]
        assert rig.track_names() == ["song (2).flac", "song.flac"]


class TestNamesNeverReplaceAFile:
    """Review r1 of U05-B-01: the guards the numbered-name rule relies on."""

    def test_moves_into_folders_differing_only_in_case_share_one_lock(self, tmp_path: Path, monkeypatch):
        """On a case-insensitive disk "ABBA/Gold" and "Abba/Gold" are one folder:
        two moves into them must not both pass the exists check before either
        replaces (the second would overwrite the first). Thread A is held inside
        its move (just before the rename); B's move must wait for A's lock."""
        import pathlib

        src_a, src_b = tmp_path / "a.flac", tmp_path / "b.flac"
        src_a.write_bytes(b"A")
        src_b.write_bytes(b"B")
        dest_a = tmp_path / "music" / "ABBA" / "Gold" / "song.flac"
        dest_b = tmp_path / "music" / "Abba" / "Gold" / "song.flac"
        inside, go = threading.Event(), threading.Event()
        real_replace = pathlib.Path.replace

        def held_replace(self, target):
            if Path(self) == src_a:
                inside.set()
                assert go.wait(10)
            return real_replace(self, target)

        monkeypatch.setattr(pathlib.Path, "replace", held_replace)
        results = {}
        ta = threading.Thread(target=lambda: results.update(a=organizer.move_file(src_a, dest_a)))
        ta.start()
        assert inside.wait(10)
        tb = threading.Thread(target=lambda: results.update(b=organizer.move_file(src_b, dest_b)))
        tb.start()
        tb.join(timeout=0.3)
        blocked = tb.is_alive()
        go.set()
        ta.join(timeout=10)
        tb.join(timeout=10)

        assert blocked, "a move into a case-variant folder did not wait for the folder lock"
        # Nothing lost: every byte string is still somewhere.
        contents = sorted(p.read_bytes() for p in tmp_path.rglob("*.flac"))
        assert contents == [b"A", b"B"]

    def test_a_dangling_symlink_at_the_destination_is_never_replaced(self, tmp_path: Path):
        src = tmp_path / "a.flac"
        src.write_bytes(b"A")
        dest = tmp_path / "music" / "song.flac"
        dest.parent.mkdir(parents=True)
        dest.symlink_to(tmp_path / "nowhere")

        assert organizer.move_file(src, dest) is False

        assert dest.is_symlink() and src.read_bytes() == b"A"

    def _organizer(self, tmp_path, **ctx):
        released = []
        org = organizer.Organizer(organizer.OrganizerContext(
            music_library_dir=tmp_path / "music", should_organize_files=True,
            should_copy_files=False, add_to_database=lambda track: True,
            add_cover_art=lambda image: CoverArtAddResult(cover_art_id=5, was_created=True),
            release_cover_art=lambda art_id: released.append(art_id) or True,
            **ctx))
        return org, released

    def _organize(self, org, source):
        meta = TrackMetaData(title="Song", artist="Artist", album="Album", codec="flac",
                             duration=1.0, has_album_art=True)
        with (
            patch("app.services.organizer.get_track_metadata", return_value=meta),
            patch("app.services.organizer.extract_cover_art_bytes", return_value=b"art"),
        ):
            return org.organize(source)

    def _source(self, tmp_path, content=b"one|t"):
        source = tmp_path / "import" / "song.flac"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(content)
        return source

    def test_a_database_error_reading_the_folder_releases_new_art(self, tmp_path: Path):
        from app.services.import_outcome import ImportOutcome

        def broken(folder):
            raise sqlite3.OperationalError("database is locked")

        org, released = self._organizer(tmp_path, folder_tracks=broken)
        source = self._source(tmp_path)

        assert self._organize(org, source) is ImportOutcome.DATABASE_ERROR

        assert released == [5]
        assert source.exists()

    def test_a_duplicate_releases_the_art_it_created(self, tmp_path: Path):
        from app.services.import_outcome import ImportOutcome

        org, released = self._organizer(tmp_path)
        source = self._source(tmp_path)
        taken = tmp_path / "music" / "Artist" / "Album" / "song.flac"
        taken.parent.mkdir(parents=True)
        taken.write_bytes(b"one|t")  # same bytes, no hashes

        assert self._organize(org, source) is ImportOutcome.DUPLICATE

        assert released == [5]

    def test_a_source_gone_during_a_race_ends_at_once(self, tmp_path: Path, monkeypatch):
        from app.services.import_outcome import ImportOutcome

        org, released = self._organizer(tmp_path)
        source = self._source(tmp_path)
        calls = []

        def taken_and_source_gone(file_path, destination_path):
            calls.append(destination_path)
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            destination_path.write_bytes(b"racer")
            Path(file_path).unlink(missing_ok=True)
            return False

        monkeypatch.setattr(organizer, "move_file", taken_and_source_gone)

        assert self._organize(org, source) is ImportOutcome.MOVE_FAILED

        assert len(calls) == 1 and released == [5]

    def test_rounds_of_refused_moves_end_as_move_failed(self, tmp_path: Path, monkeypatch):
        from app.services.import_outcome import ImportOutcome

        org, released = self._organizer(tmp_path)
        source = self._source(tmp_path)
        calls = []

        def always_taken(file_path, destination_path):
            calls.append(destination_path.name)
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            destination_path.write_bytes(f"racer {len(calls)}".encode())
            return False

        monkeypatch.setattr(organizer, "move_file", always_taken)

        assert self._organize(org, source) is ImportOutcome.MOVE_FAILED

        assert len(calls) == organizer.MAX_NAME_ATTEMPTS
        assert calls[:3] == ["song.flac", "song (2).flac", "song (3).flac"]
        assert source.read_bytes() == b"one|t" and released == [5]


class TestCaseVariantRowsAreEachCompared:
    def test_two_tracks_whose_names_differ_only_in_case_are_both_compared(self, tmp_path, monkeypatch):
        """Review r1 of U05-B-01: on a case-sensitive disk "Song.flac" and
        "song.flac" can both be tracks; the incoming file must be compared with
        each, or the same audio is imported twice."""
        from app.models import Track
        from app.services.import_outcome import ImportOutcome
        from tests.name_clash_rig import META, Rig, identity_of

        rig = Rig(tmp_path, monkeypatch)
        rig.seed_track("Song.flac", b"one|t")
        # Its case twin: only the row (a case-insensitive disk cannot hold both files).
        assert rig.db.add_track(Track(file_path=rig.folder / "song.flac", metadata=META,
                                      audio_identity=identity_of("two")))
        incoming = rig.source("b", "song.flac", b"two|retagged")

        assert rig.organize(incoming) is ImportOutcome.DUPLICATE
