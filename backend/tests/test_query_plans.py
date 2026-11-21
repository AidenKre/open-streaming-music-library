"""Pre-merge A2: the cost of a few hot statements does not grow with the library.

Production opens connections without ``ANALYZE`` data, so the planner's choice
here is the one a real server makes.

The expected plan lines are SQLite's own wording; they pass with SQLite 3.51.0
(Python 3.12.9's ``sqlite3.sqlite_version`` on the machine they were last
checked on). Another SQLite version may word the same plan differently (``SCAN TABLE``
instead of ``SCAN`` before 3.36, for example). When a test here fails on another
version, take the statement's ``EXPLAIN QUERY PLAN`` there, check that it still
reads through the same index with no full scan and no sort the test forbids, and
only then change the expected text.
"""

import re
import sqlite3
from unittest.mock import patch

from app.database import ANY_OWNER
from tests.owned_database import add_test_user
from tests.track_paths import PATH_COLUMNS, PATH_MARKS, path_values

_real_connect = sqlite3.connect


def _seed_revisions(db, owner_id, *, tracks=(), tombstones=()):
    """Insert catalog and tombstone rows with the given revisions straight into
    the tables, in one transaction (thousands of rows stay fast)."""
    conn = _real_connect(db.context.database_path)
    try:
        with conn:
            conn.executemany(
                f"INSERT INTO tracks (uuid_id, {PATH_COLUMNS}, revision, owner_id)"
                f" VALUES (?, {PATH_MARKS}, ?, ?)",
                [(f"t-{owner_id}-{r}", *path_values(f"/m/{owner_id}/{r}.flac"), r, owner_id)
                 for r in tracks],
            )
            conn.executemany(
                "INSERT INTO track_tombstones (uuid_id, deleted_at, revision, owner_id) "
                "VALUES (?, 0, ?, ?)",
                [(f"d-{owner_id}-{r}", r, owner_id) for r in tombstones],
            )
    finally:
        conn.close()


def _vm_steps_of_get_changes(db, owner_id, after_revision):
    """Run ``get_changes`` and count the SQLite VM steps it takes (in units of
    ten instructions), across every connection it opens."""
    steps = [0]

    def counting_connect(*args, **kwargs):
        conn = _real_connect(*args, **kwargs)

        def tick():
            steps[0] += 1
            return 0

        conn.set_progress_handler(tick, 10)
        return conn

    with patch("app.database.core.sqlite3.connect", side_effect=counting_connect):
        changes, latest, _ = db.get_changes(after_revision=after_revision, limit=100,
                                            owner_id=owner_id)
    return steps[0], changes, latest


def test_an_up_to_date_changes_page_costs_the_same_for_a_small_and_a_large_library(db):
    small = add_test_user(db, "small")
    large = add_test_user(db, "large")
    _seed_revisions(db, small, tracks=range(1, 11), tombstones=range(11, 13))
    _seed_revisions(db, large, tracks=range(100, 5100), tombstones=range(5100, 6100))

    small_steps, small_changes, small_latest = _vm_steps_of_get_changes(db, small, 12)
    large_steps, large_changes, large_latest = _vm_steps_of_get_changes(db, large, 6099)

    assert (small_changes, small_latest) == ([], 12)
    assert (large_changes, large_latest) == ([], 6099)
    # 6,000 rows against 12: a per-row read would cost thousands of steps more.
    assert large_steps <= small_steps + 50, (small_steps, large_steps)


def test_the_latest_revision_is_the_owners_highest_across_tracks_and_tombstones(db):
    newest_is_a_tombstone = add_test_user(db, "tomb")
    newest_is_a_track = add_test_user(db, "track")
    only_tombstones = add_test_user(db, "gone")
    only_tracks = add_test_user(db, "live")
    empty = add_test_user(db, "empty")
    _seed_revisions(db, newest_is_a_tombstone, tracks=(3, 7), tombstones=(9, 4))
    _seed_revisions(db, newest_is_a_track, tracks=(5, 20), tombstones=(6,))
    _seed_revisions(db, only_tombstones, tombstones=(11, 2))
    _seed_revisions(db, only_tracks, tracks=(1, 8))
    _seed_revisions(db, db.owner_id, tracks=(30,), tombstones=(31,))  # someone else's higher rows

    expected = {
        newest_is_a_tombstone: 9,
        newest_is_a_track: 20,
        only_tombstones: 11,
        only_tracks: 8,
        empty: 0,
        db.owner_id: 31,
    }
    conn = _real_connect(db.context.database_path)
    try:
        for owner, latest in expected.items():
            _, _, got = _vm_steps_of_get_changes(db, owner, 0)
            assert got == latest, owner
            # The shape before pre-merge A2-01 gives the same answer on the same data.
            (before,) = conn.execute(
                "SELECT COALESCE(MAX(revision), 0) FROM ("
                "SELECT revision FROM tracks WHERE owner_id = ? UNION ALL "
                "SELECT revision FROM track_tombstones WHERE owner_id = ?)",
                (owner, owner),
            ).fetchone()
            assert before == latest, owner
    finally:
        conn.close()


