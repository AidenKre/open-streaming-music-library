"""Shared setup for the 7A.3b publish-step tests: a prepared commit and exact
library tracks, all plain SQL (never the code under test)."""

import json
from typing import Optional, Union

from app.services.audio_identity import AudioIdentity, identity_to_columns
from tests.identity_worker_fixtures import add_track, sql
from tests.upload_commit_fixtures import NO_ACKS, accept, ready_item
from tests.upload_validation_fixtures import exact_for, new_uuid, stage_item

FINAL_METADATA = '{"v":1,"title":"Airbag","artist":"Radiohead"}'


def frozen_acks(library_tracks=(), staged_items=()) -> str:
    return json.dumps({"library_tracks": sorted(library_tracks), "staged_items": sorted(staged_items)},
                      separators=(",", ":"))


def prepared_commit(db, music, staged=None, *, acks: Union[str, dict, None] = None,
                    identity: Optional[AudioIdentity] = None, content: bytes = b"audio-A",
                    state: str = "prepared", owner_id: Optional[int] = None, **ready_kwargs) -> dict:
    """An accepted commit turned into a journal in ``state`` (default prepared)
    carrying the journaled identity (default: the exact hash of ``content``)."""
    if staged is None:
        staged = ready_item(db, music / ".uploads", content=content, owner_id=owner_id, **ready_kwargs)
    if isinstance(acks, dict):
        acks = frozen_acks(acks.get("library_tracks", ()), acks.get("staged_items", ()))
    commit = accept(db, staged, acks=acks or NO_ACKS)
    identity = identity or AudioIdentity(exact=exact_for(staged["source"].read_bytes()),
                                         tool_versions="ffmpeg 8.1", computed_at=1700)
    columns = identity_to_columns(identity)
    names = list(columns)
    final = str(music / "lib" / f"{commit['track']}.flac")
    sql(db, "UPDATE upload_commit_journal SET state = ?, final_path = ?, final_metadata = ?,"
            " digest_check = 'verified', lease_boot_id = NULL, "
            + ", ".join(f"{n} = ?" for n in names) + " WHERE owner_id = ? AND operation_uuid = ?",
        (state, final, FINAL_METADATA, *columns.values(), commit["owner_id"], commit["op"]))
    return commit


def library_track(db, music, content: bytes = b"audio-A", *, owner_id: Optional[int] = None,
                  exact_state: str = "current", digest: Optional[str] = ...,  # type: ignore[assignment]
                  identity: Optional[dict] = None) -> str:
    """A library track whose exact identity follows ``content`` (override with
    ``digest``/``exact_state``; ``identity`` replaces columns wholesale)."""
    exact = exact_for(content)
    values = {"exact_state": exact_state, "exact_kind": exact.kind,
              "exact_digest": exact.digest if digest is ... else digest,
              "sample_rate_hz": exact.sample_rate_hz, "channels": exact.channels,
              "bits_per_sample": exact.bits_per_sample}
    values.update(identity or {})
    return add_track(db, music / "lib" / f"t-{new_uuid()}.flac", owner_id=owner_id,
                     identity=values)


def import_item(db, music, track_uuid: str, *, owner_id: Optional[int] = None, state: str = "imported",
                acks_for: tuple = ()) -> dict:
    """Another upload item that published ``track_uuid`` (or, with another
    ``state``, one that did not); ``acks_for`` are item uuids its persisted
    acknowledgement rows list as staged_item subjects."""
    staged = stage_item(db, music / ".uploads", owner_id=owner_id, state="review_ready")
    if state == "imported":
        sql(db, "UPDATE upload_items SET state = 'imported', result_track_uuid = ?, result_revision = 1"
                " WHERE owner_id = ? AND item_uuid = ?", (track_uuid, staged["owner_id"], staged["item_uuid"]))
    for subject in acks_for:
        sql(db, "INSERT INTO upload_item_acknowledgements (owner_id, item_uuid, subject_kind, subject_ref)"
                " VALUES (?, ?, 'staged_item', ?)", (staged["owner_id"], staged["item_uuid"], subject))
    return staged


# ---- S2: publisher construction and observation helpers ----

import sqlite3  # noqa: E402

from app.services.upload_publish import SimulatedCrash, UploadPublisher  # noqa: E402
from tests.upload_commit_fixtures import FakeArt, FakeCoverArt, make_commit_worker  # noqa: E402,F401


class FakeSignal:
    """``IdentityWakeup`` stand-in: counts notifies; ``probe`` runs at each one."""

    def __init__(self, probe=None):
        self.notifies = 0
        self.probe = probe
        self.observed: list = []

    def notify(self) -> None:
        self.notifies += 1
        if self.probe is not None:
            self.observed.append(self.probe())


class RecordingSeam:
    """A seam that records its points and raises SimulatedCrash at ``crash_at``."""

    def __init__(self, crash_at: Optional[str] = None):
        self.points: list[str] = []
        self.crash_at = crash_at

    def __call__(self, name: str) -> None:
        self.points.append(name)
        if name == self.crash_at:
            raise SimulatedCrash(name)


def make_publisher(db, music, **overrides) -> UploadPublisher:
    kwargs = dict(uploads_root=music / ".uploads", music_library_dir=music,
                  cover_art=FakeCoverArt(), identity_signal=FakeSignal(),
                  fingerprinter_present=False, clock=lambda: 1_700_000_100,
                  extract_art=FakeArt(None))
    kwargs.update(overrides)
    return UploadPublisher(db, **kwargs)


def track_row(db, track_uuid: str) -> Optional[dict]:
    rows = sql(db, "SELECT * FROM tracks WHERE uuid_id = ?", (track_uuid,))
    return rows[0] if rows else None


def meta_row(db, track_uuid: str) -> dict:
    [row] = sql(db, "SELECT * FROM trackmetadata WHERE uuid_id = ?", (track_uuid,))
    return row


def identity_of(db, track_uuid: str) -> dict:
    [row] = sql(db, "SELECT * FROM track_audio_identity WHERE uuid_id = ?", (track_uuid,))
    return row


def item_state_via_new_connection(db, commit: dict):
    """The item's state read on a fresh connection (what another reader sees)."""
    conn = sqlite3.connect(db.context.database_path)
    try:
        row = conn.execute("SELECT state FROM upload_items WHERE owner_id = ? AND item_uuid = ?",
                           (commit["owner_id"], commit["item_uuid"])).fetchone()
        return row[0] if row else None
    finally:
        conn.close()
