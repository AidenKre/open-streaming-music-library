"""Phase 8A.3d S4 (spec §5 "Journal + matching tombstone/job deleted + no live
track: finish cache/cover/quarantine cleanup, never restore deleted master";
step 5 "Cache/cleanup failure keeps a retryable journal/task"; review 8-U06,
8-D09, 8-D11): the "deletion janitor".

- A committed journal whose clean-up is pending is finished: both caches
  evicted, the journaled cover art released, the quarantine file unlinked only
  when it is, by ``lstat``, the journaled file at exactly
  ``.deleting/<owner>/<op>/<uuid><ext>`` under real folders; empty folders
  pruned; the journal row deleted; the item's ``storage_cleanup_pending``
  detail dropped. The master is never restored.
- A quarantine file that is not provably ours, an unreadable identity, a forged
  or symlinked quarantine path, or a committed journal without its tombstone:
  the journal is kept and nothing is unlinked.
- A file under ``.deleting/<owner>/`` that no journal row names is reported
  (count only, never a path) and never deleted.
- A crash inside the janitor's own pass is finished by the next pass.
"""

import logging
import os

import pytest

from app.services.upload_publish import SimulatedCrash
from tests.deletion_recovery_helpers import (
    crash_at,
    crashed_at,
    disk,
    janitor,
)
from tests.deletion_world import (
    add_art,
    add_master,
    build_world,
    item,
    journal,
    live,
    one,
    path_of,
    revision,
    sql,
    tombstone,
)

@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def quarantine_of(world, uuid_id):
    return journal(world, uuid_id)["quarantine_path"]


def assert_kept(world, uuid_id, op, before):
    assert journal(world, uuid_id) == before["journal"]
    assert disk(world) == before["disk"]
    assert item(world, op, uuid_id)["details"] == ["storage_cleanup_pending"]
    assert tombstone(world, uuid_id) is not None and not live(world, uuid_id)


def snapshot(world, uuid_id):
    return {"journal": journal(world, uuid_id), "disk": disk(world)}


# ── committed clean-up ──────────────────────────────────────────────────────


@pytest.mark.parametrize("point", ["after_commit", "after_evict"])
def test_a_committed_deletion_is_cleaned_up_and_never_restored(world, point):
    art = add_art(world, "only")
    uuid_id, rev, op = crashed_at(world, point, cover_art_id=art)
    master = journal(world, uuid_id)["original_path"]
    q = quarantine_of(world, uuid_id)
    assert os.path.exists(q)
    tomb = tombstone(world, uuid_id)
    world.cache.evicted.clear()
    world.default_cache.evicted.clear()

    janitor(world).retry_cleanups()

    assert not os.path.lexists(q) and not os.path.lexists(master)
    assert not os.path.exists(os.path.dirname(master))  # empty album folder pruned
    assert journal(world, uuid_id) is None
    assert tombstone(world, uuid_id) == tomb
    after = item(world, op, uuid_id)
    assert (after["status"], after["details"]) == ("deleted", [])
    assert world.cache.evicted == [uuid_id] and world.default_cache.evicted == [uuid_id]
    assert one(world, "SELECT count(*) FROM cover_arts WHERE id = ?", (art,))[0] == 0


def test_a_crash_after_the_unlink_only_finishes_the_bookkeeping(world):
    uuid_id, rev, op = crashed_at(world, "after_unlink")
    assert not os.path.lexists(quarantine_of(world, uuid_id))

    janitor(world).retry_cleanups()

    assert journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["details"] == []


def test_a_committed_catalog_only_deletion_keeps_its_master_missing_detail(world):
    uuid_id, rev, op = crashed_at(world, "after_commit", create_file=False)

    janitor(world).retry_cleanups()

    assert journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["details"] == ["master_missing"]


