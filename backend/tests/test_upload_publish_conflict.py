"""7A.3b S4: duplicate_conflict recording and cleanup (spec §6 step 3 "Any match
not acknowledged stops the commit as `duplicate_conflict` listing those tracks";
step 5 "An unacknowledged match found here aborts the insert and enters
`duplicate_conflict` exactly as in step 3. Cleanup only this operation's moved
unreferenced file and unreferenced newly-created art; retain source and frozen
review"; §3 "never silently discard edits"; "A commit never resolves to
`duplicate` by itself"; SC-16h: created art is removed only through
``release_if_unreferenced``). The new crash seams are
``after_conflict_journal`` and ``after_conflict_cleanup``."""

import json
import os
from io import BytesIO

import pytest
from PIL import Image

from app.database.database import DatabaseContext
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import sql
from tests.owned_database import OwnedTestDatabase
from tests.schema_fixtures import INIT_SQL
from tests.track_paths import PATH_COLUMNS, PATH_MARKS, path_values
from tests.upload_commit_fixtures import (
    NOW,
    FakeArt,
    FakeCoverArt,
    FakeProbe,
    accept,
    journal,
    library_root,
    make_commit_worker,
    ready_item,
    reservations,
)
from tests.upload_publish_fixtures import RecordingSeam, frozen_acks, library_track, make_publisher, track_row
from tests.upload_validation_fixtures import detected, item_row, new_uuid

KEPT_COLUMNS = ("review_version", "source_path", "detected_metadata", "duplicate_report")


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def png(color="red") -> bytes:
    out = BytesIO()
    Image.new("RGB", (16, 16), color).save(out, "PNG")
    return out.getvalue()


def art_meta():
    meta = detected()
    meta["has_album_art"] = True
    return meta


def second_db(db):
    other = OwnedTestDatabase(DatabaseContext(database_path=db.context.database_path, init_sql_path=INIT_SQL))
    assert other.initialize()
    return other


def worker(db, music, *, cover_art=None, art=None, publisher_cover_art=None, seam=None, **kwargs):
    """A real commit worker with the publisher; ``art`` (bytes) makes the probe report embedded art."""
    cover_art = cover_art or FakeCoverArt()
    extra = {"probe": FakeProbe(art_meta()), "art": FakeArt(art)} if art else {}
    publisher = make_publisher(db, music, cover_art=publisher_cover_art or cover_art, seam=seam)
    return make_commit_worker(db, music, cover_art=cover_art, after_prepared=publisher, **extra, **kwargs)


def kept(db, commit):
    row = item_row(db, commit)
    return {k: row[k] for k in KEPT_COLUMNS}


def upload_rows(db, commit, purpose):
    return [r for r in reservations(db, commit["owner_id"])
            if r["purpose"] == purpose and r["subject_ref"] in (commit["op"], commit["item_uuid"])]


def library_files(db, music, commit):
    root = library_root(db, music, commit["owner_id"])
    return [p for p in root.rglob("*") if p.is_file()] if root.exists() else []


def never_duplicate(db):
    assert sql(db, "SELECT item_uuid FROM upload_items WHERE state = 'duplicate'") == []


# ---- conflict found before the move ----

