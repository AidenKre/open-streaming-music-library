"""Username rules shared by the env admin and registration."""

import re

USERNAME_PATTERN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]{2,31}", re.ASCII)


def is_valid_username(name: str) -> bool:
    return USERNAME_PATTERN.fullmatch(name) is not None


def username_key(name: str) -> str:
    return name.lower()


RESERVED_USERNAMES = frozenset(
    {"root", "system", "con", "prn", "aux", "nul"}
    | {f"com{i}" for i in range(1, 10)}
    | {f"lpt{i}" for i in range(1, 10)}
)


def is_reserved_username(name: str) -> bool:
    return name.casefold() in RESERVED_USERNAMES
