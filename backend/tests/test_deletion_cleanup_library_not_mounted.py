"""A committed deletion clean-up with the library not mounted (Phase 8A.3d
review r2 #1, a regression of the r1 #3 fix): a committed clean-up never reads "the library is not there" as "the quarantine file is
gone". With the library volume unmounted (an empty mount point), the journal
and ``storage_cleanup_pending`` stay; once the volume is back the next pass
finishes the clean-up."""

import os

import pytest

from tests.deletion_recovery_helpers import crashed_at, janitor
from tests.deletion_world import build_world, item, journal


@pytest.fixture
def world(tmp_path):
    return build_world(tmp_path)


def test_a_committed_cleanup_with_the_library_not_mounted_keeps_its_journal(world):
    uuid_id, rev, op = crashed_at(world, "after_commit")
    q = journal(world, uuid_id)["quarantine_path"]
    kept = journal(world, uuid_id)
    mounted = world.tmp / "volume"
    os.rename(world.music, mounted)
    world.music.mkdir()  # the empty mount point

    janitor(world).retry_cleanups()

    assert journal(world, uuid_id) == kept
    assert item(world, op, uuid_id)["details"] == ["storage_cleanup_pending"]

    world.music.rmdir()
    os.rename(mounted, world.music)
    janitor(world).retry_cleanups()

    assert not os.path.lexists(q) and journal(world, uuid_id) is None
    assert item(world, op, uuid_id)["details"] == []
