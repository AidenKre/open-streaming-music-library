"""Review r1 m-R1-01: ``users delete`` removes the user's import folder in the
spelling it has on disk.

Signup adopts, and the dispatcher routes, every ``USER_IMPORT_DIR`` entry whose
``casefold()`` equals the user's ``library_folder``. The delete must remove
each such entry too, through the same guards (no symlink, inside the root).
On a case-sensitive filesystem an exact-spelling delete would leave an adopted
``Sam/`` behind for folder ``sam``, and the next ``sam`` would adopt it.

These tests run on case-insensitive APFS too: they assert on the names the
delete resolves (``Sam``), not only on what is left on disk.
"""

import shutil

import pytest

from app.services import user_delete
from app.services.user_delete import DeletePaths, DeleteRefused, run_user_delete
from tests.cli_fixtures import ADMIN, add_user, cli_settings, open_server_database


@pytest.fixture
def setup(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    settings = cli_settings(tmp_path)
    db = open_server_database(settings)
    add_user(db, ADMIN, master=True)
    sam = add_user(db, "sam")  # library_folder "sam"
    removed = []
    real_rmtree = shutil.rmtree

    def spy(path, *args, **kwargs):
        removed.append(str(path))
        return real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(user_delete.shutil, "rmtree", spy)
    return settings, db, sam, removed


def test_an_adopted_import_folder_is_removed_by_its_on_disk_name(setup):
    settings, db, sam, removed = setup
    adopted = settings.user_import_dir / "Sam"
    (adopted / "Albums").mkdir(parents=True)
    (adopted / "Albums" / "album.zip").write_bytes(b"zip")
    (adopted / ".imported").mkdir()
    (adopted / ".imported" / "old.zip").write_bytes(b"zip")

    run_user_delete(db, sam, DeletePaths.from_settings(settings))

    assert str(adopted) in removed
    assert [p.name for p in settings.user_import_dir.iterdir()] == []
    assert db.get_user(sam) is None


def test_every_case_variant_the_listing_shows_is_removed(setup, monkeypatch):
    """A case-sensitive filesystem can hold ``Sam/`` and ``SAM/`` side by side;
    the delete removes every entry the import-folder matcher returns."""
    settings, db, sam, removed = setup
    root = settings.user_import_dir
    variants = [root / "Sam", root / "SAM"]
    variants[0].mkdir(parents=True)
    (root / "alex").mkdir()
    monkeypatch.setattr(
        user_delete, "matching_import_dirs", lambda base, folder: list(variants)
    )
    # Record only: on a case-insensitive volume both names are one directory.
    monkeypatch.setattr(user_delete.shutil, "rmtree", lambda path, *a, **k: removed.append(str(path)))

    run_user_delete(db, sam, DeletePaths.from_settings(settings))

    assert {p for p in removed if p.startswith(str(root))} == {str(v) for v in variants}
    assert (root / "alex").is_dir()


def test_a_symlinked_case_variant_is_refused_before_anything_is_removed(setup, tmp_path):
    settings, db, sam, removed = setup
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (elsewhere / "keep.flac").write_bytes(b"x")
    settings.user_import_dir.mkdir(parents=True)
    (settings.user_import_dir / "Sam").symlink_to(elsewhere, target_is_directory=True)

    with pytest.raises(DeleteRefused):
        run_user_delete(db, sam, DeletePaths.from_settings(settings))

    assert removed == []
    assert (elsewhere / "keep.flac").exists()
    assert db.get_user(sam)["deleting_at"] is None
