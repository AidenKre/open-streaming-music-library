import hashlib
import sqlite3
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from threading import Lock

import imagehash
from PIL import Image, UnidentifiedImageError

from app.core.operator_log import operator_logger
from app.database import ANY_OWNER
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


@dataclass(frozen=True)
class CoverArtAddResult:
    cover_art_id: int
    was_created: bool


class CoverArtManager:
    PHASH_THRESHOLD = 10  # max Hamming distance (out of 64 bits)

    def __init__(self, ctx: CoverArtContext):
        self.ctx = ctx
        self.ctx.cover_art_dir.mkdir(parents=True, exist_ok=True)
        self._lock = Lock()

    def add_album_art(self, image_bytes: bytes) -> int:
        return self.add_album_art_with_status(image_bytes).cover_art_id

    def add_album_art_with_status(self, image_bytes: bytes) -> CoverArtAddResult:
        """Add cover art image. Returns the cover art ID.

        If an identical or perceptually similar image already exists,
        returns the existing ID instead of creating a duplicate.

        Raises ValueError if image_bytes is not a valid image.
        """
        try:
            img = Image.open(BytesIO(image_bytes))
            img.load()
        except (UnidentifiedImageError, OSError, SyntaxError, Image.DecompressionBombError) as e:
            raise ValueError(f"Invalid image bytes: {e}")

        ext = _FORMAT_TO_EXT.get(img.format or "", ".jpg")

        sha256 = hashlib.sha256(image_bytes).hexdigest()
        phash = imagehash.phash(img)
        phash_str = str(phash)
        phash_prefix = phash_str[:2]

        with self._lock:
            existing = self.ctx.database.get_cover_art_by_sha256(sha256)
            if existing is not None:
                return CoverArtAddResult(cover_art_id=existing.id, was_created=False)

            candidate = self._find_candidate_by_phash(phash, phash_prefix)
            if candidate is not None:
                return CoverArtAddResult(
                    cover_art_id=candidate.id,
                    was_created=False,
                )

            file_path = self.ctx.cover_art_dir / f"{sha256}{ext}"
            created_file = False
            try:
                try:
                    with file_path.open("xb") as f:
                        f.write(image_bytes)
                    created_file = True
                except FileExistsError:
                    # Another writer already materialized the canonical file.
                    pass

                try:
                    cover_art_id = self.ctx.database.insert_cover_art(
                        sha256=sha256,
                        phash=phash_str,
                        phash_prefix=phash_prefix,
                        file_path=str(file_path),
                    )
                    return CoverArtAddResult(
                        cover_art_id=cover_art_id,
                        was_created=True,
                    )
                except sqlite3.IntegrityError:
                    # Another worker won the race to persist this image.
                    existing = self.ctx.database.get_cover_art_by_sha256(sha256)
                    if existing is not None:
                        return CoverArtAddResult(
                            cover_art_id=existing.id,
                            was_created=False,
                        )

                    candidate = self._find_candidate_by_phash(phash, phash_prefix)
                    if candidate is not None:
                        return CoverArtAddResult(
                            cover_art_id=candidate.id,
                            was_created=False,
                        )
                    raise
            except Exception:
                if created_file and self.ctx.database.get_cover_art_by_sha256(sha256) is None:
                    file_path.unlink(missing_ok=True)
                raise

    def get_album_art(self, cover_art_id: int) -> Path | None:
        """Return the file path for a cover art ID, or None if not found."""
        row = self.ctx.database.get_cover_art_by_id(cover_art_id)
        if row is None:
            return None
        return row.file_path

    def release_if_unreferenced(self, cover_art_id: int) -> bool:
        """Remove the row and file only when no track references them. The file
        is removed inside the row's delete transaction, before the commit: a
        failed removal raises and keeps the row, so a later call can finish."""
        with self._lock:
            row = self.ctx.database.get_cover_art_by_id(cover_art_id)
            if row is None:
                return False
            return self.ctx.database.delete_cover_art(
                cover_art_id, owner_id=ANY_OWNER,
                remove_file=lambda: row.file_path.unlink(missing_ok=True),
            )

    def backfill_cover_art(self) -> None:
        """Backfill cover_art_id for tracks that have album art but no cover_art_id."""
        tracks = self.ctx.database.get_tracks_missing_cover_art(
            owner_id=ANY_OWNER
        )
        deleting = self.ctx.database.get_deleting_user_ids()
        tracks = [t for t in tracks if t.owner_id not in deleting]
        if not tracks:
            return

        total = len(tracks)
        operator_logger.info("Backfilling cover art for %d tracks...", total)

        for i, track in enumerate(tracks, 1):
            if not track.file_path.exists():
                operator_logger.warning(
                    "  [%d/%d] Skipping track %s (file not found)",
                    i, total, track.uuid_id,
                )
                continue

            art_bytes = extract_cover_art_bytes(track.file_path)
            if not art_bytes:
                operator_logger.warning(
                    "  [%d/%d] No art extracted for track %s",
                    i, total, track.uuid_id,
                )
                continue

            try:
                result = self.add_album_art_with_status(art_bytes)
                cover_art_id = result.cover_art_id
                updated = self.ctx.database.update_track_cover_art_id(
                    track.uuid_id, cover_art_id, owner_id=track.owner_id
                )
                if updated:
                    operator_logger.debug(
                        "  [%d/%d] Updated %s -> cover_art_id=%s",
                        i, total, track.uuid_id, cover_art_id,
                    )
                else:
                    operator_logger.warning(
                        "  [%d/%d] Failed to update DB for %s",
                        i, total, track.uuid_id,
                    )
                    if result.was_created:
                        # Art created for this track only: release it, not an orphan.
                        try:
                            self.release_if_unreferenced(cover_art_id)
                        except (ValueError, OSError) as e:
                            operator_logger.warning(
                                "  [%d/%d] Could not release cover_art_id=%s: %s",
                                i, total, cover_art_id, type(e).__name__,
                            )
            except ValueError as e:
                operator_logger.warning(
                    "  [%d/%d] Invalid art in track %s: %s",
                    i, total, track.uuid_id, e,
                )

        operator_logger.info("Cover art backfill complete.")

    def _find_candidate_by_phash(
        self,
        phash: imagehash.ImageHash,
        phash_prefix: str,
    ):
        candidates = self.ctx.database.get_cover_arts_by_phash_prefix(phash_prefix)
        for candidate in candidates:
            candidate_phash = imagehash.hex_to_hash(candidate.phash)
            distance = phash - candidate_phash
            if distance <= self.PHASH_THRESHOLD:
                return candidate
        return None
