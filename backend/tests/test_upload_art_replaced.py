"""7-fix-r0 F0-4 (7A.3c review r1 #6, O-7A3c-1): the art the journal recorded
as this operation's own (adopted by startup recovery, or created by an earlier
run) is given back through ``release_if_unreferenced`` (SC-16h) by the commit
worker's re-run, before the re-run registers and journals its own art, so a
crash at any point of that step leaves no image named by nothing. Art the
journal recorded as shared (not created) is never released."""

import sqlite3
from io import BytesIO

import pytest

from app.services.upload_publish import SimulatedCrash
from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import NOW, FakeArt, journal, make_commit_worker
from tests.upload_recovery_fixtures import WITH_ART, World, art_ids
from tests.upload_validation_fixtures import FakeProbe
from tests.upload_validation_fixtures import item_row


def _halves(direction: str) -> bytes:
    """Two images no dedupe rule (sha256 or perceptual hash) folds together."""
    from PIL import Image

    img = Image.new("L", (64, 64), 0)
    for x in range(64):
        for y in range(64):
            if (y if direction == "top" else x) < 32:
                img.putpixel((x, y), 255)
    out = BytesIO()
    img.save(out, "PNG")
    return out.getvalue()


FIRST, SECOND = _halves("top"), _halves("left")


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


def _imported_art(db, commit):
    assert item_row(db, commit)["state"] == "imported"
    [meta] = sql(db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (commit["track"],))
    return meta["cover_art_id"]


def test_the_two_images_are_distinct_art(db, music):
    world = World(db, music, image=FIRST)
    a = world.cover_art.add_album_art_with_status(FIRST)
    b = world.cover_art.add_album_art_with_status(SECOND)
    assert a.was_created and b.was_created and a.cover_art_id != b.cover_art_id


def test_adopted_art_replaced_by_the_rerun_is_released(db, music):
    first = World(db, music, image=FIRST)
    commit = first.crash_at("after_art_registered")
    first.recover()
    [adopted] = art_ids(db)
    assert journal(db, commit)["cover_art_created"] == 1

    second = World(db, music, image=SECOND)  # the re-run's work copy has other art
    second.restart()
    second.restart()

    art = _imported_art(db, commit)
    assert art != adopted
    assert art_ids(db) == [art]  # the adopted row is gone, not leaked


def test_created_art_journaled_by_an_earlier_run_and_replaced_is_released(db, music):
    first = World(db, music, image=FIRST)
    commit = first.crash_at("before_prepared_journal")
    [earlier] = art_ids(db)
    assert (journal(db, commit)["cover_art_id"], journal(db, commit)["cover_art_created"]) == (earlier, 1)

    second = World(db, music, image=SECOND)
    second.restart()
    second.restart()

    art = _imported_art(db, commit)
    assert art_ids(db) == [art]


@pytest.mark.parametrize("crash", ["before", "after"])
def test_a_crash_while_the_rerun_gives_back_earlier_art_leaves_none_named_by_nothing(
        db, music, monkeypatch, crash):
    """The re-run gives back the art an earlier run of the operation created
    before it registers and journals its own: a crash just before or just after
    that release leaves every image either named by the journal or gone."""
    first = World(db, music, image=FIRST)
    commit = first.crash_at("before_prepared_journal")
    [earlier] = art_ids(db)

    second = World(db, music, image=SECOND)
    real = second.cover_art.release_if_unreferenced

    def crashing_release(cover_art_id):
        if cover_art_id == earlier:
            if crash == "after":
                real(cover_art_id)
            raise SimulatedCrash(crash)
        return real(cover_art_id)

    monkeypatch.setattr(second.cover_art, "release_if_unreferenced", crashing_release)
    with pytest.raises(SimulatedCrash):
        second.restart()
    monkeypatch.setattr(second.cover_art, "release_if_unreferenced", real)
    second.restart()
    second.restart()

    art = _imported_art(db, commit)
    assert art_ids(db) == [art]


def test_a_crash_after_the_rerun_registered_its_art_leaves_none_named_by_nothing(db, music):
    """The earlier art is already given back and forgotten, so the journal names
    no art: start-up recovery adopts the image the re-run registered."""
    first = World(db, music, image=FIRST)
    commit = first.crash_at("before_prepared_journal")

    second = World(db, music, image=SECOND)
    second.crash_at("after_art_registered", commit=commit)
    second.restart()
    second.restart()

    art = _imported_art(db, commit)
    assert art_ids(db) == [art]


