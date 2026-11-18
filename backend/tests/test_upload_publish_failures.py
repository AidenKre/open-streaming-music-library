"""7A.3b S5: failures in steps 4-5 that are not duplicate conflicts (spec §6
step 4 "Never replace an unrelated existing file; collision is a recoverable
error"; plan D38: ``track_path_in_use(final, owner_id=ANY_OWNER)`` under the
directory lock, case/NFD variants included; SC-16h: the insert re-registers art
whose row vanished). The rule is the preparation step's: journal ``failed`` /
``upload_commit_failed``, ``final_path`` NULL when nothing was placed, the
item back at ``review_ready`` (version + 1, retryable), this operation's own
file removed, created art released, outcome ``"failed"``; new crash seam
``after_failure_journal``."""

import json
import os
import uuid

import pytest

from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import make_db, sql
from tests.owned_database import add_test_user
from tests.upload_commit_fixtures import (
    FakeArt,
    FakeCoverArt,
    FakeProbe,
    accept,
    journal,
    make_commit_worker,
    ready_item,
    reservations,
)
from tests.upload_publish_fixtures import RecordingSeam, make_publisher, track_row
from tests.upload_validation_fixtures import detected, item_row


@pytest.fixture
def db(tmp_path):
    return make_db(tmp_path)


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def png() -> bytes:
    from io import BytesIO

    from PIL import Image

    out = BytesIO()
    Image.new("RGB", (16, 16), "red").save(out, "PNG")
    return out.getvalue()


def run(db, music, before=None, *, art=None, cover_art=None, extract_art=None, seam=None):
    """The real commit worker; ``before(prepared)`` runs between preparation and the publisher."""
    cover_art = cover_art or FakeCoverArt()
    publisher = make_publisher(db, music, cover_art=cover_art, seam=seam,
                               **({"extract_art": extract_art} if extract_art else {}))

    def after_prepared(prepared):
        if before is not None:
            before(prepared)
        return publisher(prepared)

    extra = {}
    if art:
        meta = detected()
        meta["has_album_art"] = True
        extra = {"probe": FakeProbe(meta), "art": FakeArt(art)}
    return make_commit_worker(db, music, cover_art=cover_art, after_prepared=after_prepared,
                              **extra).process_one()


def upload_rows(db, commit, purpose):
    return [r for r in reservations(db, commit["owner_id"])
            if r["purpose"] == purpose and r["subject_ref"] in (commit["op"], commit["item_uuid"])]


def other_users_track_at(db, path):
    other = add_test_user(db, "bob")
    sql(db, "INSERT INTO tracks (uuid_id, file_path, owner_id) VALUES (?, ?, ?)",
        (str(uuid.uuid4()), str(path), other))


def assert_failed(db, commit, version_before, *, final_none=True):
    row = journal(db, commit)
    assert row["state"] == "failed"
    assert row["error_code"] == "upload_commit_failed"
    assert (row["final_path"] is None) == final_none
    item = item_row(db, commit)
    assert item["state"] == "review_ready"
    assert item["review_version"] == version_before + 1
    assert item["error_code"] == "upload_commit_failed"
    assert item["error_retryable"] == 1
    assert item["error_message"]
    assert commit["source"].exists()
    assert len(upload_rows(db, commit, "upload_source")) == 1
    assert track_row(db, commit["track"]) is None
    assert sql(db, "SELECT 1 FROM trackmetadata WHERE uuid_id = ?", (commit["track"],)) == []
    assert sql(db, "SELECT 1 FROM track_audio_identity WHERE uuid_id = ?", (commit["track"],)) == []
    assert not commit["work"].exists()
    assert upload_rows(db, commit, "upload_work") == []
    assert sql(db, "SELECT item_uuid FROM upload_items WHERE state = 'duplicate'") == []


