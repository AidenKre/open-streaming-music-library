"""Phase M.2b (spec §6.4 ``delete``, review M-U17): the offline hard delete.

Steps (each idempotent; a rerun starts again from step 1):
1. mark (``deleting_at``, sessions, art capture — decision O5 / DEV-M-05);
2. remove the user's files; 3. delete the rows (FTS by the shared derivations,
registry order, captured unreferenced art); 4. sweep orphaned art files;
5. delete the ``users`` row and the capture.

All data lives under ``tmp_path``.
"""

import shutil

import pytest

from app.database.table_registry import owner_predicate
from app.services import user_delete
from app.services.user_delete import (
    DeletePaths,
    DeleteRefused,
    check_delete_guards,
    run_user_delete,
)
from tests.cli_fixtures import add_user, cli_settings, sql
from tests.user_delete_world import (
    FTS_TABLES,
    SAM_TOKENS,
    SERVER_WIDE_TABLES,
    USER_ROWS,
    build_world,
    dump,
    exists,
    fts_snapshot,
    owned_ids,
    table_names,
    user_rows,
)


class Crash(BaseException):
    """A simulated kill: not an Exception, so nothing may swallow it."""


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return build_world(cli_settings(tmp_path))


@pytest.fixture
def paths(world):
    return DeletePaths.from_settings(world.settings)


def _crash_after(monkeypatch, step_number):
    original = list(user_delete.STEPS)

    def crashing(*args, **kwargs):
        original[step_number - 1](*args, **kwargs)
        raise Crash(f"after step {step_number}")

    patched = list(original)
    patched[step_number - 1] = crashing
    monkeypatch.setattr(user_delete, "STEPS", patched)
    return original


def _sam(world):
    return world.db.get_user(world.sam)


def _sam_files(world):
    return [p for k, p in world.files.items() if k.startswith("sam_")]


def _alex_files(world):
    return [p for k, p in world.files.items() if k.startswith("alex_")]


# --- the world itself is what the tests assume ------------------------------------------


def test_the_world_covers_every_table(world):
    tables = table_names(world.db)
    assert tables == set(USER_ROWS) | SERVER_WIDE_TABLES | FTS_TABLES
    sam, alex = user_rows(world.db, world.sam), user_rows(world.db, world.alex)
    for table in USER_ROWS:
        if table == "user_delete_art_capture":
            continue  # written by step 1
        assert sam[table], f"no row of Sam's in {table}"
        assert alex[table], f"no row of Alex's in {table}"


def test_each_registry_owner_predicate_selects_exactly_that_users_rows(world):
    """Plan D15: the purge deletes each table by its registry predicate. A
    uuid-keyed child whose predicate matched on ``tracks.id`` would select
    nothing (FK cascades would hide that in the purge itself), so check the
    predicate directly against the independent ``USER_ROWS``."""
    for uid in (world.sam, world.alex):
        expected = user_rows(world.db, uid)
        for table in set(USER_ROWS) - {"users"}:
            selected = set(sql(world.db, f'SELECT * FROM "{table}" WHERE {owner_predicate(table)}',
                               (uid,)))
            assert selected == expected[table], table


def test_there_are_exactly_five_steps():
    assert len(user_delete.STEPS) == 5


# --- guards (before anything changes) -----------------------------------------------


def test_guards_pass_for_an_ordinary_user(world, paths):
    check_delete_guards(_sam(world), paths)


def test_guards_pass_when_the_user_has_no_folders_yet(world, paths):
    shutil.rmtree(world.files["sam_music"])
    shutil.rmtree(world.settings.user_import_dir / "Sam")
    check_delete_guards(_sam(world), paths)


@pytest.mark.parametrize("folder", ["", ".", "..", "a/b", "..\\x", ".staging", "/tmp"])
def test_guards_refuse_a_folder_that_is_not_one_plain_component(world, paths, folder):
    sql(world.db, "UPDATE users SET library_folder = ? WHERE id = ?", (folder, world.sam))

    with pytest.raises(DeleteRefused):
        check_delete_guards(_sam(world), paths)


def _replace_with_symlink(path, target):
    shutil.rmtree(path)
    path.symlink_to(target, target_is_directory=True)


