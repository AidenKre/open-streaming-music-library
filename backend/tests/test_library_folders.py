"""Phase M.0c (spec §4.5, review M-U09 folder half): ``choose_library_folder``.

1. Base: the username key through the portable sanitizer.
2. Suffixes ``-2``, ``-3``, … while the candidate is reserved, is already a
   ``library_folder`` in ``users``, or exists on disk under
   ``MUSIC_LIBRARY_DIR`` in any case (names compared by ``casefold()``).
3. A directory under ``USER_IMPORT_DIR`` whose casefold equals the chosen
   folder is adopted. Another entry equal to the base name is logged.
"""

import logging

import pytest

from app.library_folders import FolderChoice, choose_library_folder


@pytest.fixture
def dirs(tmp_path):
    music = tmp_path / "music"
    imports = tmp_path / "import-users"
    music.mkdir()
    imports.mkdir()
    return music, imports


def _choose(key, dirs, existing=()):
    music, imports = dirs
    return choose_library_folder(
        key,
        existing_folders=list(existing),
        music_library_dir=music,
        user_import_dir=imports,
    )


def test_a_free_name_is_the_username_key(dirs):
    assert _choose("sam", dirs) == FolderChoice(folder="sam", adopted_import_dir=None)


def test_the_base_goes_through_the_portable_sanitizer(dirs):
    # A Windows device name is a valid username; the sanitizer makes it portable.
    assert _choose("aux", dirs).folder == "aux_"


def test_a_stray_music_folder_in_another_case_forces_a_suffix(dirs):
    music, _ = dirs
    (music / "Sam").mkdir()

    assert _choose("sam", dirs).folder == "sam-2"


def test_suffixes_count_up_past_every_taken_candidate(dirs):
    music, _ = dirs
    (music / "sam").mkdir()
    (music / "SAM-2").mkdir()

    assert _choose("sam", dirs, existing=["Sam-3"]).folder == "sam-4"


def test_a_file_under_the_music_dir_also_collides(dirs):
    music, _ = dirs
    (music / "Sam").write_bytes(b"x")

    assert _choose("sam", dirs).folder == "sam-2"


def test_a_folder_already_in_users_collides_in_any_case(dirs):
    assert _choose("sam", dirs, existing=["Sam"]).folder == "sam-2"


@pytest.mark.parametrize("key", ["root", "system"])
def test_a_reserved_name_gets_a_suffix(dirs, key):
    assert _choose(key, dirs).folder == f"{key}-2"


def test_a_pre_staged_import_folder_is_adopted_not_suffixed(dirs):
    _, imports = dirs
    (imports / "Sam").mkdir()

    choice = _choose("sam", dirs)

    assert choice == FolderChoice(folder="sam", adopted_import_dir=imports / "Sam")


def test_the_import_folder_matching_a_suffixed_name_is_adopted(dirs):
    music, imports = dirs
    (music / "sam").mkdir()
    (imports / "Sam-2").mkdir()

    choice = _choose("sam", dirs)

    assert choice == FolderChoice(folder="sam-2", adopted_import_dir=imports / "Sam-2")


def test_an_import_entry_with_the_taken_base_name_is_logged_not_adopted(dirs, caplog):
    music, imports = dirs
    (music / "Sam").mkdir()
    (imports / "sam").mkdir()

    with caplog.at_level(logging.WARNING):
        choice = _choose("sam", dirs)

    assert choice == FolderChoice(folder="sam-2", adopted_import_dir=None)
    [record] = [r for r in caplog.records if r.levelno >= logging.WARNING]
    message = record.getMessage()
    assert "sam-2" in message
    assert str(imports / "sam") in message


def test_nothing_is_logged_when_the_base_name_is_free(dirs, caplog):
    _, imports = dirs
    (imports / "sam").mkdir()

    with caplog.at_level(logging.WARNING):
        _choose("sam", dirs)

    assert [r for r in caplog.records if r.levelno >= logging.WARNING] == []


def test_missing_directories_are_treated_as_empty(tmp_path):
    choice = choose_library_folder(
        "sam",
        existing_folders=[],
        music_library_dir=tmp_path / "absent-music",
        user_import_dir=tmp_path / "absent-imports",
    )

    assert choice == FolderChoice(folder="sam", adopted_import_dir=None)
    assert not (tmp_path / "absent-music").exists()
    assert not (tmp_path / "absent-imports").exists()


def test_choosing_creates_nothing_on_disk(dirs):
    music, imports = dirs

    _choose("sam", dirs)

    assert list(music.iterdir()) == []
    assert list(imports.iterdir()) == []
