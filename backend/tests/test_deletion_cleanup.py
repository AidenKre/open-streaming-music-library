"""Phase 8A.3c (spec §5 step 5, SC-16h, plan D12/D34; exit proof 2; review
8-D11, 8-U06): after the database commit the worker evicts the encoded caches,
releases the journaled cover art only when no track references it any more,
unlinks the quarantine copy only after an identity check, and prunes. A
clean-up failure keeps the committed journal and the item says
``storage_cleanup_pending``; the deletion stays committed.
"""

import os
from pathlib import Path

import pytest

from tests.deletion_world import (
    SpyCache,
    accept_job,
    add_art,
    add_master,
    build_world,
    files_under,
    item,
    journal,
    make_executor,
    one,
    path_of,
    revision,
    tombstone,
)


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def _art_file(world, art_id):
    row = one(world, "SELECT file_path FROM cover_arts WHERE id = ?", (art_id,))
    return None if row is None else Path(row[0])


def test_both_encoded_caches_are_evicted_for_the_track(world):
    uuid_id = add_master(world, "A/a.flac")
    accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world).run_one()

    assert world.cache.evicted == [uuid_id]
    assert world.default_cache.evicted == [uuid_id]


def test_the_last_reference_releases_the_cover_art(world):
    art = add_art(world, "dummy")
    art_file = _art_file(world, art)
    uuid_id = add_master(world, "A/a.flac", cover_art_id=art)
    accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world).run_one()

    assert one(world, "SELECT count(*) FROM cover_arts WHERE id = ?", (art,))[0] == 0
    assert not art_file.exists()


def test_shared_cover_art_survives_while_another_track_uses_it(world):
    art = add_art(world, "shared")
    art_file = _art_file(world, art)
    uuid_id = add_master(world, "A/a.flac", title="A", cover_art_id=art)
    other = add_master(world, "A/b.flac", title="B", cover_art_id=art)
    accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world).run_one()

    assert one(world, "SELECT count(*) FROM cover_arts WHERE id = ?", (art,))[0] == 1
    assert art_file.read_bytes() == b"art shared"
    assert one(world, "SELECT cover_art_id FROM trackmetadata WHERE uuid_id = ?", (other,)) == (art,)


def test_the_journaled_cover_art_is_released_even_though_the_metadata_is_gone(world):
    # The release uses the id written into the journal under the lock, because
    # trackmetadata is deleted by the commit.
    art = add_art(world, "journaled")
    uuid_id = add_master(world, "A/a.flac", cover_art_id=art)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    journaled = []
    make_executor(
        world,
        seam=lambda n: journaled.append(journal(world, uuid_id)["cover_art_id"])
        if n == "after_journal" else None,
    ).run_one()

    assert journaled == [art]
    assert item(world, op, uuid_id)["status"] == "deleted"
    assert one(world, "SELECT count(*) FROM cover_arts WHERE id = ?", (art,))[0] == 0


def _assert_cleanup_pending(world, op, uuid_id):
    it = item(world, op, uuid_id)
    assert it["status"] == "deleted"
    assert "storage_cleanup_pending" in it["details"]
    assert it["tombstone_revision"] == tombstone(world, uuid_id)[0]
    j = journal(world, uuid_id)
    assert j is not None and j["stage"] == "committed"
    return j


def test_a_cache_eviction_failure_keeps_the_journal_and_says_cleanup_pending(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world, cache=SpyCache(fail=True)).run_one()

    j = _assert_cleanup_pending(world, op, uuid_id)
    assert Path(j["quarantine_path"]).is_file()  # nothing unlinked after the failure


def test_an_art_release_failure_keeps_the_journal(world):
    art = add_art(world, "stuck")
    uuid_id = add_master(world, "A/a.flac", cover_art_id=art)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    class FailingArt:
        def release_if_unreferenced(self, cover_art_id):
            raise OSError("art store unavailable")

    make_executor(world, cover_art=FailingArt()).run_one()

    j = _assert_cleanup_pending(world, op, uuid_id)
    assert j["cover_art_id"] == art


@pytest.mark.requires_chmod_denial
def test_an_unlink_failure_keeps_the_quarantine_copy_and_the_journal(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    op_dir = world.music / ".deleting" / str(world.owner) / op

    def seam(name):
        if name == "after_evict":
            os.chmod(op_dir, 0o500)  # the unlink in this folder is refused

    try:
        make_executor(world, seam=seam).run_one()
    finally:
        os.chmod(op_dir, 0o700)

    j = _assert_cleanup_pending(world, op, uuid_id)
    assert Path(j["quarantine_path"]).read_bytes() == b"master A/a.flac"


def test_a_quarantine_file_that_is_not_ours_is_never_unlinked(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    stranger = world.tmp / "stranger.flac"

    def seam(name):
        if name == "after_evict":
            q = Path(journal(world, uuid_id)["quarantine_path"])
            q.unlink()
            stranger.write_bytes(b"master A/a.flac")  # same size, another inode
            os.replace(stranger, q)

    make_executor(world, seam=seam).run_one()

    j = _assert_cleanup_pending(world, op, uuid_id)
    assert Path(j["quarantine_path"]).read_bytes() == b"master A/a.flac"


def test_a_quarantine_path_replaced_by_a_symlink_is_never_followed(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    target = world.tmp / "outside.flac"
    target.write_bytes(b"outside")

    def seam(name):
        if name == "after_evict":
            q = Path(journal(world, uuid_id)["quarantine_path"])
            q.unlink()
            q.symlink_to(target)

    make_executor(world, seam=seam).run_one()

    j = _assert_cleanup_pending(world, op, uuid_id)
    assert Path(j["quarantine_path"]).is_symlink()
    assert target.read_bytes() == b"outside"


def test_the_emptied_operation_folder_is_removed(world):
    uuid_id = add_master(world, "A/a.flac")
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    master = path_of(world, uuid_id)
    owner_folder = world.music / ".deleting" / str(world.owner)

    make_executor(world).run_one()

    assert not os.path.lexists(master)  # it went through the operation folder
    assert not (owner_folder / op).exists()
    # Only the operation's own folder goes: the owner's and the base stay.
    assert owner_folder.is_dir() and (world.music / ".deleting").is_dir()
    assert files_under(world.music) == {}
