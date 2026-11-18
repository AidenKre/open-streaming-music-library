"""Phase 8A.3c (spec §5 steps 2-5; plan exit proof 1; review 8-D02, 8-U04,
8-U06): a one-track job deletes the master through the journal and the
quarantine, writes the tombstone, removes the FTS row and orphaned parents, and
keeps history rows, conversion audit rows and upload receipts.

The test seam records each boundary; the state seen there is what a crash at
that point would leave for startup recovery (piece 8A.3d).
"""

import os
from pathlib import Path

import pytest

from tests.deletion_world import (
    BOOT,
    accept_job,
    add_master,
    build_world,
    files_under,
    item,
    journal,
    live,
    make_executor,
    one,
    path_of,
    revision,
    sql,
    tombstone,
)

SEAMS = [
    "after_claim", "after_journal", "after_rename", "after_moved",
    "after_commit", "after_evict", "after_unlink",
]


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def _fts(world, token):
    return one(world, "SELECT count(*) FROM fts_tracks WHERE fts_tracks MATCH ?", (token,))[0]


def _keep_rows(world, uuid_id):
    """History, conversion audit and upload receipt rows naming the track."""
    sql(world, "INSERT INTO history_events (event_uuid, revision, kind, entity_type, entity_ref,"
               " occurred_at, received_at, owner_id) VALUES ('ev-1', 1, 'play', 'track', ?, 1, 1, ?)",
        (uuid_id, world.owner))
    sql(world, "INSERT INTO conversion_jobs (uuid_id, target_codec, target_container, status,"
               " owner_id) VALUES (?, 'aac', 'm4a', 'done', ?)", (uuid_id, world.owner))
    sql(world, "INSERT INTO upload_batches (owner_id, batch_uuid, label, created_at, updated_at)"
               " VALUES (?, 'batch-1', 'upload', 0, 0)", (world.owner,))
    sql(world, "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, selection_index,"
               " expected_bytes, expected_sha256, state, result_track_uuid, result_revision, created_at,"
               " updated_at, progress_at)"
               " VALUES (?, 'item-1', 'batch-1', 'a.flac', 0, 1, ?, 'imported', ?, 1, 0, 0, 0)",
        (world.owner, "0" * 64, uuid_id))
    sql(world, "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash,"
               " created_at, result_ref) VALUES (?, 'up-op', 'upload_commit', ?, 0, 'item-1')",
        (world.owner, "f" * 64))


def _kept(world):
    return {
        t: sql(world, f"SELECT * FROM {t} ORDER BY rowid")
        for t in ("history_events", "conversion_jobs", "upload_items", "upload_batches")
    } | {"receipts": sql(world, "SELECT * FROM operation_receipts WHERE kind = 'upload_commit'")}


def test_a_one_track_job_deletes_the_master_and_the_catalog_rows(world):
    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac",
                         title="Mysterons", artist="Portishead", album="Dummy")
    keep = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    master = path_of(world, uuid_id)
    rev = revision(world, uuid_id)
    _keep_rows(world, uuid_id)
    kept_before = _kept(world)
    op = accept_job(world, (uuid_id, rev))
    keep_bytes = path_of(world, keep).read_bytes()

    assert make_executor(world).run_one() is True

    # The master is gone, and so is its quarantine copy and the emptied folders.
    assert not os.path.lexists(master)
    assert files_under(world.music / ".deleting") == {}
    assert not (world.root(world.owner) / "Portishead").exists()
    assert world.root(world.owner).is_dir()
    assert path_of(world, keep).read_bytes() == keep_bytes
    # Catalog: tombstone after the old revision, no track/metadata/FTS row, no orphan parents.
    tomb_rev, tomb_owner = tombstone(world, uuid_id)
    assert tomb_owner == world.owner and tomb_rev > rev
    assert one(world, "SELECT count(*) FROM tracks WHERE uuid_id = ?", (uuid_id,))[0] == 0
    assert one(world, "SELECT count(*) FROM trackmetadata WHERE uuid_id = ?", (uuid_id,))[0] == 0
    assert _fts(world, "Mysterons") == 0 and _fts(world, "Lucky") == 1
    assert one(world, "SELECT count(*) FROM artists WHERE name = 'Portishead'")[0] == 0
    assert one(world, "SELECT count(*) FROM albums WHERE name = 'Dummy'")[0] == 0
    assert one(world, "SELECT count(*) FROM artists WHERE name = 'Radiohead'")[0] == 1
    # The outcome, and the journal gone after the cleanup.
    assert item(world, op, uuid_id) == {
        "status": "deleted", "error": None, "tombstone_revision": tomb_rev,
        "details": [], "lease": BOOT,
    }
    assert journal(world, uuid_id) is None
    assert one(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == (
        "completed",
    )
    # History, conversion audit and upload receipts are not cascaded away.
    assert _kept(world) == kept_before
    assert live(world, keep)


def test_a_folder_another_track_still_uses_is_kept(world):
    uuid_id = add_master(world, "Radiohead/OK Computer/02 Airbag.flac", title="Airbag")
    other = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world).run_one()

    assert path_of(world, other).is_file()
    assert sorted(os.listdir(world.root(world.owner) / "Radiohead" / "OK Computer")) == [
        "01 Lucky.flac"
    ]


