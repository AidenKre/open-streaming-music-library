"""7-fix-r0 F0-4 (7A.3c review r1 #6, O-7A3c-1): when the commit worker's
re-run registers different art than the art the journal recorded as this
operation's own (adopted by startup recovery, or created by an earlier run),
the replaced art is released through ``release_if_unreferenced`` (SC-16h).
Art the journal recorded as shared (not created) is never released."""

from io import BytesIO

import pytest

from tests.identity_worker_fixtures import sql
from tests.upload_commit_fixtures import journal
from tests.upload_recovery_fixtures import World, art_ids
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
