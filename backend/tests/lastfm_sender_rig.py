"""A rig for the Last.fm sender tests (9D.2b): a real database, the server
state, the in-process fake of Last.fm (MockTransport, never a socket), the
gate on a fake monotonic clock and a fixed wall clock, and the sender built on
them. Tests call ``rig.sender.run_pass()`` directly; nothing waits in real time.

Every value is made up (``tests/lastfm_secrets.py``)."""

import json
import sqlite3
import uuid
from dataclasses import dataclass
from urllib.parse import parse_qsl

from app.services.lastfm_client import LastfmClient
from app.services.lastfm_crypto import encrypt
from app.services.lastfm_gate import LastfmGate
from app.services.lastfm_now_playing import NowPlayingNotices
from app.services.lastfm_sender import ScrobbleSender
from app.services.lastfm_state import LastfmService, LastfmState
from tests import lastfm_secrets as planted
from tests.lastfm_fake import FakeClock, FakeLastfm, make_config
from tests.owned_database import add_test_user
from tests.schema_fixtures import open_database

WALL_MS = 1_800_000_000_000
NOW_S = WALL_MS // 1000
DAY_S = 86_400
DAY_MS = DAY_S * 1000
SETTLE_S = 60
GAP_S = 5


class WallClock:
    def __init__(self, ms: int = WALL_MS):
        self.ms = ms

    def __call__(self) -> int:
        return self.ms

    def advance_s(self, seconds: float) -> None:
        self.ms += int(seconds * 1000)


@dataclass
class SenderRig:
    db: object
    state: LastfmState
    fake: FakeLastfm
    gate_clock: FakeClock
    wall: WallClock
    client: LastfmClient
    gate: LastfmGate
    sender: ScrobbleSender

    def new_sender(self) -> ScrobbleSender:
        """Another sender over the same database (a restart): fresh gate and memory."""
        gate = LastfmGate(self.state, gap_s=GAP_S, clock=self.gate_clock, wait=self.gate_clock.wait)
        return ScrobbleSender(
            self.db, self.state, client=self.client, gate=gate,
            notices=NowPlayingNotices(clock=self.gate_clock),
            settle_delay_s=SETTLE_S, now_ms=self.wall, clock=self.gate_clock,
        )


def make_rig(tmp_path, *, settle_delay_s: int = SETTLE_S, db=None) -> SenderRig:
    db = db or open_database(tmp_path / "database.db")
    config = make_config(settle_delay_s=settle_delay_s, min_request_gap_s=GAP_S)
    state = LastfmState(LastfmService.RUNNING, config)
    fake = FakeLastfm()
    gate_clock = FakeClock()
    wall = WallClock()
    client = LastfmClient(config, transport=fake.transport, clock=gate_clock)
    gate = LastfmGate(state, gap_s=GAP_S, clock=gate_clock, wait=gate_clock.wait)
    sender = ScrobbleSender(
        db, state, client=client, gate=gate,
        notices=NowPlayingNotices(clock=gate_clock),  # 9D.2c: a notice's age is on the gate's clock
        settle_delay_s=settle_delay_s, now_ms=wall, clock=gate_clock,
    )
    return SenderRig(db, state, fake, gate_clock, wall, client, gate, sender)


# --- database seeding and reading -------------------------------------------------------


def execute(rig: SenderRig, sql: str, params=()) -> None:
    conn = sqlite3.connect(rig.db.context.database_path)
    try:
        conn.execute(sql, params)
        conn.commit()
    finally:
        conn.close()


def query(rig: SenderRig, sql: str, params=()) -> list[dict]:
    conn = sqlite3.connect(rig.db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in conn.execute(sql, params).fetchall()]
    finally:
        conn.close()


def session_key_for(name: str) -> str:
    """A distinct made-up session key per user (not hex)."""
    return f"{planted.SESSION_KEY}-{name}"


