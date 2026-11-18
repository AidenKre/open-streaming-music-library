"""Phase 7A.1b: the edit-journal, conversion and audio-identity reconciles run
through the SC-16e startup recovery registry (review case 7-U07).

They keep their relative order and their behavior; the registry runs after
``CoverArtManager`` and both encoded caches exist and before the cover-art
backfill and the first worker (``encoder_coordinator.startup()``). The
interrupted-conversion cache eviction is part of the conversion step. A
failure in any of the three still stops startup, as before this piece.
"""

import sqlite3
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core.instance_lock import InstanceLockHeld, acquire_instance_lock
from app.database import DatabaseContext
from app.database.database import Database
from app.services.encoded_cache import EncodedCache, EncodedCacheContext
from tests.identity_worker_fixtures import add_track
from tests.schema_fixtures import INIT_SQL


def _wrap(calls, label, real):
    def wrapper(*args, **kwargs):
        calls.append(label)
        return real(*args, **kwargs)

    return wrapper


@pytest.fixture
def spied(configure_app, monkeypatch):
    """A configured app whose startup records every step this piece orders."""
    main = configure_app()
    calls: list[str] = []
    for cls, attr, label in (
        (main.CoverArtManager, "__init__", "cover art manager"),
        (main.EncodedCache, "__init__", "encoded cache"),
        (main.CoverArtManager, "backfill_cover_art", "backfill"),
        (main.EncoderCoordinator, "startup", "encoder startup"),
    ):
        monkeypatch.setattr(cls, attr, _wrap(calls, label, getattr(cls, attr)))
    for name, label in (
        ("reconcile_journal", "journal"),
        ("reconcile_conversion_jobs", "conversion"),
        ("reconcile_audio_identity", "identity"),
        ("evict_converted_track_caches", "evict"),
    ):
        monkeypatch.setattr(main, name, _wrap(calls, label, getattr(main, name)))
    return main, calls


def test_the_reconciles_run_in_order_after_the_art_manager_and_caches_and_before_backfill_and_workers(
    spied, monkeypatch
):
    main, calls = spied
    interrupted = "00000000-0000-4000-8000-000000000001"

    def capture(database):
        calls.append("capture interrupted")
        return {interrupted}

    monkeypatch.setattr(main, "_interrupted_conversion_uuids", capture)

    with TestClient(main.app):
        pass

    assert calls == [
        "cover art manager",
        "encoded cache",
        "encoded cache",
        # The convert rows are read before journal recovery deletes them.
        "capture interrupted",
        "journal",
        "conversion",
        "evict",
        "identity",
        "backfill",
        "encoder startup",
    ]


@pytest.mark.parametrize(
    ("failing", "expected"),
    [
        ("reconcile_journal", ["journal"]),
        ("reconcile_conversion_jobs", ["journal", "conversion"]),
        ("reconcile_audio_identity", ["journal", "conversion", "identity"]),
    ],
)
def test_a_failing_reconcile_still_stops_startup_and_releases_the_lock(
    spied, monkeypatch, tmp_path, failing, expected
):
    main, calls = spied
    label = expected[-1]

    def boom(*args, **kwargs):
        calls.append(label)
        raise RuntimeError("reconcile failed")

    monkeypatch.setattr(main, failing, boom)

    with pytest.raises(RuntimeError, match="reconcile failed"):
        with TestClient(main.app):
            pass

    assert [c for c in calls if c not in ("cover art manager", "encoded cache")] == expected
    acquire_instance_lock(tmp_path / "data").release()


def test_startup_refused_by_the_instance_lock_runs_no_recovery_step(spied, tmp_path):
    main, calls = spied
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    other_instance = acquire_instance_lock(data_dir)
    try:
        with pytest.raises(InstanceLockHeld):
            with TestClient(main.app):
                pass
    finally:
        other_instance.release()

    assert calls == []


# --- every step runs twice idempotently ----------------------------------------------------------


def _snapshot(db_path: Path, music: Path) -> dict:
    conn = sqlite3.connect(db_path)
    try:
        tables = {
            "edit_journal": "SELECT intent, uuid_id, old_path, new_path, temp_path FROM edit_journal ORDER BY id",
            "conversion_jobs": "SELECT id, status, error_text FROM conversion_jobs ORDER BY id",
            "tracks": "SELECT uuid_id, file_path, revision FROM tracks ORDER BY uuid_id",
            "identity": (
                "SELECT uuid_id, generation, exact_state, fp_state, match_state "
                "FROM track_audio_identity ORDER BY uuid_id"
            ),
        }
        rows = {name: conn.execute(query).fetchall() for name, query in tables.items()}
    finally:
        conn.close()
    files = {
        str(p.relative_to(music)): p.read_bytes() for p in sorted(music.rglob("*")) if p.is_file()
    }
    return {"rows": rows, "files": files}