def test_a_shutdown_during_the_reruns_extraction_after_the_give_back_leaves_none_named_by_nothing(
        db, music):
    """The re-run has given back and forgotten the earlier art when a shutdown
    kills its cover extraction (which then reads no picture): the step is given
    back with the journal naming no art and no image left over; the next start
    adopts nothing (no image was registered), and the re-run imports with one
    image that the track names."""
    first = World(db, music, image=FIRST)
    commit = first.crash_at("before_prepared_journal")
    assert len(art_ids(db)) == 1

    second = World(db, music, image=SECOND)
    worker = None

    def killed_extraction(path, **kwargs):
        worker.request_stop()  # the shutdown arrives while the art is read
        return None  # a killed extraction reads no picture

    worker = make_commit_worker(db, music, boot_id="boot-shut-down", probe=FakeProbe(WITH_ART),
                                art=killed_extraction, cover_art=second.cover_art)
    assert worker.process_one() == "interrupted"

    row = journal(db, commit)
    assert (row["state"], row["cover_art_id"], row["cover_art_created"]) == ("committing", None, None)
    assert art_ids(db) == []
    second.restart()
    second.restart()

    art = _imported_art(db, commit)
    assert art is not None and art_ids(db) == [art]


class _ArtJournalFails:
    """The database, except that journaling a newly registered image fails
    (``raises``) or finds the lease gone (answers False)."""

    def __init__(self, db, how):
        self._db, self._how = db, how

    def __getattr__(self, name):
        return getattr(self._db, name)

    def record_upload_commit_art(self, **kwargs):
        if kwargs["cover_art_id"] is None:
            return self._db.record_upload_commit_art(**kwargs)
        if self._how == "raises":
            raise sqlite3.OperationalError("database is locked")
        return False


@pytest.mark.parametrize("how", ["raises", "answers False"])
def test_art_registered_by_a_rerun_whose_journaling_fails_is_given_back(db, music, how):
    first = World(db, music, image=FIRST)
    commit = first.crash_at("after_art_registered")
    first.recover()  # adopted: the journal names it as created
    assert journal(db, commit)["cover_art_created"] == 1

    second = World(db, music, image=SECOND)
    worker = make_commit_worker(_ArtJournalFails(db, how), music, boot_id="boot-art-journal",
                                probe=FakeProbe(WITH_ART), art=FakeArt(SECOND),
                                cover_art=second.cover_art)

    assert worker.process_one() == "failed"

    assert art_ids(db) == []


def test_a_rerun_never_gives_back_art_another_commit_journal_names(db, music):
    """The earlier run's image may since be named by another commit's journal
    (its registration found the same image): the re-run keeps it, so that
    commit does not lose its cover, and still owns it."""
    world = World(db, music, image=FIRST)
    commit = world.crash_at("before_prepared_journal")
    [earlier] = art_ids(db)
    other = world.commit(created_at=NOW + 60)
    sql(db, "UPDATE upload_commit_journal SET cover_art_id = ?, cover_art_created = 0"
            " WHERE owner_id = ? AND operation_uuid = ?", (earlier, other["owner_id"], other["op"]))

    worker = make_commit_worker(db, music, boot_id="boot-shared-art", probe=FakeProbe(WITH_ART),
                                art=FakeArt(FIRST), cover_art=world.cover_art)
    assert worker.process_one() == "prepared"

    assert earlier in art_ids(db)
    assert journal(db, other)["cover_art_id"] == earlier
    row = journal(db, commit)
    assert (row["state"], row["cover_art_id"], row["cover_art_created"]) == ("prepared", earlier, 1)


def test_shared_art_the_journal_did_not_create_is_never_released(db, music):
    first = World(db, music, image=FIRST)
    shared = first.cover_art.add_album_art_with_status(FIRST).cover_art_id  # no track uses it
    commit = first.crash_at("before_prepared_journal")
    assert (journal(db, commit)["cover_art_id"], journal(db, commit)["cover_art_created"]) == (shared, 0)

    second = World(db, music, image=SECOND)
    second.restart()
    second.restart()

    art = _imported_art(db, commit)
    assert sorted(art_ids(db)) == sorted([shared, art])


def test_adopted_art_the_rerun_no_longer_finds_is_released_after_the_import(db, music):
    # 7-fix-r0 review R0-3: the re-run registers no art at all.
    first = World(db, music, image=FIRST)
    commit = first.crash_at("after_art_registered")
    first.recover()
    assert len(art_ids(db)) == 1

    second = World(db, music, image=b"")  # the re-run extracts no artwork
    second.restart()
    second.restart()

    assert _imported_art(db, commit) is None
    assert art_ids(db) == []


def test_art_the_imported_track_uses_is_kept_by_the_cleanup(db, music):
    world = World(db, music, image=FIRST)
    commit = world.commit()

    world.restart()
    world.restart()

    art = _imported_art(db, commit)
    assert art is not None and art_ids(db) == [art]
