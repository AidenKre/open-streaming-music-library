"""Fernet storage for Last.fm session keys and pending tokens, under
``LASTFM_CREDENTIAL_KEY``.

Callers catch ``CredentialUndecryptable`` and set ``needs_reconnect`` for that
user. Never log the token, the plaintext or the key; the errors here carry
fixed texts and no cause.
"""

from cryptography.fernet import Fernet


class CredentialUndecryptable(Exception):
    pass


class CredentialKeyInvalid(Exception):
    pass


# The typed errors are raised outside every except block, so neither
# __cause__ nor __context__ can reach the key, token or plaintext.


def _fernet(key: str) -> Fernet:
    fernet = None
    try:
        fernet = Fernet(key)
    except Exception:
        pass
    if fernet is None:
        raise CredentialKeyInvalid("LASTFM_CREDENTIAL_KEY is not a valid Fernet key")
    return fernet


def encrypt(key: str, plaintext: str) -> str:
    fernet = _fernet(key)
    data = None
    try:
        data = plaintext.encode("utf-8")
    except UnicodeError:
        pass
    if data is None:
        raise ValueError("the Last.fm credential cannot be encrypted")
    return fernet.encrypt(data).decode("ascii")


def decrypt(key: str, token: str) -> str:
    fernet = _fernet(key)
    plaintext = None
    try:
        plaintext = fernet.decrypt(token.encode("ascii")).decode("utf-8")
    except Exception:
        pass
    if plaintext is None:
        raise CredentialUndecryptable("the stored Last.fm credential cannot be decrypted")
    return plaintext