# ── A2-03: an archive's children are found through the whole parent index ──

def _traced(db):
    """Patch ``sqlite3.connect`` so every statement the database runs is recorded
    (with its values bound in, ready for EXPLAIN QUERY PLAN)."""
    statements: list[str] = []

    def tracing_connect(*args, **kwargs):
        conn = _real_connect(*args, **kwargs)
        conn.set_trace_callback(statements.append)
        return conn

    return statements, patch("app.database.core.sqlite3.connect", side_effect=tracing_connect)


def _seed_archive(db, owner_id, batch, parent, *, children=()):
    conn = _real_connect(db.context.database_path)
    try:
        with conn:
            conn.execute(
                "INSERT OR IGNORE INTO upload_batches (owner_id, batch_uuid, created_at, updated_at)"
                " VALUES (?, ?, 0, 0)", (owner_id, batch))
            conn.execute(
                "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, filename, selection_index,"
                " expected_bytes, expected_sha256, state, lease_boot_id, created_at, updated_at,"
                " progress_at) VALUES (?, ?, ?, 'a.zip', 0, 10, ?, 'validating', 'boot', 0, 0, 0)",
                (owner_id, parent, batch, "0" * 64))
            conn.executemany(
                "INSERT INTO upload_items (owner_id, item_uuid, batch_uuid, parent_item_uuid, filename,"
                " selection_index, member_order_key, state, created_at, updated_at, progress_at)"
                " VALUES (?, ?, ?, ?, ?, 0, ?, 'validating', 0, 0, 0)",
                [(owner_id, child, batch, parent, f"{child}.flac", f"{child}.flac") for child in children])
    finally:
        conn.close()


def test_every_lookup_of_an_archives_children_seeks_within_the_parents_batch(db):
    import uuid

    def u():
        return str(uuid.uuid4())

    owner, batch = db.owner_id, u()
    manifest, listed, cancelled, failed = u(), u(), u(), u()
    _seed_archive(db, owner, batch, manifest)
    _seed_archive(db, owner, batch, listed, children=(u(), u()))
    _seed_archive(db, owner, batch, cancelled, children=(u(),))
    _seed_archive(db, owner, batch, failed, children=(u(),))

    statements, tracing = _traced(db)
    with tracing:
        made = db.ensure_upload_manifest(owner_id=owner, item_uuid=manifest, boot_id="boot",
                                         review_version=0, members=[("a.flac", 1), ("b.flac", 2)],
                                         skipped=0, now=1)
        again = db.ensure_upload_manifest(owner_id=owner, item_uuid=manifest, boot_id="boot",
                                          review_version=0, members=[], skipped=0, now=1)
        children = db.list_upload_children(owner_id=owner, item_uuid=listed)
        changed, _, cancelled_children = db.cancel_upload_item(
            cancelled, owner_id=owner, from_states=("validating",), now=1)
        removed = db.fail_upload_validation(owner_id=owner, item_uuid=failed, boot_id="boot",
                                            review_version=0, error_code="upload_archive_invalid",
                                            error_message="x", error_retryable=False, now=1)

    # The answers themselves (unchanged by the index use).
    assert [c["member_order_key"] for c in made] == ["a.flac", "b.flac"] and again == made
    assert len(children) == 2 and {c["batch_uuid"] for c in children} == {batch}
    assert changed and len(cancelled_children) == 1
    assert len(removed) == 1 and removed[0]["batch_uuid"] == batch

    lookups = [s for s in statements if "parent_item_uuid = '" in s]
    shapes = {re.sub(r"'[^']*'", "?", s) for s in lookups}
    assert len(shapes) == 6, sorted(shapes)  # 2 manifest, 1 list, 1 cancel, 2 fail
    conn = _real_connect(db.context.database_path)
    try:
        for statement in lookups:
            plan = [row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + statement)]
            # Every lookup, the cancel walk included, seeks the parent index: a
            # batch of a bulk upload is never walked to find one archive's children.
            expected = "idx_upload_items_parent (owner_id=? AND batch_uuid=? AND parent_item_uuid=?)"
            assert any(expected in step for step in plan if "upload_items" in step), (statement, plan)
    finally:
        conn.close()