@pytest.mark.parametrize("root", ["music", "import", "workspace"])
def test_guards_refuse_a_symlinked_user_root(world, paths, root):
    target = {
        "music": world.files["sam_music"],
        "import": world.settings.user_import_dir / "Sam",
        "workspace": world.settings.app_data_dir / "workspace" / f"u{world.sam}",
    }[root]
    _replace_with_symlink(target, world.files["alex_music"])
    before = dump(world.db)

    with pytest.raises(DeleteRefused):
        check_delete_guards(_sam(world), paths)
    with pytest.raises(DeleteRefused):
        run_user_delete(world.db, world.sam, paths)

    assert dump(world.db) == before  # not even marked
    assert all(exists(p) for p in _alex_files(world))
    assert world.files["alex_master"].exists()


# --- step 1: mark ---------------------------------------------------------------------


def test_step_1_marks_revokes_and_captures_the_users_art(world, paths, monkeypatch):
    _crash_after(monkeypatch, 1)
    before = dump(world.db)

    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)

    assert _sam(world)["deleting_at"] is not None
    assert sql(world.db, "SELECT count(*) FROM auth_sessions WHERE user_id = ?", (world.sam,)) == [(0,)]
    assert sql(world.db, "SELECT count(*) FROM auth_sessions WHERE user_id = ?", (world.alex,)) == [(1,)]
    captured = {r[0] for r in sql(world.db, "SELECT cover_art_id FROM user_delete_art_capture "
                                            "WHERE user_id = ?", (world.sam,))}
    assert captured == {world.art["a"][0], world.art["b"][0]}
    after = dump(world.db)
    for table in set(before) - {"users", "auth_sessions", "user_delete_art_capture"}:
        assert after[table] == before[table], table
    assert all(exists(p) for p in _sam_files(world))


def test_a_rerun_keeps_the_first_deleting_at(world, paths, monkeypatch):
    sql(world.db, "UPDATE users SET deleting_at = 1234 WHERE id = ?", (world.sam,))
    _crash_after(monkeypatch, 1)

    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)

    assert _sam(world)["deleting_at"] == 1234


# --- step 2: files ----------------------------------------------------------------------


def test_step_2_removes_only_the_users_files_and_follows_no_symlink(world, paths, monkeypatch):
    _crash_after(monkeypatch, 2)
    rows = dump(world.db)

    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)

    assert not exists(world.files["sam_music"])
    assert not exists(world.settings.user_import_dir / "Sam")
    assert not exists(world.settings.app_data_dir / "workspace" / f"u{world.sam}")
    for path in _sam_files(world):
        assert not exists(path), path
    for path in _alex_files(world):
        assert exists(path), path
    assert world.files["alex_master"].read_bytes().startswith(b"not really flac")
    assert sorted(p.name for p in world.files["alex_music"].rglob("*.flac")) == [
        "01 Lucky.flac", "08 Idioteque.flac"
    ]
    assert world.settings.music_library_dir.is_dir()
    assert (world.settings.music_library_dir / ".staging").is_dir()
    assert world.files["orphan_art"].exists()  # step 4's job
    after = dump(world.db)
    for table in set(rows) - {"users", "auth_sessions", "user_delete_art_capture"}:
        assert after[table] == rows[table], table  # step 2 touches no row


# --- step 3: rows ---------------------------------------------------------------------


def test_step_3_deletes_every_row_of_the_user_and_nothing_else(world, paths, monkeypatch):
    before = dump(world.db)
    sam_before = user_rows(world.db, world.sam)
    _crash_after(monkeypatch, 3)

    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)

    after = dump(world.db)
    sam_after = user_rows(world.db, world.sam)
    for table in USER_ROWS:
        if table in ("users", "user_delete_art_capture"):
            assert sam_after[table], f"{table} must survive until step 5"
            continue
        assert sam_after[table] == set(), table
        assert after[table] == before[table] - sam_before[table], table
    art_b = world.art["b"][0]
    assert {r[0] for r in after["cover_arts"]} == {
        world.art["a"][0], world.art["c"][0], world.art["d"][0]
    }
    assert art_b not in {r[0] for r in after["cover_arts"]}
    assert after["revision_counter"] == before["revision_counter"]
    assert after["app_settings"] == before["app_settings"]
    assert world.art["b"][1].exists()  # files go in step 4


