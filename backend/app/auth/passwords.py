"""Password hashing: argon2id, the only place argon2 is used."""

import functools
import secrets
import threading
import unicodedata
from contextlib import contextmanager

from argon2 import PasswordHasher, Type
from argon2.exceptions import InvalidHashError, VerificationError


def password_hasher(settings) -> PasswordHasher:
    return _hasher(bool(settings.osml_insecure_fast_password_hashing))


def _hasher(fast: bool) -> PasswordHasher:
    if fast:  # tests only
        return PasswordHasher(
            time_cost=1, memory_cost=8, parallelism=1, type=Type.ID
        )
    return PasswordHasher(
        time_cost=2, memory_cost=19 * 1024, parallelism=1, type=Type.ID
    )


MIN_PASSWORD_LENGTH = 8
MAX_PASSWORD_LENGTH = 1024


class WeakPassword(Exception):
    """A password outside the length rule. Never carries the password."""


class AuthBusy(Exception):
    """Every hashing slot is taken; the caller should retry."""


_slots = threading.BoundedSemaphore(2)


@contextmanager
def _hashing_slot():
    if not _slots.acquire(blocking=False):
        raise AuthBusy("password hashing is busy")
    try:
        yield
    finally:
        _slots.release()


def _normalize(password: str) -> str:
    return unicodedata.normalize("NFC", password)


def validate_password(password: str) -> str:
    """Return the NFC-normalized password if its length is 8-1024, else raise."""
    normalized = _normalize(password)
    if not MIN_PASSWORD_LENGTH <= len(normalized) <= MAX_PASSWORD_LENGTH:
        raise WeakPassword(
            f"password must be {MIN_PASSWORD_LENGTH}-{MAX_PASSWORD_LENGTH} characters"
        )
    return normalized


def hash_password(settings, password: str) -> str:
    with _hashing_slot():
        return password_hasher(settings).hash(_normalize(password))


def verify_password(settings, stored_hash: str, password: str) -> bool:
    with _hashing_slot():
        try:
            return password_hasher(settings).verify(stored_hash, _normalize(password))
        except (VerificationError, InvalidHashError):
            return False


def needs_rehash(settings, stored_hash: str) -> bool:
    try:
        return password_hasher(settings).check_needs_rehash(stored_hash)
    except InvalidHashError:
        return False


_dummy_lock = threading.Lock()


@functools.lru_cache(maxsize=None)
def _dummy_hash(fast: bool) -> str:
    # One-time, per parameter set; made directly so it takes no hashing slot,
    # and under a lock so a cold cache never hashes more than one at a time.
    with _dummy_lock:
        return _hasher(fast).hash(secrets.token_urlsafe(16))


def prepare_dummy_hash(settings) -> None:
    _dummy_hash(bool(settings.osml_insecure_fast_password_hashing))


def verify_against_dummy(settings, password: str) -> bool:
    """One real verify at the current parameters, so an unknown user costs the
    same as a known one."""
    dummy = _dummy_hash(bool(settings.osml_insecure_fast_password_hashing))
    return verify_password(settings, dummy, password)
