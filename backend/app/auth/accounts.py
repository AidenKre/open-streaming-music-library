"""Account service: register and login. No FastAPI imports."""

import time
from dataclasses import dataclass

from app.auth import signup_policy
from app.auth.passwords import (
    AuthBusy,
    hash_password,
    needs_rehash,
    validate_password,
    verify_against_dummy,
    verify_password,
)
from app.auth.sessions import SessionTokens, new_session_tokens
from app.auth.usernames import is_reserved_username, is_valid_username, username_key
from app.library_folders import FolderChoice, choose_library_folder


class InvalidUsername(Exception):
    """The username is malformed or reserved."""


class InvalidCredentials(Exception):
    """Unknown, disabled or deleting user, or a wrong password."""


@dataclass(frozen=True)
class AccountUser:
    id: int
    username: str
    is_admin: bool
    is_master_admin: bool


def account_user(row: dict) -> AccountUser:
    return AccountUser(
        id=row["id"],
        username=row["username"],
        is_admin=bool(row["is_admin"]),
        is_master_admin=bool(row["is_master_admin"]),
    )


@dataclass(frozen=True)
class AuthResult:
    tokens: SessionTokens
    user: AccountUser
    folder_choice: FolderChoice | None


def register(database, settings, username: str, password: str) -> AuthResult:
    if not is_valid_username(username) or is_reserved_username(username):
        raise InvalidUsername("invalid username")
    password = validate_password(password)
    password_hash = hash_password(settings, password)  # before the transaction
    key = username_key(username)
    tokens = new_session_tokens()
    chosen: list[FolderChoice] = []

    def choose_folder(folders: list[str]) -> str:
        choice = choose_library_folder(
            key,
            existing_folders=folders,
            music_library_dir=settings.music_library_dir,
            user_import_dir=settings.user_import_dir,
        )
        chosen.append(choice)
        return choice.folder

    user = database.register_user(
        username=username,
        username_key=key,
        password_hash=password_hash,
        created_at=int(time.time()),
        token_hash=tokens.token_hash,
        media_hash=tokens.media_hash,
        check=lambda conn: signup_policy.check(conn, settings),
        choose_folder=choose_folder,
    )
    return AuthResult(
        tokens=tokens, user=account_user(user), folder_choice=chosen[-1]
    )


def _after_a_concurrent_rehash(database, settings, user: dict, password: str, session: dict) -> bool:
    """The session insert was refused: another sign-in may have stored its own
    rehash of this same password between our verify and our insert (whether or
    not we could rehash). Only when the stored hash changed to one at today's
    parameters, verify once more against it and start the session on it; a
    password reset (another password) still refuses."""
    current = database.get_user(user["id"])
    return (
        current is not None
        and current["password_hash"] != user["password_hash"]
        and not needs_rehash(settings, current["password_hash"])
        and verify_password(settings, current["password_hash"], password)
        and database.start_login_session(
            user_id=user["id"], verified_hash=current["password_hash"], new_hash=None, **session
        )
    )


def login(database, settings, username: str, password: str) -> AuthResult:
    """Exactly one argon2 verify on every path, so timing tells nothing; a
    second one only when another sign-in changed the stored hash meanwhile."""
    user = None
    if is_valid_username(username):
        user = database.get_user_by_username_key(username_key(username))
    if user is None:
        verify_against_dummy(settings, password)
        raise InvalidCredentials("invalid credentials")
    ok = verify_password(settings, user["password_hash"], password)
    if not ok or user["disabled_at"] is not None or user["deleting_at"] is not None:
        raise InvalidCredentials("invalid credentials")
    new_hash = None
    if needs_rehash(settings, user["password_hash"]):
        try:
            new_hash = hash_password(settings, password)
        except AuthBusy:
            pass  # rehash on a later login
    tokens = new_session_tokens()
    session = dict(
        token_hash=tokens.token_hash, media_hash=tokens.media_hash, created_at=int(time.time())
    )
    if not database.start_login_session(
        user_id=user["id"], verified_hash=user["password_hash"], new_hash=new_hash, **session
    ) and not _after_a_concurrent_rehash(database, settings, user, password, session):
        raise InvalidCredentials("invalid credentials")
    return AuthResult(
        tokens=tokens, user=account_user(user), folder_choice=None
    )
