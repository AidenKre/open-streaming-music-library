"""Phase M.1a (M-U10, spec §5.1): the password rules in ``app/auth/passwords.py``.

Passwords are NFC-normalized, and the 8–1024 length rule counts characters of
the normalized form. A composed and a decomposed spelling of one password
verify alike.
"""

import threading
import unicodedata

import pytest
from argon2 import PasswordHasher

from app.auth.passwords import (
    AuthBusy,
    WeakPassword,
    hash_password,
    needs_rehash,
    validate_password,
    verify_password,
)
from app.config import Settings

COMPOSED = "café-au-lait"  # é as one code point
DECOMPOSED = unicodedata.normalize("NFD", COMPOSED)  # e + U+0301


def _settings(**overrides) -> Settings:
    values = dict(osml_insecure_fast_password_hashing=True)
    values.update(overrides)
    return Settings(_env_file=None, **values)


# ── length after NFC ────────────────────────────────────────────────────────

@pytest.mark.parametrize("length", [8, 1024])
def test_the_length_bounds_are_accepted(length):
    assert validate_password("p" * length) == "p" * length


@pytest.mark.parametrize("length", [0, 7, 1025])
def test_lengths_outside_8_to_1024_are_refused(length):
    with pytest.raises(WeakPassword):
        validate_password("p" * length)


def test_the_length_counts_the_nfc_form():
    # Eight code points decomposed, but four characters once composed.
    decomposed = unicodedata.normalize("NFD", "é" * 4)
    assert len(decomposed) == 8
    with pytest.raises(WeakPassword):
        validate_password(decomposed)


def test_a_long_decomposed_password_within_1024_once_composed_is_accepted():
    decomposed = unicodedata.normalize("NFD", "é" * 1024)
    assert len(decomposed) == 2048
    assert validate_password(decomposed) == "é" * 1024


def test_validation_returns_the_nfc_form():
    assert validate_password(DECOMPOSED) == COMPOSED


def test_the_refusal_never_echoes_the_password():
    secret = "s3cr3t!"
    with pytest.raises(WeakPassword) as refused:
        validate_password(secret)
    assert secret not in str(refused.value)
    assert secret not in repr(refused.value)


# ── NFC equivalence ─────────────────────────────────────────────────────────

def test_a_decomposed_password_verifies_against_a_composed_hash():
    settings = _settings()
    stored = hash_password(settings, COMPOSED)
    assert verify_password(settings, stored, DECOMPOSED)


def test_a_composed_password_verifies_against_a_decomposed_hash():
    settings = _settings()
    stored = hash_password(settings, DECOMPOSED)
    assert verify_password(settings, stored, COMPOSED)


def test_a_different_password_does_not_verify():
    settings = _settings()
    stored = hash_password(settings, COMPOSED)
    assert not verify_password(settings, stored, COMPOSED + "x")


# ── rehash on a parameter change ────────────────────────────────────────────

def test_a_hash_made_with_other_parameters_needs_a_rehash():
    weak = hash_password(_settings(), COMPOSED)
    assert needs_rehash(_settings(osml_insecure_fast_password_hashing=False), weak)


def test_a_hash_made_with_the_current_parameters_needs_no_rehash():
    settings = _settings()
    assert not needs_rehash(settings, hash_password(settings, COMPOSED))


# ── at most two hashes or verifies at once ──────────────────────────────────

class _BlockingHasher:
    """Makes argon2 hash/verify wait on a gate, so a test can hold slots."""

    def __init__(self, monkeypatch):
        self.release = threading.Event()
        self.entered = threading.Semaphore(0)
        real_hash, real_verify = PasswordHasher.hash, PasswordHasher.verify

        def blocking_hash(hasher, *args, **kwargs):
            self.entered.release()
            assert self.release.wait(5), "gate never released"
            return real_hash(hasher, *args, **kwargs)

        def blocking_verify(hasher, *args, **kwargs):
            self.entered.release()
            assert self.release.wait(5), "gate never released"
            return real_verify(hasher, *args, **kwargs)

        monkeypatch.setattr(PasswordHasher, "hash", blocking_hash)
        monkeypatch.setattr(PasswordHasher, "verify", blocking_verify)

    def hold(self, calls):
        """Start each call in a thread and wait until all are inside argon2."""
        threads = [threading.Thread(target=call) for call in calls]
        for thread in threads:
            thread.start()
        for _ in threads:
            assert self.entered.acquire(timeout=5), "call never reached argon2"
        return threads


def test_a_third_concurrent_hash_or_verify_is_refused_as_busy(monkeypatch):
    settings = _settings()
    stored = hash_password(settings, COMPOSED)
    gate = _BlockingHasher(monkeypatch)
    threads = gate.hold([
        lambda: hash_password(settings, COMPOSED),
        lambda: verify_password(settings, stored, COMPOSED),
    ])
    try:
        with pytest.raises(AuthBusy):
            hash_password(settings, COMPOSED)
        with pytest.raises(AuthBusy):
            verify_password(settings, stored, COMPOSED)
    finally:
        gate.release.set()
        for thread in threads:
            thread.join(5)

    # Both slots are free again once the held calls finish.
    assert verify_password(settings, stored, COMPOSED)
    assert verify_password(settings, hash_password(settings, COMPOSED), COMPOSED)


def test_one_call_in_flight_leaves_room_for_another(monkeypatch):
    settings = _settings()
    gate = _BlockingHasher(monkeypatch)
    threads = gate.hold([lambda: hash_password(settings, COMPOSED)])
    second = []
    try:
        worker = threading.Thread(target=lambda: second.append(hash_password(settings, COMPOSED)))
        worker.start()
        assert gate.entered.acquire(timeout=5)  # the second call got a slot
    finally:
        gate.release.set()
        for thread in [*threads, worker]:
            thread.join(5)
    assert len(second) == 1


def test_a_failing_verify_frees_its_slot():
    settings = _settings()
    for _ in range(3):
        assert not verify_password(settings, "not-an-argon2-hash", COMPOSED)
    assert verify_password(settings, hash_password(settings, COMPOSED), COMPOSED)