def setup(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    return commit, item_row(db, commit)["review_version"]


def test_another_users_master_at_the_final_path_is_a_collision(db, music):
    commit, version = setup(db, music)
    seen = {}

    def before(prepared):
        seen["final"] = prepared["final_path"]
        other_users_track_at(db, prepared["final_path"])

    assert run(db, music, before) == "failed"

    assert_failed(db, commit, version)
    assert not os.path.lexists(seen["final"])


def test_a_case_variant_of_another_tracks_path_is_a_collision(db, music):
    commit, version = setup(db, music)
    seen = {}

    def before(prepared):
        head, name = os.path.split(prepared["final_path"])
        seen["final"] = prepared["final_path"]
        other_users_track_at(db, os.path.join(head, name.upper()))

    assert run(db, music, before) == "failed"

    assert_failed(db, commit, version)
    assert not os.path.lexists(seen["final"])


def test_an_unrelated_existing_file_is_never_replaced(db, music):
    commit, version = setup(db, music)
    seen = {}

    def before(prepared):
        seen["final"] = prepared["final_path"]
        os.makedirs(os.path.dirname(prepared["final_path"]), exist_ok=True)
        with open(prepared["final_path"], "wb") as f:
            f.write(b"someone else's file")

    assert run(db, music, before) == "failed"

    assert_failed(db, commit, version)
    assert open(seen["final"], "rb").read() == b"someone else's file"


def test_a_work_file_that_vanished_before_the_move_fails_cleanly(db, music):
    commit, version = setup(db, music)
    seen = {}

    def before(prepared):
        seen["final"] = prepared["final_path"]
        os.unlink(prepared["work_path"])

    assert run(db, music, before) == "failed"

    assert_failed(db, commit, version)
    assert not os.path.lexists(seen["final"])


def test_an_unexpected_insert_error_after_the_move_removes_the_placed_file(db, music, monkeypatch):
    commit, version = setup(db, music)
    covers = FakeCoverArt(first_id=500)

    def boom(*args, **kwargs):
        raise RuntimeError("insert exploded")

    monkeypatch.setattr(db, "_insert_track_in", boom)

    assert run(db, music, art=b"img", cover_art=covers) == "failed"

    assert_failed(db, commit, version, final_none=False)
    assert not os.path.lexists(journal(db, commit)["final_path"])
    assert covers.released == [500]


@pytest.mark.parametrize("created, released", [(True, [500]), (False, [])])
def test_created_art_is_released_and_reused_art_is_not_on_a_collision(db, music, created, released):
    commit, version = setup(db, music)
    covers = FakeCoverArt(first_id=500)
    if not created:
        covers.add_album_art_with_status(b"img")  # another track's cover

    assert run(db, music, lambda p: other_users_track_at(db, p["final_path"]),
               art=b"img", cover_art=covers) == "failed"

    assert_failed(db, commit, version)
    assert covers.released == released


def _art_gone_run(db, music, tmp_path, extract_art):
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    commit, _ = setup(db, music)
    gone = {}

    def before(prepared):
        gone["id"] = journal(db, commit)["cover_art_id"]
        sql(db, "DELETE FROM cover_arts WHERE id = ?", (gone["id"],))

    outcome = run(db, music, before, art=png(), cover_art=manager, extract_art=extract_art)
    return commit, outcome, gone["id"]


def test_art_that_vanished_is_registered_again_from_the_file(db, music, tmp_path):
    image = png()
    commit, outcome, old = _art_gone_run(db, music, tmp_path, lambda path, **kw: image)

    assert outcome == "imported"
    art_id = sql(db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (commit["track"],))[0][
        "cover_art_id"]
    assert art_id is not None
    assert sql(db, "SELECT id FROM cover_arts WHERE id = ?", (art_id,)) != []
    row = journal(db, commit)
    assert (row["cover_art_id"], row["cover_art_created"]) == (art_id, 1)
    assert json.loads(row["final_metadata"])["cover_art_id"] in (old, art_id)


def test_art_that_vanished_and_is_gone_from_the_file_publishes_without_art(db, music, tmp_path):
    commit, outcome, _ = _art_gone_run(db, music, tmp_path, lambda path, **kw: None)

    assert outcome == "imported"
    assert sql(db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (commit["track"],)) == [
        {"cover_art_id": None}]
    assert track_row(db, commit["track"]) is not None


def test_art_registered_again_is_read_with_the_probed_demuxer_forced(db, music, tmp_path):
    """Review r1 7-R1-18: the final file is staged upload bytes too; the art
    extraction opens only that file (the demuxer the probe detected)."""
    calls = []

    def extract(path, **kwargs):
        calls.append(kwargs)
        return png()

    _commit, outcome, _ = _art_gone_run(db, music, tmp_path, extract)

    assert outcome == "imported"
    assert calls and all(c.get("input_format") == "flac" for c in calls)


def test_a_crash_after_the_failure_journal_leaves_the_work_file(db, music):
    commit, _ = setup(db, music)
    seam = RecordingSeam(crash_at="after_failure_journal")

    with pytest.raises(SimulatedCrash):
        run(db, music, lambda p: other_users_track_at(db, p["final_path"]), seam=seam)

    row = journal(db, commit)
    assert row["state"] == "failed"
    assert row["final_path"] is None
    assert commit["work"].exists()
    assert len(upload_rows(db, commit, "upload_work")) == 1
