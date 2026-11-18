"""Master-admin bootstrap: the admin account comes from the environment."""

import logging
import time
from pathlib import Path

from app.auth.passwords import (
    MAX_PASSWORD_LENGTH,
    MIN_PASSWORD_LENGTH,
    WeakPassword,
    hash_password,
    needs_rehash,
    validate_password,
    verify_password,
)
from app.core.secret_file import (
    SecretFileUnreadable,
    read_secret_file,
    warn_if_group_or_world_readable,
)
from app.database import UsernameTaken
from app.auth.usernames import is_valid_username, username_key
from app.library_folders import choose_library_folder

logger = logging.getLogger(__name__)


def _admin_password(settings) -> str:
    secret = settings.osml_admin_password
    password = secret.get_secret_value() if secret is not None else ""
    password_file = settings.osml_admin_password_file
    if password and password_file is not None:
        raise BootstrapError(
            "Set only one of OSML_ADMIN_PASSWORD and OSML_ADMIN_PASSWORD_FILE"
        )
    if password_file is not None:
        try:
            text = read_secret_file(password_file)
        except SecretFileUnreadable as e:
            raise BootstrapError(
                f"OSML_ADMIN_PASSWORD_FILE {password_file} {e}"
            ) from None
        warn_if_group_or_world_readable(password_file, holds="the admin password")
        return text
    return password


class BootstrapError(Exception):
    """Fatal startup error: the master admin cannot be set up."""


def bootstrap_master_admin(database, settings, *, env_file: Path | None = None) -> int:
    username = settings.osml_admin_username
    if not username:
        raise BootstrapError("OSML_ADMIN_USERNAME is not set")
    if env_file is not None and env_file.exists():
        warn_if_group_or_world_readable(env_file, holds="the admin password")
    password = _admin_password(settings)
    if not password:
        raise BootstrapError(
            "OSML_ADMIN_PASSWORD (or OSML_ADMIN_PASSWORD_FILE) is not set"
        )
    try:
        validate_password(password)
    except WeakPassword:
        raise BootstrapError(
            f"OSML_ADMIN_PASSWORD needs at least {MIN_PASSWORD_LENGTH} characters "
            f"(and at most {MAX_PASSWORD_LENGTH})"
        ) from None
    if not is_valid_username(username):
        raise BootstrapError(
            "OSML_ADMIN_USERNAME must be 3-32 ASCII letters, digits, '_' or '-', "
            "not starting with '-'"
        )

    existing = database.get_master_admin()
    if existing is None:
        admin_id = _create(database, settings, username, password)
    else:
        admin_id = existing["id"]
        _reconcile(database, settings, existing, username, password)
    database.seed_user_setting(
        owner_id=admin_id,
        key="default_streaming_quality",
        value=settings.default_streaming_quality,
    )
    return admin_id


def _create(database, settings, username: str, password: str) -> int:
    key = username_key(username)
    return database.create_master_admin(
        username=username,
        username_key=key,
        password_hash=hash_password(settings, password),
        library_folder=choose_library_folder(
            key,
            existing_folders=database.get_library_folders(),
            music_library_dir=settings.music_library_dir,
            user_import_dir=settings.user_import_dir,
        ).folder,
        created_at=int(time.time()),
    )


def _reconcile(database, settings, admin: dict, username: str, password: str) -> None:
    # The library folder is fixed on the row; a rename never touches it.
    if username != admin["username"]:
        try:
            database.rename_user(admin["id"], username, username_key(username))
        except UsernameTaken:
            holder = database.get_user_by_username_key(username_key(username))
            if holder is not None and holder["deleting_at"] is not None:
                raise BootstrapError(
                    f"OSML_ADMIN_USERNAME {username!r} is held by "
                    f"{holder['username']}, who is being deleted; run "
                    f"`users delete {holder['username']}` to finish it first "
                    "(or keep the old OSML_ADMIN_USERNAME)"
                ) from None
            raise BootstrapError(
                f"OSML_ADMIN_USERNAME {username!r} is already taken by another user"
            ) from None
    if not verify_password(settings, admin["password_hash"], password):
        database.set_password_hash_and_revoke_sessions(
            admin["id"], hash_password(settings, password), int(time.time())
        )
    elif needs_rehash(settings, admin["password_hash"]):
        database.set_password_hash(admin["id"], hash_password(settings, password))
