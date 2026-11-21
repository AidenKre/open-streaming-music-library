"""7A.3c S12 (7A.3a review #2, SC-16h; exit proof "art recovers and shared art
survives"): a crash between registering a commit's embedded art and
journaling it leaves an art row nothing records. The re-run dedupes onto it
as "not created", so a later conflict or failure never released it (a leak).

At startup, for a ``committing`` journal that records no art but whose work
copy has embedded art, the journal step resolves that art again. When the
resolved art row is referenced by no track and no other journal, it is this
operation's: the journal records it as created. The re-run then gives that
art back and registers the image again as its own (a new id), so a crash at
any point leaves no image named by nothing. Art a track already uses is never
adopted, so it survives."""

import pytest

from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import journal
from tests.upload_publish_fixtures import library_track
from tests.upload_recovery_fixtures import World, art_ids
from tests.upload_validation_fixtures import item_row


@pytest.fixture
def music(tmp_path):
    path = tmp_path / "music"
    (path / ".uploads").mkdir(parents=True)
    return path


@pytest.fixture
def world(db, music):
    return World(db, music)


def test_unjournaled_art_is_adopted_by_its_committing_journal(world):
    commit = world.crash_at("after_art_registered")
    [art] = art_ids(world.db)
    assert journal(world.db, commit)["cover_art_id"] is None

    world.recover()

    row = journal(world.db, commit)
    assert (row["state"], row["cover_art_id"], row["cover_art_created"]) == ("committing", art, 1)


def test_a_conflict_after_the_crash_releases_the_adopted_art(world):
    library_track(world.db, world.music, b"audio-A")
    commit = world.crash_at("after_art_registered")

    world.restart()
    world.restart()

    assert item_row(world.db, commit)["state"] == "duplicate_conflict"
    assert art_ids(world.db) == []


def test_an_import_after_the_crash_keeps_one_art_row(world):
    # The re-run gives back the adopted image and registers it again (a new
    # id): one row is left, and the imported track names it.
    commit = world.crash_at("after_art_registered")
    assert len(art_ids(world.db)) == 1

    world.restart()
    world.restart()

    assert item_row(world.db, commit)["state"] == "imported"
    [meta] = sql(world.db, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (commit["track"],))
    assert art_ids(world.db) == [meta["cover_art_id"]]


def test_art_a_track_already_uses_is_never_adopted_and_survives(world):
    shared = world.cover_art.add_album_art_with_status(world.image).cover_art_id
    winner = library_track(world.db, world.music, b"audio-A")
    sql(world.db, "UPDATE trackmetadata SET cover_art_id = ? WHERE uuid_id = ?", (shared, winner))
    commit = world.crash_at("after_art_registered")

    world.recover()
    assert journal(world.db, commit)["cover_art_id"] is None

    world.restart()
    world.restart()

    assert item_row(world.db, commit)["state"] == "duplicate_conflict"
    assert art_ids(world.db) == [shared]


def test_art_another_operation_holds_is_never_adopted(world):
    first = world.crash_at("after_prepared_journal")  # journaled art, created by `first`
    [art] = art_ids(world.db)
    second = world.crash_at("after_art_registered")  # deduped onto the same image

    world.recover()

    assert journal(world.db, second)["cover_art_id"] is None
    assert (journal(world.db, first)["cover_art_id"], journal(world.db, first)["cover_art_created"]) == (art, 1)


def test_a_committing_journal_without_a_work_file_or_art_is_left_alone(world):
    commit = world.crash_at("after_work_fsync")  # before any art step
    commit["work"].unlink()

    world.recover()

    row = journal(world.db, commit)
    assert (row["state"], row["cover_art_id"], row["cover_art_created"]) == ("committing", None, None)
    assert art_ids(world.db) == []


def test_the_adoption_reads_the_work_copy_with_the_probed_demuxer_forced(world):
    """Review r1 7-R1-18 (in-piece review #1): the work copy is staged upload
    bytes; its art is read opening only that file."""
    from app.services.upload_recovery import reconcile_upload_commits
    from tests.upload_commit_fixtures import FakeExact

    world.crash_at("after_art_registered")
    calls = []

    def extract(path, **kwargs):
        calls.append(kwargs)
        return world.image

    reconcile_upload_commits(
        world.db, publisher=world.publisher(), uploads_root=world.music / ".uploads",
        music_library_dir=world.music, cover_art=world.cover_art, compute_exact=FakeExact(),
        extract_art=extract)

    assert calls and all(c.get("input_format") == "flac" for c in calls)