def connect_user(
    rig: SenderRig,
    name: str,
    *,
    opted_in: bool = True,
    needs_reconnect: bool = False,
    session_key: str | None = None,
    session_key_enc: str | None = None,
) -> int:
    """A user with a bound Last.fm connection; returns the user id."""
    owner = add_test_user(rig.db, name)
    bind(rig, owner, opted_in=opted_in, needs_reconnect=needs_reconnect,
         session_key=session_key or session_key_for(name), session_key_enc=session_key_enc)
    return owner


def bind(rig, owner, *, opted_in=True, needs_reconnect=False, session_key=None,
         session_key_enc=None, account="alpha") -> str:
    """(Re)bind ``owner``'s connection with a new connection_id; returns it."""
    connection_id = str(uuid.uuid4())
    key_enc = session_key_enc or encrypt(planted.CREDENTIAL_KEY, session_key or planted.SESSION_KEY)
    execute(rig, "DELETE FROM lastfm_connections WHERE owner_id = ?", (owner,))
    execute(
        rig,
        "INSERT INTO lastfm_connections (owner_id, connection_id, account_name, session_key_enc,"
        " opted_in, needs_reconnect, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (owner, connection_id, account, key_enc, int(opted_in), int(needs_reconnect),
         rig.wall.ms - 1, rig.wall.ms - 1),
    )
    return connection_id


def queue_row(
    rig: SenderRig,
    owner: int,
    *,
    listened_at_s: int = NOW_S - 3600,
    created_at: int | None = None,
    artist: str = "Artist",
    track: str | None = None,
    attempts: int = 0,
    alone: bool = False,
    status: str = "pending",
    code: str | None = None,
    done_at: int | None = None,
    extra: dict | None = None,
) -> str:
    """One outbox row as the subscriber writes it (settled by default); returns its uuid."""
    event_uuid = str(uuid.uuid4())
    payload = {"artist": artist, "track": track or f"Track {listened_at_s}", "timestamp": listened_at_s}
    payload.update(extra or {})
    created = rig.wall.ms - SETTLE_S * 1000 - 1 if created_at is None else created_at
    execute(
        rig,
        "INSERT INTO scrobble_outbox (event_uuid, owner_id, payload, listened_at_s, status,"
        " result_code, attempts, alone, created_at, done_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (event_uuid, owner, json.dumps(payload, ensure_ascii=False), listened_at_s, status, code,
         attempts, int(alone), created, done_at),
    )
    return event_uuid


def row(rig: SenderRig, event_uuid: str) -> dict | None:
    found = query(rig, "SELECT * FROM scrobble_outbox WHERE event_uuid = ?", (event_uuid,))
    return found[0] if found else None


def rows(rig: SenderRig, owner: int | None = None) -> list[dict]:
    if owner is None:
        return query(rig, "SELECT * FROM scrobble_outbox ORDER BY listened_at_s, event_uuid")
    return query(
        rig, "SELECT * FROM scrobble_outbox WHERE owner_id = ? ORDER BY listened_at_s, event_uuid",
        (owner,),
    )


def connection(rig: SenderRig, owner: int) -> dict | None:
    found = query(rig, "SELECT * FROM lastfm_connections WHERE owner_id = ?", (owner,))
    return found[0] if found else None


# --- what was sent -----------------------------------------------------------------------


@dataclass
class Sent:
    method: str
    sk: str
    timestamps: list[int]
    fields: list[dict]


def sent(rig: SenderRig) -> list[Sent]:
    """Every request the fake received, decoded: rows in body index order."""
    out = []
    for request in rig.fake.requests:
        form = dict(parse_qsl(request.content.decode("utf-8"), keep_blank_values=True))
        by_index: dict[int, dict] = {}
        for name, value in form.items():
            if "[" in name:
                field, index = name[:-1].split("[")
                by_index.setdefault(int(index), {})[field] = value
        fields = [by_index[i] for i in sorted(by_index)]
        out.append(Sent(form["method"], form.get("sk"), [int(f["timestamp"]) for f in fields if "timestamp" in f], fields))
    return out
