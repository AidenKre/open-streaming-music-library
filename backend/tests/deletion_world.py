"""A fixture library with two users for the deletion worker tests (piece 8A.3c).

Masters are real files under each user's library root
(``music/<library_folder>/…``); tracks are inserted through the real
``add_track`` (FTS rows, artist and album parents); jobs are accepted through
the real ``create_deletion_job``. Expected values in the tests are written out
or read with plain SQL, never derived from the code under test.
"""

import hashlib
import json
import sqlite3
import uuid as uuidlib
from dataclasses import dataclass, field
from pathlib import Path

from app.database.database import DatabaseContext
from app.library import Library
from app.models.deletions import DeletionJobRequest
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData
from app.services.cover_art_manager import CoverArtContext, CoverArtManager
from app.services.track_locks import TrackLocks
from tests.owned_database import OwnedTestDatabase, add_test_user
from tests.schema_fixtures import INIT_SQL

BOOT = "boot-test"
NOW = 1_700_000_000


class SpyCache:
    """Records ``remove_all_for_uuid`` calls (the eviction API the worker uses)."""

    def __init__(self, fail=False):
        self.evicted: list[str] = []
        self.fail = fail

    def remove_all_for_uuid(self, uuid_id: str) -> None:
        if self.fail:
            raise OSError("cache unavailable")
        self.evicted.append(uuid_id)


@dataclass
class World:
    tmp: Path
    db: OwnedTestDatabase
    music: Path
    owner: int
    sam: int
    locks: TrackLocks
    cover_art: CoverArtManager
    cache: SpyCache = field(default_factory=SpyCache)
    default_cache: SpyCache = field(default_factory=SpyCache)
    seams: list = field(default_factory=list)

    def root(self, uid: int) -> Path:
        return self.music / ("owner" if uid == self.owner else "sam")


def build_world(tmp_path: Path) -> World:
    db = OwnedTestDatabase(
        DatabaseContext(database_path=tmp_path / "db.sqlite", init_sql_path=INIT_SQL)
    )
    assert db.initialize()
    sam = add_test_user(db, "sam")  # library_folder "sam"; the owner's is "owner"
    music = tmp_path / "music"
    (music / ".deleting").mkdir(parents=True)
    world = World(
        tmp=tmp_path,
        db=db,
        music=music,
        owner=db.owner_id,
        sam=sam,
        locks=TrackLocks(),
        cover_art=CoverArtManager(CoverArtContext(cover_art_dir=tmp_path / "art", database=db)),
    )
    world.root(world.owner).mkdir()
    world.root(sam).mkdir()
    return world


def sql(world: World, statement: str, params=()) -> list[tuple]:
    conn = sqlite3.connect(world.db.context.database_path)
    try:
        rows = conn.execute(statement, params).fetchall()
        conn.commit()
        return rows
    finally:
        conn.close()


def one(world: World, statement: str, params=()):
    rows = sql(world, statement, params)
    return rows[0] if rows else None


def add_art(world: World, name: str) -> int:
    path = world.tmp / "art" / f"{name}.jpg"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"art " + name.encode())
    conn = sqlite3.connect(world.db.context.database_path)
    try:
        art_id = conn.execute(
            "INSERT INTO cover_arts (sha256, phash, phash_prefix, file_path) VALUES (?, ?, ?, ?)",
            (hashlib.sha256(name.encode()).hexdigest(), "0" * 16, "00", str(path)),
        ).lastrowid
        conn.commit()
        return art_id
    finally:
        conn.close()


def add_master(
    world: World,
    rel: str,
    *,
    owner: int | None = None,
    title: str = "Lucky",
    artist: str = "Radiohead",
    album: str = "OK Computer",
    cover_art_id: int | None = None,
    data: bytes | None = None,
    create_file: bool = True,
) -> str:
    """A track whose master is ``root(owner) / rel``; returns its uuid."""
    owner = world.owner if owner is None else owner
    path = world.root(owner) / rel
    if create_file:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if data is not None else f"master {rel}".encode())
    metadata = TrackMetaData(
        title=title, artist=artist, album=album, codec="flac", duration=1.0,
        has_album_art=cover_art_id is not None, cover_art_id=cover_art_id,
    )
    track = Track(file_path=path, metadata=metadata)
    assert Library(world.db, owner).add_track(track=track)
    return track.uuid_id


def revision(world: World, uuid_id: str):
    row = one(world, "SELECT revision FROM tracks WHERE uuid_id = ?", (uuid_id,))
    return None if row is None else row[0]


def path_of(world: World, uuid_id: str) -> Path:
    return Path(one(world, "SELECT file_path FROM tracks WHERE uuid_id = ?", (uuid_id,))[0])


def counter(world: World) -> int:
    return one(world, "SELECT value FROM revision_counter WHERE id = 0")[0]


def accept_job(world: World, *targets, owner: int | None = None, op: str | None = None,
               now: int = NOW) -> str:
    """Accept a job of (uuid, base_revision) targets, in this order."""
    owner = world.owner if owner is None else owner
    op = op or str(uuidlib.uuid4())
    request = DeletionJobRequest.model_validate({
        "operation_uuid": op,
        "targets": [{"uuid_id": u, "base_revision": r} for u, r in targets],
        "confirmed_count": len(targets),
    })
    assert Library(world.db, owner).create_deletion_job(request, now=now)
    return op


def item(world: World, op: str, uuid_id: str, owner: int | None = None) -> dict:
    owner = world.owner if owner is None else owner
    row = one(
        world,
        "SELECT status, error_code, tombstone_revision, detail_json, lease_boot_id"
        " FROM deletion_job_items WHERE owner_id = ? AND operation_uuid = ? AND uuid_id = ?",
        (owner, op, uuid_id),
    )
    status, code, tomb, detail, lease = row
    return {
        "status": status,
        "error": code,
        "tombstone_revision": tomb,
        "details": json.loads(detail) if detail else [],
        "lease": lease,
    }


def journal(world: World, uuid_id: str) -> dict | None:
    conn = sqlite3.connect(world.db.context.database_path)
    conn.row_factory = sqlite3.Row
    try:
        row = conn.execute("SELECT * FROM deletion_journal WHERE uuid_id = ?", (uuid_id,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def tombstone(world: World, uuid_id: str):
    return one(world, "SELECT revision, owner_id FROM track_tombstones WHERE uuid_id = ?", (uuid_id,))


def live(world: World, uuid_id: str) -> bool:
    return one(world, "SELECT count(*) FROM live_tracks WHERE uuid_id = ?", (uuid_id,))[0] == 1


def files_under(path: Path) -> dict[str, bytes]:
    """Every regular file (not following links) under ``path``: relpath -> bytes."""
    if not path.exists():
        return {}
    return {
        str(p.relative_to(path)): p.read_bytes()
        for p in sorted(path.rglob("*"))
        if p.is_file() and not p.is_symlink()
    }


def make_executor(world: World, **overrides):
    from app.services.deletion_worker import DeletionExecutor

    kwargs = dict(
        music_library_dir=world.music,
        track_locks=world.locks,
        cover_art=world.cover_art,
        cache=world.cache,
        default_cache=world.default_cache,
        boot_id=BOOT,
        lock_timeout_s=0,
        clock=lambda: NOW + 5,
        seam=world.seams.append,
    )
    kwargs.update(overrides)
    return DeletionExecutor(world.db, **kwargs)


def drain(executor) -> int:
    """Run the executor until no pending item is left; the number of runs."""
    runs = 0
    while executor.run_one():
        runs += 1
        assert runs < 1000
    return runs
