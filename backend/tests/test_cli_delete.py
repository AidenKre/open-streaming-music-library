"""Phase M.2b (spec §6.4, M-U17): ``users delete <name>`` from the CLI.

Stopped server only: it takes the SC-16d flock and refuses while it is held.
It prints the track count and folder size and requires the typed username.
"""

import os

import pytest

from app.core.instance_lock import acquire_instance_lock
from app.services import user_delete
from tests.cli_fixtures import cli_settings, run_cli
from tests.user_delete_world import build_world, dump, exists


class Crash(BaseException):
    pass


@pytest.fixture
def world(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return build_world(cli_settings(tmp_path))


def _confirm(answer):
    asked = []

    def confirm(text):
        asked.append(text)
        return answer

    confirm.asked = asked
    return confirm


def _delete(world, tmp_path, answer="Sam"):
    confirm = _confirm(answer)
    result = run_cli(world.settings, tmp_path, "users", "delete", "Sam", confirm=confirm)
    result.prompts = confirm.asked
    return result


def _lock_is_free(world):
    lock = acquire_instance_lock(world.settings.app_data_dir)
    lock.release()
    return True


def _folder_bytes(root):
    total = 0
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in files:
            path = os.path.join(directory, name)
            if not os.path.islink(path):
                total += os.path.getsize(path)
    return total


def test_delete_shows_the_size_asks_for_the_name_and_deletes(world, tmp_path):
    size = _folder_bytes(world.files["sam_music"])

    result = _delete(world, tmp_path)

    assert result.code == 0, result.err
    assert "2 tracks" in result.out
    assert f"{size} bytes" in result.out
    assert len(result.prompts) == 1 and "Sam" in result.prompts[0]
    assert world.db.get_user(world.sam) is None
    assert world.db.get_user(world.alex) is not None
    assert not exists(world.files["sam_music"])
    assert world.files["alex_master"].exists()
    assert _lock_is_free(world)


@pytest.mark.parametrize("answer", ["sam", "", "Sam ", "Alex"])
def test_a_wrong_confirmation_changes_nothing(world, tmp_path, answer):
    before = dump(world.db)

    result = _delete(world, tmp_path, answer)

    assert result.code == 1
    assert "did not match" in result.err
    assert dump(world.db) == before
    assert all(exists(p) for p in world.files.values())
    assert _lock_is_free(world)


def test_delete_refuses_while_the_server_holds_the_flock(world, tmp_path):
    before = dump(world.db)
    lock = acquire_instance_lock(world.settings.app_data_dir)
    try:
        result = _delete(world, tmp_path)
    finally:
        lock.release()

    assert result.code == 1
    assert "server" in result.err and "osml.lock" in result.err
    assert result.prompts == []
    assert dump(world.db) == before
    assert all(exists(p) for p in world.files.values())


def test_delete_refuses_a_symlinked_root_before_asking(world, tmp_path):
    import shutil

    shutil.rmtree(world.files["sam_music"])
    world.files["sam_music"].symlink_to(world.files["alex_music"], target_is_directory=True)
    before = dump(world.db)

    result = _delete(world, tmp_path)

    assert result.code == 1
    assert result.prompts == []
    assert dump(world.db) == before
    assert world.files["alex_master"].exists()
    assert _lock_is_free(world)


@pytest.mark.parametrize("step", [1, 2, 3, 4])
def test_a_crash_after_a_step_then_the_cli_again_converges(world, tmp_path, monkeypatch, step):
    original = list(user_delete.STEPS)

    def crashing(*args, **kwargs):
        original[step - 1](*args, **kwargs)
        raise Crash()

    patched = list(original)
    patched[step - 1] = crashing
    monkeypatch.setattr(user_delete, "STEPS", patched)
    with pytest.raises(Crash):
        _delete(world, tmp_path)
    monkeypatch.setattr(user_delete, "STEPS", original)
    assert _lock_is_free(world)  # a crashed process's flock dies with it

    result = _delete(world, tmp_path)

    assert result.code == 0, result.err
    assert world.db.get_user(world.sam) is None
    assert not world.art["b"][1].exists()
    assert world.art["a"][1].exists()
    assert not exists(world.files["sam_music"])
    assert world.files["alex_master"].exists()


def test_after_a_crash_after_step_5_the_user_is_simply_gone(world, tmp_path, monkeypatch):
    original = list(user_delete.STEPS)

    def crashing(*args, **kwargs):
        original[4](*args, **kwargs)
        raise Crash()

    monkeypatch.setattr(user_delete, "STEPS", original[:4] + [crashing])
    with pytest.raises(Crash):
        _delete(world, tmp_path)

    result = _delete(world, tmp_path)

    assert result.code == 1
    assert "No user named 'Sam'" in result.err


def test_delete_against_a_missing_data_dir_creates_nothing(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    settings = cli_settings(tmp_path)

    result = run_cli(settings, tmp_path, "users", "delete", "Sam", confirm=lambda _: "Sam")

    assert result.code == 1
    assert "No database" in result.err
    assert not settings.app_data_dir.exists()