def test_cleaning_twice_changes_nothing_more(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    janitor(world).retry_cleanups()
    first = (disk(world), journal(world, uuid_id), item(world, op, uuid_id), tombstone(world, uuid_id))

    janitor(world).retry_cleanups()

    assert (disk(world), journal(world, uuid_id), item(world, op, uuid_id), tombstone(world, uuid_id)) == first


def test_a_crash_inside_the_janitor_is_finished_by_the_next_pass(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    with pytest.raises(SimulatedCrash):
        janitor(world, seam=crash_at("after_evict")).retry_cleanups()
    assert journal(world, uuid_id) is not None

    janitor(world).retry_cleanups()

    assert journal(world, uuid_id) is None and item(world, op, uuid_id)["details"] == []


def test_another_owners_committed_deletion_is_cleaned_in_its_own_quarantine(world):
    mine = add_master(world, "A/a.flac")
    theirs, rev, op = crashed_at(world, "after_commit", owner=world.sam)
    q = quarantine_of(world, theirs)
    assert q.startswith(str(world.music / ".deleting" / str(world.sam)))

    janitor(world).retry_cleanups()

    assert not os.path.lexists(q) and journal(world, theirs) is None
    assert path_of(world, mine).exists() and live(world, mine)


def test_one_failing_row_does_not_stop_the_others(world):
    bad, _, bad_op = crashed_at(world, "after_commit", "A/bad.flac")
    good, _, good_op = crashed_at(world, "after_commit", "A/good.flac")
    world.cache.fail = True  # every eviction raises: both rows stay
    janitor(world).retry_cleanups()
    assert journal(world, bad) is not None and journal(world, good) is not None
    world.cache.fail = False

    janitor(world).retry_cleanups()

    assert journal(world, bad) is None and journal(world, good) is None


# ── never unlinked without proof ────────────────────────────────────────────


def test_a_different_file_in_quarantine_is_kept(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    q = quarantine_of(world, uuid_id)
    os.unlink(q)
    with open(q, "wb") as f:
        f.write(b"someone else's file")
    before = snapshot(world, uuid_id)

    janitor(world).retry_cleanups()

    assert_kept(world, uuid_id, op, before)


@pytest.mark.requires_chmod_denial
def test_an_unreadable_quarantine_identity_is_kept(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    folder = os.path.dirname(quarantine_of(world, uuid_id))
    before = snapshot(world, uuid_id)
    os.chmod(folder, 0)
    try:
        janitor(world).retry_cleanups()
    finally:
        os.chmod(folder, 0o755)

    assert_kept(world, uuid_id, op, before)


def test_a_forged_quarantine_path_outside_the_quarantine_deletes_nothing(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    outside = world.tmp / "outside" / f"{uuid_id}.flac"
    outside.parent.mkdir()
    os.rename(quarantine_of(world, uuid_id), outside)
    sql(world, "UPDATE deletion_journal SET quarantine_path = ? WHERE uuid_id = ?", (str(outside), uuid_id))
    before = snapshot(world, uuid_id)

    janitor(world).retry_cleanups()

    assert_kept(world, uuid_id, op, before)
    assert outside.exists()


def test_a_symlinked_owner_quarantine_folder_is_never_followed(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    owner_q = world.music / ".deleting" / str(world.owner)
    real = world.tmp / "real-quarantine"
    os.rename(owner_q, real)
    os.symlink(real, owner_q)
    before = snapshot(world, uuid_id)

    janitor(world).retry_cleanups()

    assert_kept(world, uuid_id, op, before)


def test_a_committed_journal_without_its_tombstone_is_kept(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    sql(world, "DELETE FROM track_tombstones WHERE uuid_id = ?", (uuid_id,))
    before = snapshot(world, uuid_id)

    janitor(world).retry_cleanups()

    assert journal(world, uuid_id) == before["journal"] and disk(world) == before["disk"]


def test_an_uncommitted_journal_is_only_ever_rolled_back_by_the_janitor(world):
    # Changed by fix round 1 (TR-DELETE-03): the periodic pass now re-runs the
    # startup verdict for uncommitted journals, so one kept for a reason that
    # went away does not wait for a restart. It never commits or cleans one up
    # as a deletion: here (quarantined, original free) it restores the master.
    # Was: the janitor left an uncommitted journal untouched.
    uuid_id, rev, op = crashed_at(world, "after_rename")
    master = path_of(world, uuid_id)
    q = quarantine_of(world, uuid_id)
    quarantined = open(q, "rb").read()

    janitor(world).retry_cleanups()

    assert journal(world, uuid_id) is None
    assert tombstone(world, uuid_id) is None
    assert live(world, uuid_id) and revision(world, uuid_id) == rev
    assert master.read_bytes() == quarantined
    assert not os.path.exists(q)


# ── orphans: reported, never deleted ────────────────────────────────────────


def test_a_quarantine_file_with_no_journal_is_reported_and_kept(world, caplog):
    stray = world.music / ".deleting" / str(world.owner) / "some-op" / "secret-name.flac"
    stray.parent.mkdir(parents=True)
    stray.write_bytes(b"no record of this")
    kept_uuid, _, _ = crashed_at(world, "after_moved")  # its file is not an orphan

    with caplog.at_level(logging.INFO):
        assert janitor(world).report_orphans() == 1

    assert stray.read_bytes() == b"no record of this"
    assert os.path.exists(quarantine_of(world, kept_uuid))
    warnings = [r for r in caplog.records if r.levelno >= logging.WARNING]
    assert warnings and all("secret-name" not in r.getMessage() for r in caplog.records)
    assert all(str(world.music) not in r.getMessage() for r in caplog.records)


def test_orphans_of_every_owner_are_counted_and_symlinks_are_not_followed(world):
    deleting = world.music / ".deleting"
    (deleting / str(world.sam) / "op").mkdir(parents=True)
    (deleting / str(world.sam) / "op" / "x.flac").write_bytes(b"x")
    outside = world.tmp / "outside"
    outside.mkdir()
    (outside / "a.flac").write_bytes(b"a")
    (outside / "b.flac").write_bytes(b"b")
    os.symlink(outside, deleting / str(world.owner))

    count = janitor(world).report_orphans()

    assert count == 1  # the symlinked owner folder is not walked
    assert sorted(p.name for p in outside.iterdir()) == ["a.flac", "b.flac"]
    assert (deleting / str(world.sam) / "op" / "x.flac").exists()


def test_the_startup_pass_cleans_and_reports(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    stray = world.music / ".deleting" / str(world.owner) / "op" / "stray.flac"
    stray.parent.mkdir(parents=True)
    stray.write_bytes(b"s")

    janitor(world).run_startup_pass()

    assert journal(world, uuid_id) is None and stray.exists()