# ── The deletion worker's idle poll reads only the pending items ──

def _seed_deletion_job(db, owner_id, operation, created_at, items):
    """``items``: (uuid_id, position, status) rows of one job."""
    conn = _real_connect(db.context.database_path)
    try:
        with conn:
            conn.execute(
                "INSERT INTO operation_receipts (owner_id, operation_uuid, kind, request_hash,"
                " created_at, result_ref) VALUES (?, ?, 'track_deletion', ?, ?, ?)",
                (owner_id, operation, "a" * 64, created_at, operation))
            conn.execute(
                "INSERT INTO deletion_jobs (owner_id, operation_uuid, created_at, status)"
                " VALUES (?, ?, ?, 'accepted')", (owner_id, operation, created_at))
            conn.executemany(
                "INSERT INTO deletion_job_items (owner_id, operation_uuid, uuid_id, position,"
                " base_revision, status, tombstone_revision) VALUES (?, ?, ?, ?, 1, ?, ?)",
                [(owner_id, operation, uuid_id, position, status,
                  None if status == "pending" else 1) for uuid_id, position, status in items])
    finally:
        conn.close()


def test_claiming_the_next_deletion_item_reads_only_pending_items(db):
    owner = db.owner_id
    _seed_deletion_job(db, owner, "op-old", 1,
                       [(f"done-{n}", n, "deleted") for n in range(300)])
    _seed_deletion_job(db, owner, "op-new", 2,
                       [("second", 1, "pending"), ("first", 0, "pending"), ("gone", 2, "deleted")])

    statements, tracing = _traced(db)
    with tracing:
        claimed = db.claim_next_deletion_item(boot_id="boot")

    assert (claimed["operation_uuid"], claimed["uuid_id"]) == ("op-new", "first")
    [poll] = [s for s in statements if "FROM deletion_job_items i" in s]
    conn = _real_connect(db.context.database_path)
    try:
        plan = [row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + poll)]
    finally:
        conn.close()
    assert "SCAN i USING INDEX idx_deletion_job_items_pending" in plan, plan


# ── PM-BE-PATHKEY: "is this path taken" is one probe of the unique index ──

def _seed_album(db, owner_id, folder, count):
    """``count`` tracks of one owner directly in ``folder``, straight into the table."""
    conn = _real_connect(db.context.database_path)
    try:
        with conn:
            conn.executemany(
                f"INSERT INTO tracks (uuid_id, {PATH_COLUMNS}, owner_id) VALUES (?, {PATH_MARKS}, ?)",
                [(f"{folder}/{n}", *path_values(f"{folder}/{n:05d} Song.flac"), owner_id)
                 for n in range(count)],
            )
    finally:
        conn.close()


def _vm_steps(db, call):
    """Run ``call`` and count the SQLite VM steps it takes (in units of ten
    instructions), across every connection it opens."""
    steps = [0]

    def counting_connect(*args, **kwargs):
        conn = _real_connect(*args, **kwargs)

        def tick():
            steps[0] += 1
            return 0

        conn.set_progress_handler(tick, 10)
        return conn

    with patch("app.database.core.sqlite3.connect", side_effect=counting_connect):
        answer = call()
    return steps[0], answer


def _path_questions(db, sam, alex):
    """Every shape of the question the product asks, with its answer."""
    taken, free = "/m/sam/Art/Album/00003 Song.flac", "/m/sam/Art/Album/New Upload.flac"
    return [
        (lambda: db.track_path_in_use(free, owner_id=ANY_OWNER), False),
        (lambda: db.track_path_in_use(taken, owner_id=ANY_OWNER), True),
        (lambda: db.track_path_in_use(taken.upper(), owner_id=ANY_OWNER), True),
        (lambda: db.track_path_in_use(taken, owner_id=sam), True),
        (lambda: db.track_path_in_use(taken, owner_id=alex), False),
        (lambda: db.track_path_in_use(taken, owner_id=ANY_OWNER,
                                      exclude_uuid="/m/sam/Art/Album/3"), False),
        (lambda: db.track_path_in_use(taken, owner_id=sam, exclude_uuid="/m/sam/Art/Album/4"), True),
    ]