def test_step_3_leaves_no_fts_ghost_of_the_user(world, paths, monkeypatch):
    sam_ids = owned_ids(world.db, world.sam)
    alex_ids = owned_ids(world.db, world.alex)
    before = fts_snapshot(world.db)
    # The fixture really put Sam's tokens in every FTS table.
    zebra = sql(world.db, "SELECT id FROM tracks WHERE uuid_id = ?", (world.sam_uuids[1],))[0][0]
    assert before[("fts_tracks", "renamedtitle")] == {zebra}
    assert before[("fts_tracks", "zebrafish")] == set()  # edited away
    # Zebrafish has album artist " Samvarious " (m-R1-04): it names the
    # artist row and the track's FTS artist.
    assert before[("fts_artists", "samvarious")] and before[("fts_albums", "samonly")]
    assert before[("fts_tracks", "samvarious")] == {zebra}
    assert before[("fts_tracks", "radiohead")] & sam_ids["fts_tracks"]
    assert before[("fts_tracks", "radiohead")] & alex_ids["fts_tracks"]
    _crash_after(monkeypatch, 3)

    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)

    after = fts_snapshot(world.db)
    for (table, token), rowids in after.items():
        assert not rowids & sam_ids[table], (table, token, rowids)
        assert rowids == before[(table, token)] - sam_ids[table], (table, token)
    for token in ("zebrafish", "renamedtitle", "uniquesam", "samonly", "samvarious"):
        for table in FTS_TABLES:
            assert after[(table, token)] == set(), (table, token)
    assert after[("fts_tracks", "lucky")] == before[("fts_tracks", "lucky")] & alex_ids["fts_tracks"]
    assert after[("fts_tracks", "lucky")]


# --- steps 4 and 5 ----------------------------------------------------------------------


def _assert_fully_deleted(world, before, sam_before):
    after = dump(world.db)
    for table in USER_ROWS:
        assert after[table] == before[table] - sam_before[table], table
    assert {r[0] for r in after["cover_arts"]} == {
        world.art["a"][0], world.art["c"][0], world.art["d"][0]
    }
    assert world.db.get_user(world.sam) is None
    assert world.db.get_user(world.alex) is not None
    assert not world.art["b"][1].exists()
    assert not world.files["orphan_art"].exists()
    for name in ("a", "c", "d"):
        assert world.art[name][1].exists(), name
    for path in _sam_files(world):
        assert not exists(path), path
    for path in _alex_files(world):
        assert exists(path), path
    assert world.files["alex_master"].exists()
    for (table, token), rowids in fts_snapshot(world.db).items():
        assert not rowids & world.sam_fts_ids[table], (table, token)


@pytest.fixture
def baseline(world):
    world.sam_fts_ids = owned_ids(world.db, world.sam)
    return dump(world.db), user_rows(world.db, world.sam)


def test_a_full_run_deletes_the_user_last_and_only_their_unreferenced_art(
    world, paths, baseline, monkeypatch
):
    seen = []
    original = list(user_delete.STEPS)

    def spy(index):
        def step(*args, **kwargs):
            seen.append((index, world.db.get_user(world.sam) is not None))
            return original[index](*args, **kwargs)
        return step

    monkeypatch.setattr(user_delete, "STEPS", [spy(i) for i in range(5)])

    run_user_delete(world.db, world.sam, paths)

    assert seen == [(0, True), (1, True), (2, True), (3, True), (4, True)]
    _assert_fully_deleted(world, *baseline)


def test_step_4_removes_art_files_no_row_references(world, paths, monkeypatch):
    _crash_after(monkeypatch, 4)

    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)

    assert not world.art["b"][1].exists()
    assert not world.files["orphan_art"].exists()
    for name in ("a", "c", "d"):
        assert world.art[name][1].exists(), name
    assert world.db.get_user(world.sam) is not None


# --- a crash after each step, then a rerun, converges ------------------------------------


@pytest.mark.parametrize("step", [1, 2, 3, 4, 5])
def test_a_crash_after_any_step_then_a_rerun_converges(world, paths, baseline, monkeypatch, step):
    original = _crash_after(monkeypatch, step)

    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)
    monkeypatch.setattr(user_delete, "STEPS", original)
    run_user_delete(world.db, world.sam, paths)
    run_user_delete(world.db, world.sam, paths)  # and again: still a no-op

    _assert_fully_deleted(world, *baseline)


def test_a_failure_inside_step_3_rolls_the_whole_transaction_back(world, paths, monkeypatch):
    before = dump(world.db)
    real_order = user_delete.delete_order

    def failing_order():
        order = list(real_order())
        return order + ["__no_such_table__"]

    _crash_after(monkeypatch, 2)
    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)
    marked = dump(world.db)
    monkeypatch.setattr(user_delete, "delete_order", failing_order)

    with pytest.raises(Exception):
        user_delete.STEPS[2](world.db, _sam(world), paths)  # step 3, unpatched

    assert dump(world.db) == marked
    assert before["tracks"] == marked["tracks"]


# --- review round (M.2b-review.md) ------------------------------------------------------


