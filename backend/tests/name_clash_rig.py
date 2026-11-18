"""Rig for bug row U05-B-01 (a different track that lands on a taken library
file name gets a numbered name). A real database and ``make_pipeline``; the
audio identity is faked from the file's bytes: ``b"<label>|<anything>"`` has
the audio ``<label>`` (same label = same audio, whatever follows the bar, as a
re-tagged copy would), and the label ``unavailable`` has no exact hash."""

import hashlib
from pathlib import Path
from unittest.mock import patch

from app.database import DatabaseContext
from app.models import Track, TrackMetaData
from app.services import audio_identity
from app.services.audio_identity import KIND_PCM, AudioIdentity, ExactAudioHash, ExactUnavailable
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.pipeline import make_pipeline
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL

META = TrackMetaData(title="Song", artist="Artist", album="Album", codec="flac", duration=1.0)


def identity_of(label: str) -> AudioIdentity:
    if label == "unavailable":
        return AudioIdentity(exact=ExactUnavailable("failed", "decode_error"),
                             tool_versions="ffmpeg 9", computed_at=1)
    digest = hashlib.sha256(label.encode()).hexdigest()
    return AudioIdentity(exact=ExactAudioHash(KIND_PCM, digest, 44100, 2, 16),
                         tool_versions="ffmpeg 9", computed_at=1)


class Rig:
    def __init__(self, tmp_path: Path, monkeypatch):
        self.tmp = tmp_path
        self.db = OwnedTestDatabase(
            DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL))
        assert self.db.initialize()
        manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=self.db))
        self.organizer, self.ingestor = make_pipeline(
            self.db.get_user(self.db.owner_id), database=self.db, cover_art_manager=manager,
            music_library_dir=tmp_path / "music", workspace_root=tmp_path / "workspace")
        self.root = self.organizer.ctx.music_library_dir
        self.folder = self.root / "Artist" / "Album"
        self.decoded: list[Path] = []

        def fake_compute(path, codec_hint, **kwargs):
            self.decoded.append(Path(path))
            return identity_of(Path(path).read_bytes().split(b"|")[0].decode())

        monkeypatch.setattr(audio_identity, "compute_identity", fake_compute)

    def source(self, sub: str, name: str, content: bytes) -> Path:
        path = self.tmp / "import" / sub / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def organize(self, path: Path, meta: TrackMetaData = META):
        with (
            patch("app.services.organizer.get_track_metadata", return_value=meta),
            patch("app.services.organizer.extract_cover_art_bytes", return_value=None),
        ):
            return self.organizer.organize(path)

    def seed_track(self, name: str, content: bytes, *, stored: bool = True) -> Path:
        """A track already in the library at ``folder/name``, its exact hash
        stored as current (``stored``) or left pending."""
        path = self.folder / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        label = content.split(b"|")[0].decode()
        track = Track(file_path=path, metadata=META,
                      audio_identity=identity_of(label) if stored else None)
        assert self.db.add_track(track)
        return path

    def names(self) -> list[str]:
        return sorted(p.name for p in self.folder.iterdir())

    def track_names(self) -> list[str]:
        return sorted(Path(t.file_path).name for t in self.db.get_tracks(owner_id=self.db.owner_id))