def test_asking_whether_a_path_is_taken_costs_the_same_in_a_small_and_a_large_library(db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    _seed_album(db, sam, "/m/sam/Art/Album", 12)
    small = [_vm_steps(db, ask) for ask, _ in _path_questions(db, sam, alex)]
    _seed_album(db, sam, "/m/sam/Art/Other", 4000)
    _seed_album(db, alex, "/m/alex/Art/Album", 2000)
    questions = _path_questions(db, sam, alex)
    large = [_vm_steps(db, ask) for ask, _ in questions]

    assert [answer for _, answer in small] == [expected for _, expected in questions]
    assert [answer for _, answer in large] == [expected for _, expected in questions]
    # 6,012 rows against 12: reading a row per track would cost thousands of steps more.
    for (few, _), (many, _) in zip(small, large):
        assert many <= few + 5, (small, large)


def test_asking_whether_a_path_is_taken_probes_the_unique_index(db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    _seed_album(db, sam, "/m/sam/Art/Album", 12)
    questions = _path_questions(db, sam, alex)

    statements, tracing = _traced(db)
    with tracing:
        answers = [ask() for ask, _ in questions]

    assert answers == [expected for _, expected in questions]
    lookups = [s for s in statements if "FROM tracks" in s]
    assert len(lookups) == len(questions), statements
    conn = _real_connect(db.context.database_path)
    try:
        for statement in lookups:
            plan = [row[3].replace("COVERING INDEX", "INDEX")
                    for row in conn.execute("EXPLAIN QUERY PLAN " + statement)]
            # With an owner, with a track left out: always the one probe, never
            # a walk of the owner's tracks or of the table.
            assert plan == [
                "SEARCH tracks USING INDEX idx_tracks_file_path_fold (file_path_fold=?)"
            ], (statement, plan)
    finally:
        conn.close()


# ── PM-BE-PATHKEY: the tracks directly in a folder are one probe of the folder index ──

def _folder_questions(db, sam, alex):
    album, top = "/m/sam/Art/Album", "/m/sam"
    return [
        (lambda: len(db.track_identities_in_folder(album, owner_id=ANY_OWNER)), 12),
        (lambda: len(db.track_identities_in_folder(album.upper(), owner_id=ANY_OWNER)), 12),
        (lambda: len(db.track_identities_in_folder(album, owner_id=sam)), 12),
        (lambda: len(db.track_identities_in_folder(album, owner_id=alex)), 0),
        (lambda: len(db.track_identities_in_folder("/m/sam/Art/New", owner_id=ANY_OWNER)), 0),
        # A user's top folder (files with no artist tag are placed there): no
        # track lies directly in it, every track of the user lies below it.
        (lambda: len(db.track_identities_in_folder(top, owner_id=ANY_OWNER)), 0),
        (lambda: len(db.track_identities_in_folder(top, owner_id=sam)), 0),
    ]


def test_reading_a_folders_tracks_costs_the_same_in_a_small_and_a_large_library(db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    _seed_album(db, sam, "/m/sam/Art/Album", 12)
    small = [_vm_steps(db, ask) for ask, _ in _folder_questions(db, sam, alex)]
    _seed_album(db, sam, "/m/sam/Art/Other", 4000)
    _seed_album(db, alex, "/m/alex/Art/Album", 2000)
    questions = _folder_questions(db, sam, alex)
    large = [_vm_steps(db, ask) for ask, _ in questions]

    assert [answer for _, answer in small] == [expected for _, expected in questions]
    assert [answer for _, answer in large] == [expected for _, expected in questions]
    # 6,012 rows against 12: reading a row per track would cost thousands of steps more.
    for (few, _), (many, _) in zip(small, large):
        assert many <= few + 5, (small, large)


def test_reading_a_folders_tracks_probes_the_folder_index(db):
    sam, alex = add_test_user(db, "sam"), add_test_user(db, "alex")
    _seed_album(db, sam, "/m/sam/Art/Album", 12)
    questions = _folder_questions(db, sam, alex)

    statements, tracing = _traced(db)
    with tracing:
        answers = [ask() for ask, _ in questions]

    assert answers == [expected for _, expected in questions]
    lookups = [s for s in statements if "FROM tracks" in s]
    assert len(lookups) == len(questions), statements
    conn = _real_connect(db.context.database_path)
    try:
        for statement in lookups:
            plan = [row[3] for row in conn.execute("EXPLAIN QUERY PLAN " + statement)]
            # The folder's own rows through its index, with an owner too; each
            # row's identity through that table's key.
            assert plan[0] == (
                "SEARCH t USING INDEX idx_tracks_file_folder_fold (file_folder_fold=?)"
            ), (statement, plan)
            assert len(plan) == 2 and plan[1].startswith("SEARCH i USING INDEX"), (statement, plan)
    finally:
        conn.close()
