import hashlib
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path

import imagehash
from PIL import Image, UnidentifiedImageError

from app.database.database import Database
from app.services.metadata import extract_cover_art_bytes


_FORMAT_TO_EXT = {
    "JPEG": ".jpg",
    "PNG": ".png",
    "WEBP": ".webp",
    "GIF": ".gif",
    "BMP": ".bmp",
    "TIFF": ".tiff",
}


@dataclass(frozen=True)
class CoverArtContext:
    cover_art_dir: Path
    database: Database


class CoverArtManager:
    PHASH_THRESHOLD = 10  # max Hamming distance (out of 64 bits)

    def __init__(self, ctx: CoverArtContext):
        self.ctx = ctx
        self.ctx.cover_art_dir.mkdir(parents=True, exist_ok=True)

    def add_album_art(self, image_bytes: bytes) -> int:
        """Add cover art image. Returns the cover art ID.

        If an identical or perceptually similar image already exists,
        returns the existing ID instead of creating a duplicate.

        Raises ValueError if image_bytes is not a valid image.
        """
        try:
            img = Image.open(BytesIO(image_bytes))
            img.load()
        except (UnidentifiedImageError, OSError, SyntaxError) as e:
            raise ValueError(f"Invalid image bytes: {e}")

        ext = _FORMAT_TO_EXT.get(img.format or "", ".jpg")

        # Exact dedup via SHA256
        sha256 = hashlib.sha256(image_bytes).hexdigest()
        existing = self.ctx.database.get_cover_art_by_sha256(sha256)
        if existing is not None:
            return existing.id

        # Perceptual dedup via phash
        phash = imagehash.phash(img)
        phash_str = str(phash)
        # Use first 2 hex chars (8 bits) for prefix bucketing. Broader than 4 chars
        # to reduce false negatives — with 10k images, ~39 candidates per bucket
        # is still trivial to compare via Hamming distance.
        phash_prefix = phash_str[:2]

        candidates = self.ctx.database.get_cover_arts_by_phash_prefix(phash_prefix)
        for candidate in candidates:
            candidate_phash = imagehash.hex_to_hash(candidate.phash)
            distance = phash - candidate_phash
            if distance <= self.PHASH_THRESHOLD:
                return candidate.id

        # No match — save to disk and insert
        file_path = self.ctx.cover_art_dir / f"{sha256}{ext}"
        file_path.write_bytes(image_bytes)

        try:
            cover_art_id = self.ctx.database.insert_cover_art(
                sha256=sha256,
                phash=phash_str,
                phash_prefix=phash_prefix,
                file_path=str(file_path),
            )
        except Exception:
            file_path.unlink(missing_ok=True)
            raise
        return cover_art_id

    def get_album_art(self, cover_art_id: int) -> Path | None:
        """Return the file path for a cover art ID, or None if not found."""
        row = self.ctx.database.get_cover_art_by_id(cover_art_id)
        if row is None:
            return None
        return row.file_path

    def remove_album_art(self, cover_art_id: int) -> bool:
        """Remove cover art by ID. Raises ValueError if ID doesn't exist."""
        row = self.ctx.database.get_cover_art_by_id(cover_art_id)
        if row is None:
            raise ValueError(f"Cover art with id {cover_art_id} does not exist")

        # Clear references from tracks before deleting
        self.ctx.database.clear_cover_art_references(cover_art_id)

        # Delete file from disk
        file_path = row.file_path
        if file_path.exists():
            file_path.unlink()

        # Delete database row
        return self.ctx.database.delete_cover_art(cover_art_id)

    def backfill_cover_art(self) -> None:
        """Backfill cover_art_id for tracks that have album art but no cover_art_id."""
        tracks = self.ctx.database.get_tracks_missing_cover_art()
        if not tracks:
            return

        total = len(tracks)
        print(f"Backfilling cover art for {total} tracks...")

        for i, track in enumerate(tracks, 1):
            if not track.file_path.exists():
                print(f"  [{i}/{total}] Skipping {track.file_path} (file not found)")
                continue

            art_bytes = extract_cover_art_bytes(track.file_path)
            if not art_bytes:
                print(f"  [{i}/{total}] No art extracted from {track.file_path}")
                continue

            try:
                cover_art_id = self.add_album_art(art_bytes)
                updated = self.ctx.database.update_track_cover_art_id(
                    track.uuid_id, cover_art_id
                )
                if updated:
                    print(f"  [{i}/{total}] Updated {track.uuid_id} -> cover_art_id={cover_art_id}")
                else:
                    print(f"  [{i}/{total}] Failed to update DB for {track.uuid_id}")
            except ValueError as e:
                print(f"  [{i}/{total}] Invalid art in {track.file_path}: {e}")

        print("Cover art backfill complete.")