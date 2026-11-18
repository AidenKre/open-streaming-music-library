"""Shared setup for the 7A.3c recovery/janitor tests: real cover art (so
"shared art survives" is checked by the real reference rule) and a PNG."""

from io import BytesIO
from pathlib import Path

from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from tests.identity_worker_fixtures import sql


def png(color: str = "red") -> bytes:
    from PIL import Image

    out = BytesIO()
    Image.new("RGB", (16, 16), color).save(out, "PNG")
    return out.getvalue()


def art_manager(db, art_dir: Path) -> CoverArtManager:
    return CoverArtManager(CoverArtContext(cover_art_dir=art_dir, database=db))


def art_ids(db) -> list[int]:
    return [row["id"] for row in sql(db, "SELECT id FROM cover_arts ORDER BY id")]


# ---- S2: crash and restart helpers (the real worker + publisher, fake tools) ----

import itertools  # noqa: E402

import pytest  # noqa: E402

from app.services.upload_publish import SimulatedCrash  # noqa: E402
from app.services.upload_recovery import reconcile_upload_commits  # noqa: E402
from tests.upload_commit_fixtures import FakeArt, FakeExact, accept, make_commit_worker, make_ledger, ready_item  # noqa: E402
from tests.upload_publish_fixtures import RecordingSeam, make_publisher  # noqa: E402
from tests.upload_validation_fixtures import FakeProbe, detected  # noqa: E402

WITH_ART = {**detected(), "has_album_art": True}
_boots = itertools.count(1)


class World:
    """One library + its cover art, shared across simulated restarts (the art
    manager is the DB + art dir, so it survives a 'restart')."""

    def __init__(self, db, music, image=None):
        self.db = db
        self.music = music
        self.cover_art = art_manager(db, music.parent / "art")
        self.image = image if image is not None else png()

    def publisher(self, seam=None):
        return make_publisher(self.db, self.music, cover_art=self.cover_art, seam=seam,
                              extract_art=FakeArt(self.image))

    def worker(self, *, seam=None, boot_id=None, after_prepared=None):
        return make_commit_worker(
            self.db, self.music, seam=seam, boot_id=boot_id or f"boot-{next(_boots)}",
            probe=FakeProbe(WITH_ART), art=FakeArt(self.image), cover_art=self.cover_art,
            after_prepared=after_prepared or self.publisher(seam))

    def commit(self, staged=None, **accept_kwargs) -> dict:
        staged = staged or ready_item(self.db, self.music / ".uploads")
        return accept(self.db, staged, **accept_kwargs)

    def crash_at(self, point: str, commit=None) -> dict:
        """Accept a commit (unless given) and run it until ``point`` kills it."""
        commit = commit or self.commit()
        seam = RecordingSeam(crash_at=point)
        with pytest.raises(SimulatedCrash):
            self.worker(seam=seam).process_one()
        assert seam.points[-1] == point
        return commit

    def recover(self, compute_exact=None) -> None:
        """The startup journal step alone."""
        reconcile_upload_commits(
            self.db, publisher=self.publisher(), uploads_root=self.music / ".uploads",
            music_library_dir=self.music, cover_art=self.cover_art,
            compute_exact=compute_exact or FakeExact(), extract_art=FakeArt(self.image))

    def restart(self) -> None:
        """A new boot: the journal step, the storage-reservation reconcile (it
        releases a dead boot's leased rows), then the commit worker drains its queue."""
        boot = f"boot-{next(_boots)}"
        self.recover()
        make_ledger(self.db, self.music, boot_id=boot).reconcile()
        worker = self.worker(boot_id=boot)
        for _ in range(20):
            if worker.process_one() == "idle":
                return
        raise AssertionError("the commit worker never went idle")
