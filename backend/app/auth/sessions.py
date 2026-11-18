"""Session tokens (spec §5.1): stored only as SHA-256 hashes, no cache."""

import hashlib
import secrets
import time
from dataclasses import dataclass

import anyio.to_thread


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class SessionTokens:
    token: str
    media_token: str

    @property
    def token_hash(self) -> str:
        return hash_token(self.token)

    @property
    def media_hash(self) -> str:
        return hash_token(self.media_token)


def new_session_tokens() -> SessionTokens:
    return SessionTokens(
        token=secrets.token_urlsafe(32), media_token=secrets.token_urlsafe(32)
    )


@dataclass(frozen=True)
class LiveSession:
    session_hash: str
    user_id: int
    is_admin: bool
    is_master_admin: bool


def _live_session_from_row(row: dict | None) -> LiveSession | None:
    if row is None:
        return None
    return LiveSession(
        session_hash=row["session_hash"],
        user_id=row["user_id"],
        is_admin=bool(row["is_admin"]),
        is_master_admin=bool(row["is_master_admin"]),
    )


async def lookup_session(database, token: str) -> LiveSession | None:
    row = await anyio.to_thread.run_sync(
        database.get_live_session, hash_token(token)
    )
    return _live_session_from_row(row)


def revoke_session_hash(database, session_hash: str) -> None:
    database.revoke_auth_session(session_hash, int(time.time()))


async def lookup_media_session(database, media_token: str) -> LiveSession | None:
    row = await anyio.to_thread.run_sync(
        database.get_live_session_by_media_hash, hash_token(media_token)
    )
    return _live_session_from_row(row)