def test_every_recovery_step_runs_twice_with_the_same_result(configure_app, monkeypatch, tmp_path):
    main = configure_app()
    with TestClient(main.app):
        db_path = main.app.state.database.context.database_path
        owner = main.app.state.admin_user_id
        root = main.app.state.admin_library.root
    music = tmp_path / "music"
    staging = music / ".staging"
    database = Database(DatabaseContext(database_path=db_path, init_sql_path=INIT_SQL))

    # A same-path conversion that committed but crashed before its os.replace.
    root.mkdir(parents=True, exist_ok=True)
    master = root / "song.flac"
    master.write_bytes(b"pre-conversion bytes")
    converted_uuid = add_track(database, master, owner_id=owner)
    converted_temp = staging / f"{converted_uuid}.7.tagged.flac"
    converted_temp.write_bytes(b"converted bytes")
    database.insert_journal_entry(
        "convert", converted_uuid, str(master), None, str(converted_temp), owner_id=owner
    )
    # A conversion job a dead worker left running.
    conn = sqlite3.connect(db_path)
    try:
        conn.execute(
            "INSERT INTO conversion_jobs (uuid_id, target_codec, target_container, status, owner_id) "
            "VALUES (?, 'flac', 'flac', 'running', ?)",
            (converted_uuid, owner),
        )
        conn.commit()
    finally:
        conn.close()
    # Staged temps no journal row owns: only the top level of .staging is swept.
    orphan_temp = staging / "11111111-1111-4111-8111-111111111111.3.convert.flac"
    orphan_temp.write_bytes(b"orphan")
    nested_temp = staging / "nested" / "22222222-2222-4222-8222-222222222222.3.convert.flac"
    nested_temp.parent.mkdir()
    nested_temp.write_bytes(b"nested")
    unrelated = staging / "notes.txt"
    unrelated.write_bytes(b"not a temp")
    # A track with no identity row yet.
    (root / "other.flac").write_bytes(b"other bytes")
    no_identity_uuid = add_track(database, root / "other.flac", owner_id=owner, identity={"_none": True})
    # Encodes made from the pre-conversion bytes.
    data = tmp_path / "data"
    stale_encodes = [
        EncodedCache(EncodedCacheContext(cache_dir=data / name, max_size_bytes=0)).path_for(converted_uuid, "high")
        for name in ("encoded_cache", "default_cache")
    ]
    for path in stale_encodes:
        path.write_bytes(b"encode of the pre-conversion bytes")

    captured = []
    real_run = getattr(main, "run_startup_recovery", None)

    def capture(steps):
        captured.append(list(steps))
        return real_run(steps)

    monkeypatch.setattr(main, "run_startup_recovery", capture, raising=False)

    with TestClient(main.app):
        pass

    assert len(captured) == 1, "startup runs the recovery registry once"
    [steps] = captured
    assert [s.name for s in steps][:3] == ["edit journal", "conversion jobs", "audio identity"]
    assert all(s.fatal for s in steps[:3])

    # The first run recovered everything.
    assert master.read_bytes() == b"converted bytes"
    assert not converted_temp.exists()
    assert not orphan_temp.exists()
    assert nested_temp.read_bytes() == b"nested"
    assert unrelated.read_bytes() == b"not a temp"
    assert not any(p.exists() for p in stale_encodes)
    first = _snapshot(db_path, music)
    assert first["rows"]["edit_journal"] == []
    assert first["rows"]["conversion_jobs"] == [(1, "failed", "interrupted by restart")]
    assert no_identity_uuid in {row[0] for row in first["rows"]["identity"]}

    # The second run of the same steps changes nothing.
    real_run(steps)

    assert _snapshot(db_path, music) == first
    assert not any(p.exists() for p in stale_encodes)


def test_a_failing_conversion_reconcile_still_evicts_the_interrupted_conversions_encodes(
    configure_app, monkeypatch, tmp_path
):
    # Review r1: journal recovery has already deleted the convert rows by the
    # time the conversion step runs, so a later start could not find them again.
    main = configure_app()
    interrupted = "00000000-0000-4000-8000-000000000002"
    data = tmp_path / "data"
    stale = [
        EncodedCache(EncodedCacheContext(cache_dir=data / name, max_size_bytes=0)).path_for(interrupted, "high")
        for name in ("encoded_cache", "default_cache")
    ]
    for path in stale:
        path.write_bytes(b"encode of the pre-conversion bytes")

    def boom(*args, **kwargs):
        raise RuntimeError("reconcile failed")

    monkeypatch.setattr(main, "_interrupted_conversion_uuids", lambda database: {interrupted})
    monkeypatch.setattr(main, "reconcile_conversion_jobs", boom)

    with pytest.raises(RuntimeError, match="reconcile failed"):
        with TestClient(main.app):
            pass

    assert not any(p.exists() for p in stale)
