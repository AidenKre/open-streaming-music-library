"""The admin tool's ``--help`` is useful to an operator who never read the
README: the tool names each group, each group names each command, and each
command's own help says in a sentence what it does."""

import re

import pytest

COMMANDS = [
    ("users", "list"), ("users", "reset-password"), ("users", "disable"),
    ("users", "enable"), ("users", "delete"), ("lastfm", "purge"), ("library", "check"),
]


def _help(capsys, *argv) -> str:
    from app.cli import main

    assert main([*argv, "--help"]) == 0
    return capsys.readouterr().out


@pytest.mark.parametrize("group", ["users", "lastfm", "library"])
def test_the_tools_help_describes_every_group(capsys, group):
    text = _help(capsys)
    assert re.search(rf"^\s+{group}\s+\S", text, re.M), text


@pytest.mark.parametrize("group,command", COMMANDS)
def test_a_groups_help_describes_every_command(capsys, group, command):
    text = _help(capsys, group)
    assert re.search(rf"^\s+{re.escape(command)}\s+\S", text, re.M), text


@pytest.mark.parametrize("group,command", COMMANDS)
def test_a_commands_help_says_what_it_does(capsys, group, command):
    paragraphs = [p for p in _help(capsys, group, command).split("\n\n") if p.strip()]
    # After the usage line comes a sentence on what it does, before its arguments.
    assert not paragraphs[1].startswith(("positional arguments", "options")), paragraphs


def test_the_checks_help_says_what_it_does_not_write(capsys):
    assert "writes no library file and no database row" in _help(capsys, "library", "check")