def test_a_preflight_conflict_is_recorded_and_cleaned(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    lib = library_track(db, music)  # a watch-folder ingest between review and commit
    before = kept(db, commit)
    covers = FakeCoverArt(first_id=500)

    assert worker(db, music, cover_art=covers, art=b"img").process_one() == "duplicate_conflict"

    row = journal(db, commit)
    assert row["state"] == "duplicate_conflict"
    assert row["final_path"] is None
    item = item_row(db, commit)
    assert item["state"] == "duplicate_conflict"
    assert json.loads(item["conflict_track_uuids"]) == [lib]
    assert kept(db, commit) == before
    assert commit["source"].exists()
    assert len(upload_rows(db, commit, "upload_source")) == 1
    assert track_row(db, commit["track"]) is None
    assert library_files(db, music, commit) == []
    assert not commit["work"].exists()
    assert upload_rows(db, commit, "upload_work") == []
    assert covers.released == [500]  # this operation created it
    never_duplicate(db)


def test_art_the_operation_only_reused_is_not_released(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    library_track(db, music)
    covers = FakeCoverArt(first_id=500)
    covers.add_album_art_with_status(b"img")  # another track's cover

    assert worker(db, music, cover_art=covers, art=b"img").process_one() == "duplicate_conflict"

    assert covers.released == []
    assert item_row(db, commit)["state"] == "duplicate_conflict"


def test_a_stale_pending_digest_is_a_conflict_too(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    lib = library_track(db, music, exact_state="pending")

    assert worker(db, music).process_one() == "duplicate_conflict"

    assert json.loads(item_row(db, commit)["conflict_track_uuids"]) == [lib]
    never_duplicate(db)


def test_every_unacknowledged_match_is_listed_but_not_the_acknowledged_one(db, music):
    libs = sorted(library_track(db, music) for _ in range(4))
    acked, open_ones = libs[0], libs[1:]
    commit = accept(db, ready_item(db, music / ".uploads"), acks=frozen_acks(library_tracks=[acked]))

    assert worker(db, music).process_one() == "duplicate_conflict"

    assert sorted(json.loads(item_row(db, commit)["conflict_track_uuids"])) == open_ones
    never_duplicate(db)


# ---- conflict found inside the insert transaction (the race guard) ----

def _a_and_b(db, music):
    a = accept(db, ready_item(db, music / ".uploads"), created_at=NOW)
    b = accept(db, ready_item(db, music / ".uploads"), created_at=NOW + 1)
    return a, b


def _race(db, music, a, b, *, a_kwargs=None, b_kwargs=None, also=None):
    """A's run, with B's whole commit on an independent Database at A's after_work_unlink."""
    other = second_db(db)
    b_outcomes = []

    def seam(name):
        if name == "after_work_unlink":
            b_outcomes.append(worker(other, music, **(b_kwargs or {})).process_one())
        if also is not None:
            also(name)

    return worker(db, music, seam=seam, **(a_kwargs or {})), b_outcomes


def test_a_conflict_inside_the_transaction_removes_only_this_operations_file(db, music):
    a, b = _a_and_b(db, music)
    a_worker, b_outcomes = _race(db, music, a, b)

    assert a_worker.process_one() == "duplicate_conflict"

    assert b_outcomes == ["imported"]
    row = journal(db, a)
    assert row["state"] == "duplicate_conflict"
    assert row["final_path"] is not None  # this operation placed a file there
    assert not os.path.exists(row["final_path"])
    assert track_row(db, a["track"]) is None
    assert not a["work"].exists()
    assert upload_rows(db, a, "upload_work") == []
    assert json.loads(item_row(db, a)["conflict_track_uuids"]) == [b["track"]]
    assert item_row(db, a)["state"] == "duplicate_conflict"
    assert a["source"].exists()
    b_final = journal(db, b)["final_path"]
    assert os.path.isfile(b_final)
    assert track_row(db, b["track"])["file_path"] == b_final
    never_duplicate(db)


def test_a_preflight_conflict_after_the_other_item_fully_imported(db, music):
    b = accept(db, ready_item(db, music / ".uploads"), created_at=NOW)
    a = accept(db, ready_item(db, music / ".uploads"), created_at=NOW + 1)

    assert worker(db, music).process_one() == "imported"  # B (older)
    assert worker(db, music).process_one() == "duplicate_conflict"

    assert item_row(db, b)["state"] == "imported"
    assert item_row(db, a)["state"] == "duplicate_conflict"
    assert journal(db, a)["final_path"] is None
    assert json.loads(item_row(db, a)["conflict_track_uuids"]) == [b["track"]]
    assert os.path.isfile(journal(db, b)["final_path"])
    never_duplicate(db)


# ---- shared art with a real CoverArtManager ----

def _managers(db, other, tmp_path):
    art_dir = tmp_path / "art"
    return (CoverArtManager(CoverArtContext(cover_art_dir=art_dir, database=db)),
            CoverArtManager(CoverArtContext(cover_art_dir=art_dir, database=other)))


def test_the_loser_keeps_the_winners_shared_art(db, music, tmp_path):
    other = second_db(db)
    manager_a, manager_b = _managers(db, other, tmp_path)
    image = png()
    a, b = _a_and_b(db, music)
    b_outcomes = []

    def seam(name):
        if name == "after_work_unlink":  # A created art X in its prepare; B dedupes onto it
            b_outcomes.append(worker(other, music, cover_art=manager_b, art=image).process_one())

    a_worker = worker(db, music, cover_art=manager_a, art=image, seam=seam)

    assert a_worker.process_one() == "duplicate_conflict"

    assert b_outcomes == ["imported"]
    assert journal(db, a)["cover_art_created"] == 1
    assert journal(db, b)["cover_art_created"] == 0
    x = journal(db, a)["cover_art_id"]
    assert journal(db, b)["cover_art_id"] == x
    [art_row] = sql(db, "SELECT id, file_path FROM cover_arts WHERE id = ?", (x,))
    assert os.path.isfile(art_row["file_path"])
    assert sql(db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (b["track"],)) == [
        {"cover_art_id": x}]
    never_duplicate(db)


def test_a_loser_that_created_unreferenced_art_releases_it(db, music, tmp_path):
    manager = CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db))
    commit = accept(db, ready_item(db, music / ".uploads"))
    library_track(db, music)

    assert worker(db, music, cover_art=manager, art=png()).process_one() == "duplicate_conflict"

    x = journal(db, commit)["cover_art_id"]
    assert x is not None
    assert sql(db, "SELECT id FROM cover_arts WHERE id = ?", (x,)) == []
    assert list((tmp_path / "art").iterdir()) == []


# ---- crash seams ----

def test_a_crash_after_the_conflict_journal_from_preflight(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    library_track(db, music)
    seam = RecordingSeam(crash_at="after_conflict_journal")

    with pytest.raises(SimulatedCrash):
        worker(db, music, seam=seam).process_one()

    row = journal(db, commit)
    assert row["state"] == "duplicate_conflict"
    assert row["final_path"] is None
    assert commit["work"].exists()
    assert len(upload_rows(db, commit, "upload_work")) == 1


def test_a_crash_after_the_conflict_journal_from_the_transaction(db, music):
    a, b = _a_and_b(db, music)
    crash = RecordingSeam(crash_at="after_conflict_journal")
    a_worker, _ = _race(db, music, a, b, also=crash)

    with pytest.raises(SimulatedCrash):
        a_worker.process_one()

    row = journal(db, a)
    assert row["state"] == "duplicate_conflict"
    assert row["final_path"] is not None
    assert os.path.isfile(row["final_path"])  # cleanup had not run
    assert track_row(db, a["track"]) is None


def test_a_crash_after_the_conflict_cleanup_leaves_the_art_unreleased(db, music):
    commit = accept(db, ready_item(db, music / ".uploads"))
    library_track(db, music)
    covers = FakeCoverArt(first_id=500)
    seam = RecordingSeam(crash_at="after_conflict_cleanup")

    with pytest.raises(SimulatedCrash):
        worker(db, music, cover_art=covers, art=b"img", seam=seam).process_one()

    assert covers.released == []
    assert not commit["work"].exists()
    assert journal(db, commit)["state"] == "duplicate_conflict"


def test_a_final_file_that_a_track_now_names_is_never_removed(db, music):
    """Mutation M5 (lead): the loser removes its placed file only when no track of
    any owner names that path (D38); otherwise the file is left for 7A.3c."""
    from tests.owned_database import add_test_user

    a, b = _a_and_b(db, music)
    other = add_test_user(db, "bob")

    def claim(name):
        if name == "after_conflict_journal":
            sql(db, f"INSERT INTO tracks (uuid_id, {PATH_COLUMNS}, owner_id) VALUES (?, {PATH_MARKS}, ?)",
                (new_uuid(), *path_values(journal(db, a)["final_path"]), other))

    a_worker, _ = _race(db, music, a, b, also=claim)

    assert a_worker.process_one() == "duplicate_conflict"

    assert os.path.isfile(journal(db, a)["final_path"])
