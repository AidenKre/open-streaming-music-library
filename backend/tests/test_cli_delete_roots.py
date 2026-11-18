"""Review r1 m-R1-14, decision DEV-M-11: ``users delete`` acts only on the
server's own tree.

The server records its resolved ``music_library_dir``, ``import_dir`` and
``user_import_dir`` in ``app_settings`` at startup. ``users delete`` refuses,
naming both paths, when its own resolved roots differ (a split environment:
systemd/docker gives the server one tree, the admin's shell another). When
nothing is recorded yet (the server never started) it proceeds as before.
Other CLI commands are unaffected.
"""

import sqlite3

import pytest
from fastapi.testclient import TestClient

from tests.cli_fixtures import cli_settings, run_cli
from tests.user_delete_world import build_world, dump, exists

ROOTS = ("music_library_dir", "import_dir", "user_import_dir")


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return build_world(cli_settings(tmp_path))


def _record(world, **paths):
    for key in ROOTS:
        world.db.set_setting(key, str(paths.get(key, getattr(world.settings, key).resolve())))


def _delete(world, tmp_path):
    return run_cli(world.settings, tmp_path, "users", "delete", "Sam", confirm=lambda _: "Sam")


def test_the_server_records_its_resolved_roots_at_startup(configure_app, tmp_path):
    main = configure_app()
    with TestClient(main.app) as client:
        db = client.app.state.database

    assert db.get_setting("music_library_dir") == str((tmp_path / "music").resolve())
    assert db.get_setting("import_dir") == str((tmp_path / "import").resolve())
    assert db.get_setting("user_import_dir") == str((tmp_path / "import-users").resolve())


@pytest.mark.parametrize("root", ROOTS)
def test_delete_refuses_when_a_root_differs_from_the_servers(world, tmp_path, root):
    server_side = tmp_path / "srv" / root
    _record(world, **{root: server_side})
    before = dump(world.db)

    result = _delete(world, tmp_path)

    assert result.code == 1
    assert str(server_side) in result.err
    assert str(getattr(world.settings, root).resolve()) in result.err
    assert dump(world.db) == before
    assert exists(world.files["sam_music"]) and world.files["sam_import"].exists()


def test_delete_proceeds_when_the_roots_match(world, tmp_path):
    _record(world)

    result = _delete(world, tmp_path)

    assert result.code == 0, result.err
    assert world.db.get_user(world.sam) is None


def test_delete_proceeds_when_the_server_never_recorded_its_roots(world, tmp_path):
    result = _delete(world, tmp_path)

    assert result.code == 0, result.err
    assert world.db.get_user(world.sam) is None


def test_other_commands_ignore_a_root_mismatch(world, tmp_path):
    _record(world, music_library_dir=tmp_path / "srv" / "music")

    result = run_cli(world.settings, tmp_path, "users", "disable", "Sam")

    assert result.code == 0, result.err
    assert world.db.get_user(world.sam)["disabled_at"] is not None


# Review r2 m-R2-12 (amends DEV-M-11): the guard fails closed, and both sides
# of the comparison are normalized with resolve().


def _sam_untouched(world):
    assert world.db.get_user(world.sam) is not None
    assert exists(world.files["sam_music"]) and world.files["sam_import"].exists()


def test_delete_refuses_when_the_recorded_roots_cannot_be_read(world, tmp_path):
    _record(world)
    conn = sqlite3.connect(world.db.context.database_path)
    conn.execute("DROP TABLE app_settings")
    conn.commit()
    conn.close()

    result = _delete(world, tmp_path)

    assert result.code == 1
    assert "could not read the server's recorded folders" in result.err
    _sam_untouched(world)


@pytest.mark.parametrize("value", ["", "relative/music", "\x00"])
def test_delete_refuses_when_a_recorded_root_cannot_be_parsed(world, tmp_path, value):
    _record(world, music_library_dir=value)

    result = _delete(world, tmp_path)

    assert result.code == 1
    assert "could not read the server's recorded folders" in result.err
    _sam_untouched(world)


def _alias(world, tmp_path, key, how):
    real = getattr(world.settings, key).resolve()
    if how == "symlink":
        link = tmp_path / f"link-to-{key}"
        link.symlink_to(real, target_is_directory=True)
        return link
    return real.parent / "." / ".." / real.parent.name / real.name  # a "..": same directory


@pytest.mark.parametrize("how", ["symlink", "dotdot"])
@pytest.mark.parametrize("root", ROOTS)
def test_a_recorded_root_spelled_differently_but_naming_the_same_folder_matches(
    world, tmp_path, root, how
):
    alias = _alias(world, tmp_path, root, how)
    assert str(alias) != str(getattr(world.settings, root).resolve())
    _record(world, **{root: alias})

    result = _delete(world, tmp_path)

    assert result.code == 0, result.err
    assert world.db.get_user(world.sam) is None
