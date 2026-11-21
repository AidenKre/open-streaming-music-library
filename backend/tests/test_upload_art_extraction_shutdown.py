"""A shutdown ends the cover extraction of an upload commit (spec SC-16e; the
organizer's import does the same through ``metadata.probes_killed_by``).

The commit worker reads the work copy's embedded art, and the publisher it
hands over to reads the final file's art again when the art row vanished. Both
run on the commit worker's thread; shutdown asks the worker to stop and closes
its kill registry. Each extraction runs registered in that registry, so the
close ends it instead of waiting out its own bound.

The staged bytes in these rigs are not real audio, so the extraction reads one
real file with an attached picture (``cover_file``) whatever path it is given:
what is under test is that its process is killed, not which file it opens.
"""

import json
from io import BytesIO

import pytest
from PIL import Image

from app.database import ANY_OWNER
from app.services import metadata
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.ffmpeg_runner import FfmpegProcessRegistry
from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import (
    FakeArt,
    FakeCoverArt,
    FakeProbe,
    accept,
    journal,
    make_commit_worker,
    ready_item,
)
from tests.upload_publish_fixtures import make_publisher
from tests.upload_validation_fixtures import detected

pytestmark = pytest.mark.requires_ffmpeg


@pytest.fixture(scope="module")
def cover_file(tmp_path_factory):
    import subprocess

    path = tmp_path_factory.mktemp("cover") / "song.m4a"
    subprocess.run(
        ["ffmpeg", "-nostdin", "-v", "error", "-y",
         "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
         "-f", "lavfi", "-i", "testsrc=size=64x64:rate=1:duration=1",
         "-map", "0:a", "-map", "1:v", "-c:a", "aac", "-c:v", "mjpeg", "-frames:v", "1",
         "-disposition:v", "attached_pic", "-f", "mp4", str(path)],
        check=True)
    return path


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _with_art():
    meta = detected()
    meta["has_album_art"] = True
    return FakeProbe(meta)


def _png() -> bytes:
    out = BytesIO()
    Image.new("RGB", (16, 16), "red").save(out, "PNG")
    return out.getvalue()


def _commit(db, music):
    return accept(db, ready_item(db, music / ".uploads"))


# --- the commit worker's art step ----------------------------------------------------------------


def _commit_run(db, music, cover_file, *, shutdown):
    registry = FfmpegProcessRegistry()
    covers = FakeCoverArt()
    worker = None

    def extract(path, **kwargs):
        if shutdown:  # the shutdown arrives while the art is being read
            worker.request_stop()
            registry.close()
        return metadata.extract_cover_art_bytes(cover_file, input_format="mov")

    worker = make_commit_worker(db, music, registry=registry, probe=_with_art(), art=extract,
                                cover_art=covers)
    return worker.process_one(), covers


def test_without_a_shutdown_the_commit_reads_the_cover(db, music, cover_file):
    commit = _commit(db, music)

    outcome, covers = _commit_run(db, music, cover_file, shutdown=False)

    assert outcome == "prepared"
    assert len(covers.calls) == 1  # the rig's file really has a cover
    assert journal(db, commit)["cover_art_id"] is not None


def test_a_shutdown_ends_the_commits_cover_extraction(db, music, cover_file):
    commit = _commit(db, music)

    outcome, covers = _commit_run(db, music, cover_file, shutdown=True)

    assert outcome == "interrupted"
    assert covers.calls == []  # the extraction was killed: no picture came back
    assert journal(db, commit)["state"] == "committing"  # given back, not prepared without its art


# --- the publisher's re-registration of art that vanished ----------------------------------------


def _publish_run(db, music, tmp_path, cover_file, *, shutdown):
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    commit = _commit(db, music)
    registry = FfmpegProcessRegistry()
    worker = None
    publisher = make_publisher(
        db, music, cover_art=manager,
        extract_art=lambda path, **kwargs: metadata.extract_cover_art_bytes(cover_file, input_format="mov"))

    def after_prepared(prepared):
        sql(db, "DELETE FROM cover_arts WHERE id = ?", (journal(db, commit)["cover_art_id"],))
        if shutdown:  # the shutdown arrives before the publisher reads the art again
            worker.request_stop()
            registry.close()
        return publisher(prepared)

    worker = make_commit_worker(db, music, registry=registry, probe=_with_art(), art=FakeArt(_png()),
                                cover_art=manager, after_prepared=after_prepared)
    outcome = worker.process_one()
    [row] = sql(db, "SELECT has_album_art, cover_art_id FROM trackmetadata WHERE uuid_id = ?",
                (commit["track"],))
    return outcome, commit, row


def test_without_a_shutdown_the_publisher_reads_the_cover_again(db, music, tmp_path, cover_file):
    outcome, _commit_row, row = _publish_run(db, music, tmp_path, cover_file, shutdown=False)

    assert outcome == "imported"
    assert row["cover_art_id"] is not None  # the rig's file really has a cover


def test_a_shutdown_ends_the_publishers_cover_extraction(db, music, tmp_path, cover_file):
    outcome, commit, row = _publish_run(db, music, tmp_path, cover_file, shutdown=True)

    assert outcome == "imported"
    # Killed: published without its cover, still marked as having one, so the
    # next start's cover backfill reads it again.
    assert (row["has_album_art"], row["cover_art_id"]) == (1, None)
    missing = db.get_tracks_missing_cover_art(owner_id=ANY_OWNER)
    assert commit["track"] in {t.uuid_id for t in missing}
    assert json.loads(journal(db, commit)["final_metadata"])["has_album_art"] is True
