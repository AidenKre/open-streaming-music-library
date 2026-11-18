"""Helpers for the Last.fm route tests (9D.1d): a started app whose Last.fm
holder talks to the in-process fake (never to Last.fm), fake clocks, a second
signed-in user and direct row seeding.

``open_lastfm_app(open_app_client, env)`` yields a client logged in as the
master admin. ``install(client, fake)`` replaces ``app.state.lastfm_accounts``
with one built on the app's own ``app.state.lastfm`` state and config, the
fake transport, a fake gate clock, a fake cooldown clock and a fixed wall
clock. Every value is made up (``tests/lastfm_secrets.py``)."""

import contextlib
import json
import sqlite3
import uuid
from dataclasses import dataclass, field

from app.services.lastfm_accounts import LastfmAccounts
from app.services.lastfm_client import LastfmClient
from app.services.lastfm_crypto import encrypt
from app.services.lastfm_gate import LastfmGate
from app.services.user_cooldown import UserCooldown
from tests import lastfm_secrets as planted
from tests.auth_helpers import create_session
from tests.conftest import bearer
from tests.lastfm_fake import FakeClock, FakeLastfm
from tests.lastfm_secrets import LASTFM_ENV, valid_env
from tests.lastfm_sender_rig import WallClock, execute
from tests.owned_database import add_test_user

BASE = "/settings/integrations/lastfm"
DAY_MS = 86_400_000
TOKEN_LIFETIME_MS = 600_000


@dataclass
class Rig:
    client: object
    fake: FakeLastfm
    gate_clock: FakeClock
    cooldown_clock: FakeClock
    wall: WallClock
    accounts: LastfmAccounts
    dropped: list = field(default_factory=list)
    noticed: list = field(default_factory=list)  # 9D.2c: (owner, track_uuid) per Now Playing put

    @property
    def db(self):
        return self.client.app.state.database

    @property
    def state(self):
        return self.client.app.state.lastfm


class RecordingNotices:
    """Stands in for the sender's Now Playing notices (9-R1-11): records puts and
    drops, and is attached like one a running sender listens to."""

    attached = True

    def __init__(self, dropped: list, noticed: list):
        self.dropped, self.noticed = dropped, noticed

    def put(self, owner_id, track_uuid) -> None:
        self.noticed.append((owner_id, track_uuid))

    def drop(self, owner_id) -> None:
        self.dropped.append(owner_id)


def clean_env(monkeypatch):
    for name in LASTFM_ENV:
        monkeypatch.delenv(name, raising=False)


ENVS = {
    "off": {},
    "running": valid_env(),
    # An invalid gap leaves the server stopped at startup (no config held).
    "stopped": valid_env(LASTFM_MIN_REQUEST_GAP_S="0"),
}


def install(client, fake: FakeLastfm | None = None) -> Rig:
    fake = fake or FakeLastfm()
    state = client.app.state.lastfm
    config = state.config
    gate_clock = FakeClock()
    cooldown_clock = FakeClock()
    wall = WallClock()
    dropped: list = []
    noticed: list = []
    lastfm_client = gate = None
    if config is not None:
        lastfm_client = LastfmClient(config, transport=fake.transport, clock=gate_clock)
        gate = LastfmGate(
            state, gap_s=config.min_request_gap_s, clock=gate_clock, wait=gate_clock.wait
        )
    accounts = LastfmAccounts(
        state,
        client=lastfm_client,
        gate=gate,
        cooldown=UserCooldown(clock=cooldown_clock),
        now_ms=wall,
        notices=RecordingNotices(dropped, noticed),
    )
    replaced = getattr(client.app.state, "lastfm_accounts", None)
    if replaced is not None and replaced.client is not None:
        replaced.client.close()  # the startup client is never used by a test
    client.app.state.lastfm_accounts = accounts
    return Rig(client, fake, gate_clock, cooldown_clock, wall, accounts, dropped, noticed)


@contextlib.contextmanager
def open_rig(open_app_client, server_state: str = "running", fake: FakeLastfm | None = None):
    with open_app_client(env=ENVS[server_state]) as client:
        yield install(client, fake)


def admin_id(rig: Rig) -> int:
    return _one(rig, "SELECT id FROM users WHERE username = 'admin'")[0]


def second_user(rig: Rig, username: str = "bea") -> tuple[int, dict]:
    """Another user and the headers of a session of theirs."""
    uid = add_test_user(rig.db, username)
    return uid, bearer(create_session(rig.db, uid).token)


def rows(rig: Rig, sql: str, params=()) -> list:
    conn = sqlite3.connect(rig.db.context.database_path)
    try:
        return conn.execute(sql, params).fetchall()
    finally:
        conn.close()


def _one(rig, sql, params=()):
    [row] = rows(rig, sql, params)
    return row


def enc(value: str) -> str:
    return encrypt(planted.CREDENTIAL_KEY, value)


def seed_token(rig: Rig, owner: int, *, token: str = planted.TOKEN, expires_at: int | None = None) -> str:
    """Store a pending token for ``owner``; returns its ciphertext."""
    token_enc = enc(token)
    expires = rig.wall.ms + TOKEN_LIFETIME_MS if expires_at is None else expires_at
    rig.db.store_lastfm_pending_token(token_enc, expires, rig.wall.ms - 1, owner_id=owner)
    return token_enc


def seed_connection(
    rig: Rig,
    owner: int,
    *,
    account: str = "alpha",
    session_key: str = planted.SESSION_KEY,
    opted_in: bool = False,
    needs_reconnect: bool = False,
) -> str:
    """A bound connection for ``owner``; returns its connection_id."""
    token_enc = seed_token(rig, owner, token=f"seed-{uuid.uuid4().hex}")
    connection_id = str(uuid.uuid4())
    rig.db.bind_lastfm_session(
        token_enc,
        account_name=account,
        session_key_enc=enc(session_key),
        new_connection_id=connection_id,
        now=rig.wall.ms - 1,
        owner_id=owner,
    )
    execute(
        rig,
        "UPDATE lastfm_connections SET opted_in = ?, needs_reconnect = ? WHERE owner_id = ?",
        (int(opted_in), int(needs_reconnect), owner),
    )
    return connection_id


def seed_outbox(
    rig: Rig,
    owner: int,
    *,
    status: str = "pending",
    code: str | None = None,
    done_at: int | None = None,
    listened_at_s: int = 1_799_000_000,
    artist: str = "Artist",
    track: str = "Track",
) -> str:
    event_uuid = str(uuid.uuid4())
    payload = json.dumps({"artist": artist, "track": track, "timestamp": listened_at_s})
    execute(
        rig,
        "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, status,"
        " result_code, attempts, alone, created_at, done_at) VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?, ?)",
        (event_uuid, owner, payload, listened_at_s, status, code, rig.wall.ms - 10, done_at),
    )
    return event_uuid


def connection_row(rig: Rig, owner: int) -> dict | None:
    return rig.db.get_lastfm_connection(owner_id=owner)