def test_the_art_sweep_matches_by_name_not_by_stored_directory(world, paths, baseline):
    """#1: a data dir reached by another spelling (APFS case, a moved or restored
    backup) must not make every referenced art file look orphaned."""
    for name in ("a", "c", "d"):
        art_id, path = world.art[name]
        sql(world.db, "UPDATE cover_arts SET file_path = ? WHERE id = ?",
            (f"/somewhere/else/cover_art/{path.name}", art_id))

    run_user_delete(world.db, world.sam, paths)

    for name in ("a", "c", "d"):
        assert world.art[name][1].exists(), name
    assert not world.art["b"][1].exists()
    assert not world.files["orphan_art"].exists()


def test_the_art_sweep_removes_only_art_named_files(world, paths):
    """#2: anything in cover_art/ that is not ``<sha256>.<ext>`` is not ours."""
    run_user_delete(world.db, world.sam, paths)

    assert world.files["not_art_photo"].exists()
    assert world.files["not_art_notes"].exists()


def test_a_symlinked_cover_art_dir_is_refused(world, paths, tmp_path):
    pictures = tmp_path / "pictures"
    pictures.mkdir()
    (pictures / ("f" * 64 + ".jpg")).write_bytes(b"a picture")
    cover = world.settings.app_data_dir / "cover_art"
    cover.rename(tmp_path / "real_cover_art")
    cover.symlink_to(pictures, target_is_directory=True)
    before = dump(world.db)

    with pytest.raises(DeleteRefused):
        run_user_delete(world.db, world.sam, paths)

    assert dump(world.db) == before
    assert (pictures / ("f" * 64 + ".jpg")).exists()


def _overlapping_world(tmp_path, monkeypatch, **overrides):
    monkeypatch.chdir(tmp_path)
    world = build_world(cli_settings(tmp_path, **overrides))
    return world, DeletePaths.from_settings(world.settings)


@pytest.mark.parametrize("folder", ["music", "data", "import"])
def test_a_user_root_that_is_a_configured_directory_is_refused(tmp_path, monkeypatch, folder):
    """#3: USER_IMPORT_DIR misconfigured as the parent of the other dirs: a user
    whose folder is named like one of them must not take it down."""
    world, paths = _overlapping_world(tmp_path, monkeypatch, user_import_dir=tmp_path)
    victim = add_user(world.db, folder)
    before = dump(world.db)

    with pytest.raises(DeleteRefused):
        run_user_delete(world.db, victim, paths)

    assert dump(world.db) == before
    assert world.files["alex_master"].exists()
    assert world.settings.app_data_dir.is_dir()
    assert world.settings.music_library_dir.is_dir()


def test_a_user_root_containing_another_users_root_is_refused(tmp_path, monkeypatch):
    """#3: with USER_IMPORT_DIR = APP_DATA_DIR (misconfigured), user "workspace"
    has an import root that holds every other user's workspace."""
    world, paths = _overlapping_world(tmp_path, monkeypatch, user_import_dir=tmp_path / "data")
    victim = add_user(world.db, "workspace")
    before = dump(world.db)

    with pytest.raises(DeleteRefused):
        run_user_delete(world.db, victim, paths)

    assert dump(world.db) == before
    assert world.files["alex_workspace"].exists()


# --- sign-off DEV-7-14 point 1: import-folder archive unpacks ---------------------------


def test_a_users_import_unpack_reservations_and_unpack_folders_go_with_the_user(world, paths):
    """The unpack folders live in the user's ``workspace/u<id>/`` and the
    reservations are owned rows of ``storage_reservations`` of purpose
    ``import_unpack``: both go with the user, the other user's stay."""
    from app.services.storage_ledger import IMPORT_UNPACK

    workspace = world.settings.app_data_dir / "workspace"
    for uid in (world.sam, world.alex):
        sql(world.db, "INSERT INTO storage_reservations (owner_id, purpose, subject_ref, bytes, "
                      "lease_boot_id, created_at) VALUES (?, ?, NULL, 500, 'boot', 0)", (uid, IMPORT_UNPACK))
        folder = workspace / f"u{uid}" / ("unpack-" + "a" * 32) / "Album"
        folder.mkdir(parents=True)
        (folder / "a.mp3").write_bytes(b"a")

    run_user_delete(world.db, world.sam, paths)

    rows = sql(world.db, "SELECT owner_id FROM storage_reservations WHERE purpose = ?", (IMPORT_UNPACK,))
    assert [tuple(r) for r in rows] == [(world.alex,)]
    assert not exists(workspace / f"u{world.sam}")
    assert (workspace / f"u{world.alex}" / ("unpack-" + "a" * 32) / "Album" / "a.mp3").exists()
