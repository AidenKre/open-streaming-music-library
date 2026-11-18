"""Phase M.0a (SC-16 path containment, M-U08 config half): configured
directories are absolute after loading, so stored file paths and journal
paths are absolute and recovery's string compares stay valid."""

import pytest

from app.config import Settings

_DIRS = {
    "IMPORT_DIR": "import_dir",
    "MUSIC_LIBRARY_DIR": "music_library_dir",
    "APP_DATA_DIR": "app_data_dir",
    "USER_IMPORT_DIR": "user_import_dir",
}


@pytest.fixture
def in_tmp(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    for var in _DIRS:
        monkeypatch.delenv(var, raising=False)
    return tmp_path


def test_relative_directories_resolve_against_the_working_directory(in_tmp, monkeypatch):
    for var in _DIRS:
        monkeypatch.setenv(var, f"./nested/../{var.lower()}")

    settings = Settings(_env_file=None)

    for var, field in _DIRS.items():
        value = getattr(settings, field)
        assert value.is_absolute()
        assert value == in_tmp / var.lower()


def test_default_directories_are_absolute(in_tmp):
    settings = Settings(_env_file=None)

    assert settings.import_dir == in_tmp / "import"
    assert settings.music_library_dir == in_tmp / "music"
    assert settings.app_data_dir == in_tmp / "data"
    assert settings.user_import_dir == in_tmp / "import-users"
