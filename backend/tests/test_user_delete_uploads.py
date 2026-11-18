"""7A.3c S10 (SC-28 hard delete; plan row "users delete removes the deleted
user's .uploads stages (DeletePaths) before the rows are purged"): the staged
upload tree of a user is ``MUSIC_LIBRARY_DIR/.uploads/<user id>/``. ``users
delete`` removes all of it in its file step, before the rows go, follows no
symlink and never touches another user's stage or ``.uploads`` itself."""

import pytest

from app.services import user_delete
from app.services.user_delete import DeletePaths, DeleteRefused, run_user_delete
from tests.cli_fixtures import cli_settings, sql
from tests.crash import Crash
from tests.user_delete_world import build_world


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return build_world(cli_settings(tmp_path))


@pytest.fixture
def paths(world):
    return DeletePaths.from_settings(world.settings)


def stage(world, uid, name) -> dict:
    root = world.settings.music_library_dir / ".uploads" / str(uid)
    item = root / "batch" / "item"
    item.mkdir(parents=True, exist_ok=True)
    files = {"source": item / "source", "part": item / "x.part", "work": item / "work-op.flac",
             "child": root / "batch" / "child" / "source"}
    files["child"].parent.mkdir(parents=True, exist_ok=True)
    for path in files.values():
        path.write_bytes(name.encode())
    return {"root": root, **files}


def test_the_delete_paths_name_the_uploads_tree(world, paths):
    assert paths.uploads_dir == world.settings.music_library_dir / ".uploads"


def test_users_delete_removes_the_users_whole_stage_and_only_it(world, paths):
    sam = stage(world, world.sam, "sam")
    alex = stage(world, world.alex, "alex")

    run_user_delete(world.db, world.sam, paths)

    assert not sam["root"].exists()
    for key in ("source", "part", "work", "child"):
        assert alex[key].read_bytes() == b"alex"
    assert (world.settings.music_library_dir / ".uploads").is_dir()


def test_the_stage_goes_in_the_file_step_before_the_rows(world, paths, monkeypatch):
    sam = stage(world, world.sam, "sam")
    original = list(user_delete.STEPS)

    def crash_after_files(*args, **kwargs):
        original[1](*args, **kwargs)
        raise Crash()

    monkeypatch.setattr(user_delete, "STEPS", [original[0], crash_after_files, *original[2:]])
    with pytest.raises(Crash):
        run_user_delete(world.db, world.sam, paths)

    assert not sam["root"].exists()
    assert sql(world.db, "SELECT count(*) AS n FROM upload_items WHERE owner_id = ?",
               (world.sam,))[0][0] > 0  # rows still there: step 3 not run yet

    monkeypatch.setattr(user_delete, "STEPS", original)
    run_user_delete(world.db, world.sam, paths)  # the rerun finishes

    assert sql(world.db, "SELECT count(*) AS n FROM upload_items WHERE owner_id = ?",
               (world.sam,))[0][0] == 0


def test_a_user_without_a_stage_is_deleted(world, paths):
    run_user_delete(world.db, world.sam, paths)

    assert world.db.get_user(world.sam) is None


def test_a_symlinked_stage_is_refused_and_followed_nowhere(world, paths):
    alex = stage(world, world.alex, "alex")
    sam_root = world.settings.music_library_dir / ".uploads" / str(world.sam)
    sam_root.symlink_to(alex["root"], target_is_directory=True)

    with pytest.raises(DeleteRefused):
        run_user_delete(world.db, world.sam, paths)

    assert alex["source"].read_bytes() == b"alex"
    assert world.db.get_user(world.sam) is not None
