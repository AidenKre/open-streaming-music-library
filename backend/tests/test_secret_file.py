"""9D.1a (D15, spec §7.2): the ``_FILE`` handling of ``OSML_ADMIN_PASSWORD_FILE``,
generalised so the Last.fm secrets reuse it. The admin text is unchanged
(``test_bootstrap.py`` pins it through the bootstrap)."""

import logging

import pytest

from app.core.secret_file import (
    SecretFileUnreadable,
    read_secret_file,
    warn_if_group_or_world_readable,
)
from tests.lastfm_secrets import assert_no_secret

PLANTED = "planted-file-secret-7Qz"


def _write(path, data: bytes, mode=0o600):
    path.write_bytes(data)
    path.chmod(mode)
    return path


@pytest.mark.parametrize(
    ("data", "expected"),
    [
        (PLANTED.encode(), PLANTED),
        ((PLANTED + "\n").encode(), PLANTED),
        ((PLANTED + "\r\n").encode(), PLANTED),
        ((PLANTED + "\n\n").encode(), PLANTED + "\n"),
        (("  " + PLANTED + "  ").encode(), "  " + PLANTED + "  "),
    ],
)
def test_the_file_is_read_as_utf8_with_one_line_ending_removed(tmp_path, data, expected):
    assert read_secret_file(_write(tmp_path / "s", data)) == expected


def test_a_missing_file_raises_a_typed_error_with_the_os_reason(tmp_path):
    with pytest.raises(SecretFileUnreadable) as info:
        read_secret_file(tmp_path / "absent")
    assert "No such file" in str(info.value)
    assert info.value.__cause__ is None
    assert info.value.__context__ is None


def test_a_non_utf8_file_raises_without_its_content(tmp_path):
    path = _write(tmp_path / "s", PLANTED.encode() + b"\xff\xfe")
    with pytest.raises(SecretFileUnreadable) as info:
        read_secret_file(path)
    assert "UTF-8" in str(info.value)
    assert_no_secret(str(info.value) + repr(info.value), "the error", secrets=[PLANTED])
    assert info.value.__cause__ is None
    assert info.value.__context__ is None


def test_a_directory_is_unreadable(tmp_path):
    with pytest.raises(SecretFileUnreadable):
        read_secret_file(tmp_path)


@pytest.mark.parametrize("mode", [0o640, 0o604, 0o644])
def test_a_group_or_world_readable_file_warns_naming_what_it_holds(tmp_path, caplog, mode):
    path = _write(tmp_path / "s", PLANTED.encode(), mode)
    caplog.set_level(logging.WARNING)

    warn_if_group_or_world_readable(path, "a Last.fm secret")

    warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
    assert warnings == [
        f"{path} is readable by group or others and holds a Last.fm secret; "
        f"run: chmod 600 {path}"
    ]


def test_an_owner_only_file_does_not_warn(tmp_path, caplog):
    path = _write(tmp_path / "s", PLANTED.encode(), 0o600)
    caplog.set_level(logging.WARNING)

    warn_if_group_or_world_readable(path, "a Last.fm secret")

    assert [r for r in caplog.records if r.levelno >= logging.WARNING] == []


def test_a_missing_file_does_not_warn(tmp_path, caplog):
    caplog.set_level(logging.WARNING)
    warn_if_group_or_world_readable(tmp_path / "absent", "a Last.fm secret")
    assert caplog.records == []


def test_the_admin_password_warning_text_is_unchanged(tmp_path, caplog):
    path = _write(tmp_path / "s", PLANTED.encode(), 0o640)
    caplog.set_level(logging.WARNING)

    warn_if_group_or_world_readable(path, "the admin password")

    assert [r.getMessage() for r in caplog.records] == [
        f"{path} is readable by group or others and holds the admin password; "
        f"run: chmod 600 {path}"
    ]


def test_a_path_with_a_nul_byte_is_unreadable_not_a_crash(tmp_path):
    # pathlib raises ValueError, not OSError, for an embedded NUL.
    path = tmp_path / "planted\0name"
    with pytest.raises(SecretFileUnreadable) as info:
        read_secret_file(path)
    assert info.value.__cause__ is None
    warn_if_group_or_world_readable(path, "a Last.fm secret")  # silent, no raise


def test_a_non_utf8_error_keeps_no_context(tmp_path):
    path = _write(tmp_path / "s", PLANTED.encode() + b"\xff")
    with pytest.raises(SecretFileUnreadable) as info:
        read_secret_file(path)
    assert info.value.__context__ is None, "the UnicodeDecodeError (holding the bytes) stays reachable"
