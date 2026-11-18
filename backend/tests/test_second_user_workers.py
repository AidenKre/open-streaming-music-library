"""Phase M.2a (M-U15, spec §6.2): ``.staging`` stays flat, so
``reconcile_conversion_jobs`` (top level only) still finds a second user's
staged files: a temp owned by sam's journal row is kept, sam's orphaned
conversion temps are swept, and no per-owner subdirectory is ever needed.

Rows carrying the owner, recovery against the owner's root, pruning no higher
than that root and workers reading the owner from the row are covered by M.0c
(test_owner_isolation, test_track_editor, test_conversion); this file adds the
staging cases for a non-admin owner.
"""

import pytest

from app.database import DatabaseContext
from app.library import Library
from app.services.conversion import reconcile_conversion_jobs
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL


@pytest.fixture
def db(tmp_path):
    database = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert database.initialize()
    return database


def test_a_second_users_journal_owned_temp_is_kept_and_their_orphans_swept(db, tmp_path):
    sam = Library(db, add_test_user(db, "sam"))
    staging = tmp_path / ".staging"
    staging.mkdir()
    owned = staging / "s1.tagged.m4a"
    orphan_convert = staging / "s2.convert.m4a"
    orphan_tagged = staging / "s2.tagged.m4a"
    for path in (owned, orphan_convert, orphan_tagged):
        path.write_bytes(b"x")
    sam.insert_journal_entry(
        "convert", "s1", old_path=str(tmp_path / "sam" / "s1.mp3"), temp_path=str(owned)
    )

    reconcile_conversion_jobs(db, staging)

    assert owned.exists()
    assert not orphan_convert.exists()
    assert not orphan_tagged.exists()