def test_each_boundary_leaves_the_state_recovery_expects(world):
    uuid_id = add_master(world, "Portishead/Dummy/01 Mysterons.flac", title="Mysterons")
    master = path_of(world, uuid_id)
    st = os.lstat(master)
    rev = revision(world, uuid_id)
    op = accept_job(world, (uuid_id, rev))
    quarantine = world.music / ".deleting" / str(world.owner) / op / f"{uuid_id}.flac"
    seen = {}

    def seam(name):
        seen[name] = {
            "journal": journal(world, uuid_id),
            "at_original": os.path.lexists(master),
            "at_quarantine": os.path.lexists(quarantine),
            "item": item(world, op, uuid_id),
            "live": live(world, uuid_id),
            "tombstone": tombstone(world, uuid_id),
            "q_ino": os.lstat(quarantine).st_ino if os.path.lexists(quarantine) else None,
        }

    make_executor(world, seam=seam).run_one()

    assert list(seen) == SEAMS
    claim = seen["after_claim"]
    assert claim["journal"] is None and claim["at_original"] and claim["live"]
    assert claim["item"]["status"] == "running" and claim["item"]["lease"] == BOOT

    j = seen["after_journal"]["journal"]
    assert {k: j[k] for k in (
        "owner_id", "operation_uuid", "original_path", "quarantine_path", "base_revision",
        "src_dev", "src_ino", "src_size", "src_mtime_ns", "cover_art_id", "master_missing", "stage",
    )} == {
        "owner_id": world.owner, "operation_uuid": op, "original_path": str(master),
        "quarantine_path": str(quarantine), "base_revision": rev,
        "src_dev": st.st_dev, "src_ino": st.st_ino, "src_size": st.st_size,
        "src_mtime_ns": st.st_mtime_ns, "cover_art_id": None, "master_missing": 0,
        "stage": "intent",
    }
    assert seen["after_journal"]["at_original"] and not seen["after_journal"]["at_quarantine"]
    assert not seen["after_journal"]["live"]  # the journal row is the pending marker

    rename = seen["after_rename"]
    assert rename["journal"]["stage"] == "intent"
    assert not rename["at_original"] and rename["at_quarantine"]
    assert seen["after_moved"]["journal"]["stage"] == "moved"
    assert rename["q_ino"] == st.st_ino  # the same file, renamed (never a copy)

    commit = seen["after_commit"]
    assert commit["journal"]["stage"] == "committed"
    assert commit["tombstone"] is not None and commit["at_quarantine"]
    assert commit["item"]["status"] == "deleted"
    assert commit["item"]["details"] == ["storage_cleanup_pending"]
    assert commit["item"]["tombstone_revision"] == commit["tombstone"][0]

    assert seen["after_evict"]["at_quarantine"]
    unlink = seen["after_unlink"]
    assert not unlink["at_quarantine"] and unlink["journal"]["stage"] == "committed"

    assert journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["details"] == []


def test_two_users_targets_each_delete_only_their_own_master(world):
    mine = add_master(world, "Radiohead/OK Computer/01 Lucky.flac")
    theirs = add_master(world, "Radiohead/OK Computer/01 Lucky.flac", owner=world.sam)
    their_bytes = path_of(world, theirs).read_bytes()
    op_me = accept_job(world, (mine, revision(world, mine)))

    make_executor(world).run_one()

    assert item(world, op_me, mine)["status"] == "deleted"
    assert path_of(world, theirs).read_bytes() == their_bytes
    assert live(world, theirs) and tombstone(world, theirs) is None
    assert not (world.music / ".deleting" / str(world.sam)).exists()


def test_the_quarantine_is_per_owner_and_per_operation(world):
    theirs = add_master(world, "A/a.flac", owner=world.sam)
    op = accept_job(world, (theirs, revision(world, theirs)), owner=world.sam)
    seen = []
    make_executor(world, seam=lambda name: seen.append(journal(world, theirs))
                  if name == "after_journal" else None).run_one()

    assert Path(seen[0]["quarantine_path"]) == (
        world.music / ".deleting" / str(world.sam) / op / f"{theirs}.flac"
    )
    assert item(world, op, theirs, owner=world.sam)["status"] == "deleted"


def test_a_job_of_three_with_one_conflict_gives_a_truthful_partial_result(world):
    # Spec §4 "Deletion is atomic per track, not all-or-nothing across a batch";
    # review 8-D03.
    a = add_master(world, "X/a.flac", title="Alpha")
    b = add_master(world, "X/b.flac", title="Bravo")
    c = add_master(world, "X/c.flac", title="Charlie")
    b_bytes = path_of(world, b).read_bytes()
    op = accept_job(world, (a, revision(world, a)), (b, revision(world, b) - 1),
                    (c, revision(world, c)))

    executor = make_executor(world)
    while executor.run_one():
        pass

    assert [item(world, op, u)["status"] for u in (a, b, c)] == ["deleted", "conflict", "deleted"]
    assert item(world, op, b)["error"] == "conflict"
    assert tombstone(world, a) and tombstone(world, c) and tombstone(world, b) is None
    assert path_of(world, b).read_bytes() == b_bytes and live(world, b)
    assert sorted(os.listdir(world.root(world.owner) / "X")) == ["b.flac"]
    job = world.db.get_deletion_job(op, owner_id=world.owner)
    assert [(i["uuid_id"], i["status"]) for i in job["items"]] == [
        (a, "deleted"), (b, "conflict"), (c, "deleted"),
    ]
    assert one(world, "SELECT status FROM deletion_jobs WHERE operation_uuid = ?", (op,)) == (
        "completed",
    )
