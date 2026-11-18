"""Phase 8A.3c (spec §5 step 1 "A missing master can still remove the catalog
row/tombstone; report master_missing detail"; plan exit proof 3, O11; review
8-D06): a target whose master file is gone is a catalog-only deletion.
"""

import pytest

from tests.deletion_world import (
    accept_job,
    add_master,
    build_world,
    files_under,
    item,
    journal,
    make_executor,
    revision,
    sql,
    tombstone,
)


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


@pytest.mark.parametrize("folder_exists", [True, False])
def test_a_missing_master_is_a_catalog_only_deletion(world, folder_exists):
    uuid_id = add_master(world, "Gone/Album/01 Gone.flac", create_file=False)
    if folder_exists:
        (world.root(world.owner) / "Gone" / "Album").mkdir(parents=True)
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))
    seen = {}

    def seam(name):
        seen[name] = journal(world, uuid_id)

    make_executor(world, seam=seam).run_one()

    assert list(seen) == ["after_claim", "after_journal", "after_commit", "after_evict"]
    j = seen["after_journal"]
    assert (j["master_missing"], j["quarantine_path"], j["src_dev"], j["src_ino"],
            j["src_size"], j["stage"]) == (1, None, None, None, None, "intent")
    tomb = tombstone(world, uuid_id)
    assert tomb is not None
    assert item(world, op, uuid_id)["status"] == "deleted"
    assert item(world, op, uuid_id)["details"] == ["master_missing"]
    assert item(world, op, uuid_id)["tombstone_revision"] == tomb[0]
    assert journal(world, uuid_id) is None
    assert files_under(world.music) == {}
    assert world.cache.evicted == [uuid_id]


def test_a_missing_master_outside_the_root_is_still_rejected(world, tmp_path):
    uuid_id = add_master(world, "A/a.flac", create_file=False)
    sql(world, "UPDATE tracks SET file_path = ? WHERE uuid_id = ?",
        (str(tmp_path / "outside" / "gone.flac"), uuid_id))
    op = accept_job(world, (uuid_id, revision(world, uuid_id)))

    make_executor(world).run_one()

    assert (item(world, op, uuid_id)["status"], item(world, op, uuid_id)["error"]) == (
        "failed", "path_rejected",
    )
    assert tombstone(world, uuid_id) is None and journal(world, uuid_id) is None
