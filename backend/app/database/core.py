"""The shared core of the server's database class.

``Database`` (``app/database/database.py``) is composed from one part per
domain, and every part inherits ``DatabaseCore``. A member is here when more
than one domain uses it:

- the connection (``open_connection``, ``_connection``) and the durable point (``make_durable``);
- the revision counter (``_next_revision``, ``_bump_track_revision``);
- operation receipts (SC-16c) and the storage settle;
- the transaction primitives (SC-16a) that more than one domain runs inside a
  transaction of its own: a track's rows with its artist, album and search
  rows; a track's audio-identity row; the release of a cover-art row.

The module-level names here are the ones the core's methods or several domains
use: the track row mapper, the stored forms of a path, the track's library
identity, and the exceptions the primitives raise. The owner checks are a leaf
of their own (``app/core/owner.py``).

Imports go one way: this module imports the ``app/core`` leaves, ``app.models``
and the plain modules beside it. A domain module imports this one, and never
another domain module or ``database.py``. The imports of ``app.services``
inside two functions below stay there until the services package stops
importing its modules when it loads (it imports modules that import the
database).
"""

import sqlite3
import unicodedata
import uuid
import weakref
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Optional

from app.core.owner import _require_owner
from app.database.operation_receipts import (
    New as OpNew,
    OperationConflict,
    Replay as OpReplay,
    request_hash,
)
from app.models.track import Track
from app.models.track_meta_data import TrackMetaData

# TODO: catch specific sqlite3 exceptions rather than broad Exception

# Why a track's audio identity went stale (see _mark_audio_identity_stale_in).
STALE_REASONS = frozenset({"tag_write", "conversion", "settle"})

# Layer states that mean "this track can definitively not be compared on that
# layer". A track that settles into one of them keeps no open duplicate pairs of
# that kind. 'failed' is not one of them: it means unknown, and unknown is not
# "no match", so a failed layer keeps its pairs as they are.
EXACT_NOT_COMPARABLE_STATES = frozenset({"unsupported"})
FINGERPRINT_NOT_COMPARABLE_STATES = frozenset({"too_short", "low_information"})


def _fold_path(p):
    if p is None:
        return None
    nfd = unicodedata.normalize
    return nfd("NFD", nfd("NFD", p).casefold())


class TrackPathTaken(Exception):
    """Another track's row already names this file: the unique index on
    ``tracks.file_path_fold`` refused the write, and the transaction it was in
    wrote nothing. The writers' own checks (``track_path_in_use``, the
    organizer's name choice) come first; this is what is left when two writers
    pass their checks for one path."""


def track_path_values(path) -> tuple[str, str, str]:
    """What every write of a track's path stores, in the order (``file_path``,
    ``file_path_fold``, ``file_folder_fold``): the path as given, its canonical
    caseless form, and that form of the folder it lies in. The one place the
    stored folds are computed, so no row's folds can differ from the folds of
    its path."""
    path = str(path)
    return path, _fold_path(path), _fold_path(str(Path(path).parent))


def _is_taken_path(error: sqlite3.IntegrityError) -> bool:
    """Whether ``error`` is the unique index on the folded path refusing a row."""
    return str(error) == "UNIQUE constraint failed: tracks.file_path_fold"


class CoverArtGone(Exception):
    """A track insert referenced a cover_art_id whose row was released after the
    id was handed out; the caller must re-register the art and retry."""


class OwnerMismatch(Exception):
    """A track's artist or album row belongs to a different owner than the track.

    Raised by the post-upsert consistency check; it means an owner predicate was
    missed somewhere, never a normal condition.
    """


class TrackNotFound(Exception):
    """Raised when a metadata edit targets a uuid that no longer exists."""


class TrackAlreadyDeleted(Exception):
    """``_delete_track_in`` met the owner's own tombstone for the uuid: the
    track is already deleted, and its tombstone revision is not bumped again."""

    def __init__(self, uuid_id: str, revision: int):
        self.uuid_id = uuid_id
        self.revision = revision
        super().__init__(f"track {uuid_id} is already deleted (revision {revision})")


def effective_artist(album_artist: Optional[str], artist: Optional[str]) -> Optional[str]:
    """The artist that owns a track's library identity: album_artist wins, then
    artist, else None. Shared by ``add_track``, the metadata-edit spine, and the
    organizer's ``sanitized_destination_path`` so DB identity and on-disk layout are
    computed one way everywhere and can't diverge."""
    if album_artist and album_artist.strip():
        return album_artist.strip()
    if artist and artist.strip():
        return artist.strip()
    return None


def _library_identity(
    artist: Optional[str], album: Optional[str], album_artist: Optional[str]
) -> tuple[Optional[str], Optional[str]]:
    """A track's library identity from its tags: the effective artist (see
    ``effective_artist``) and the album name (None when blank). Derived here
    only, for insert, edit and the search text."""
    album_name = album if album is not None and album.strip() != "" else None
    return effective_artist(album_artist, artist), album_name


def _track_search_text(
    title: Optional[str], artist: Optional[str], album: Optional[str],
    album_artist: Optional[str],
) -> tuple[str, str, str]:
    """The (title, artist_name, album_name) a track's ``fts_tracks`` row holds.
    The table is contentless: a row is removed only by repeating exactly this
    text, so insert, edit and delete all derive it here from the stored tags."""
    effective, album_name = _library_identity(artist, album, album_artist)
    return title or "", effective or "", album_name or ""


@dataclass(frozen=True)
class DatabaseContext:
    database_path: Path
    init_sql_path: Path


def _row_to_track(row) -> Track:
    metadata = TrackMetaData(
        title=row["title"],
        artist=row["artist"],
        album=row["album"],
        album_artist=row["album_artist"],
        artist_id=row["artist_id"],
        album_id=row["album_id"],
        year=row["year"],
        date=row["date"],
        genre=row["genre"],
        track_number=row["track_number"],
        disc_number=row["disc_number"],
        codec=row["codec"],
        duration=row["duration"],
        bitrate_kbps=row["bitrate_kbps"],
        sample_rate_hz=row["sample_rate_hz"],
        channels=row["channels"],
        has_album_art=bool(row["has_album_art"]),
        cover_art_id=row["cover_art_id"],
    )
    keys = row.keys()
    return Track(
        uuid_id=row["uuid_id"],
        file_path=Path(row["file_path"]),
        metadata=metadata,
        created_at=row["created_at"],
        last_updated=row["last_updated"],
        revision=row["revision"] if "revision" in keys else 0,
        owner_id=row["owner_id"] if "owner_id" in keys else None,
    )


TRACK_SELECT_COLUMNS = (
    "tm.uuid_id, tm.title, tm.artist, tm.album, tm.album_artist, "
    'tm.artist_id, tm.album_id, tm."year", tm."date", tm.genre, '
    "tm.track_number, tm.disc_number, tm.codec, tm.duration, "
    "tm.bitrate_kbps, tm.sample_rate_hz, tm.channels, "
    "tm.has_album_art, tm.cover_art_id, t.file_path, "
    "t.created_at, t.last_updated, t.revision, t.owner_id"
)


def _track_select_columns(*extra_columns: str) -> str:
    columns = TRACK_SELECT_COLUMNS
    if extra_columns:
        columns += ", " + ", ".join(extra_columns)
    return columns


# The size the write-ahead log is cut back to after a checkpoint. While the
# server holds a connection open the log is never deleted, so without a limit
# (SQLite's default on most builds) it keeps its largest size until the server
# stops. 16 MiB is four times the log at which the automatic checkpoint runs
# (1,000 pages of 4 KiB), so an ordinary log is never cut and grown again; only
# a log that one large transaction grew past it is cut.
JOURNAL_SIZE_LIMIT_BYTES = 16 * 1024 * 1024


def open_connection(
    database_path,
    *,
    timeout: float = 5,
    check_same_thread: bool = True,
    isolation_level: Optional[str] = "",
) -> sqlite3.Connection:
    """Open a read-write connection to the server's database.

    This is the one place the server opens such a connection, and every
    connection it returns commits durably. ``synchronous=FULL`` syncs the
    write-ahead log before a commit returns. ``fullfsync=ON`` makes that sync
    ``F_FULLFSYNC`` on macOS, which flushes the drive's own cache (a plain
    ``fsync`` does not there). On Linux there is no such call: the flag changes
    nothing and the sync is ``fsync``/``fdatasync``, which asks the drive to
    flush.

    ``check_same_thread=False`` is only for the one connection the server holds
    open while idle; every other caller keeps the default.
    ``isolation_level=None`` (autocommit) is for the callers that run
    ``VACUUM`` or their own ``BEGIN``/``COMMIT``: the Last.fm purge's compaction
    and the table rebuild (``app/database/table_rebuild.py``). The default is
    ``sqlite3.connect``'s own.
    """
    conn = sqlite3.connect(
        database_path,
        timeout=timeout,
        check_same_thread=check_same_thread,
        isolation_level=isolation_level,
    )
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=FULL")
        conn.execute("PRAGMA fullfsync=ON")
        conn.execute(f"PRAGMA journal_size_limit={JOURNAL_SIZE_LIMIT_BYTES}")
        conn.execute("PRAGMA foreign_keys=ON")
        conn.row_factory = sqlite3.Row
    except BaseException:
        conn.close()
        raise
    return conn


class DatabaseCore:
    """What every part of ``Database`` shares. See the module docstring."""

    def __init__(self, context: DatabaseContext):
        self.context = context
        self._held = None  # the finalizer of the held connection, or None

    @contextmanager
    def _connection(self, *, commit: bool = False, timeout: float = 5, immediate: bool = False):
        conn = open_connection(self.context.database_path, timeout=timeout)
        try:
            if immediate:
                # Acquire SQLite's write lock up front, before the caller reads
                # anything: a plain SELECT (the default, non-immediate mode)
                # holds no lock, so a check-then-write sequence built on it is
                # not atomic across connections -- a second connection's own
                # check can pass against the same stale value before the first
                # connection's write lands. immediate=True closes that gap by
                # making a concurrent caller's own BEGIN IMMEDIATE block until
                # this transaction commits or rolls back.
                conn.execute("BEGIN IMMEDIATE")
            yield conn
            if commit:
                conn.commit()
        except BaseException:
            if commit:
                conn.rollback()
            raise
        finally:
            conn.close()

    def hold_open(self) -> None:
        """Keep one idle connection to the database open until ``close()``.

        While it is open, no call's close is the last one, so SQLite does not
        checkpoint the write-ahead log at the end of every call. It
        never writes and keeps no transaction open, so it blocks no writer, no
        reader and no checkpoint. It is opened with the durable settings,
        because its own close is as a rule the last one and then runs the
        checkpoint (not when the admin tool, or a worker that outlived the
        shutdown, still has a connection open: the last close is then theirs).

        The server holds one from start-up to shutdown; the admin tool and
        tests need none. It cannot leak: ``close()`` closes it, and so does
        dropping this object (a finalizer), also at interpreter exit. It may be
        closed from another thread than the one that opened it
        (``check_same_thread=False``). Holding twice opens nothing.
        """
        if self._held is not None:
            return
        # open_connection's first pragma read the file, so this connection now
        # holds SQLite's shared lock; that pragma's cursor is already dropped,
        # so no read transaction stays open. Nothing else runs on it.
        conn = open_connection(self.context.database_path, check_same_thread=False)
        # The finalizer is the only reference to the connection.
        self._held = weakref.finalize(self, conn.close)

    def close(self) -> None:
        """Close the held connection, if any.

        With no other connection open, this close is the last one: SQLite
        checkpoints the write-ahead log into the database file. The object
        stays usable (each call opens its own connection, as before) and
        ``hold_open()`` may be called again.
        """
        held, self._held = self._held, None
        if held is not None:
            held()

    @staticmethod
    def _with_operation_in(conn, *, owner_id, operation_uuid, kind, request_model, now):
        """Record or replay an operation receipt (SC-16c).

        The caller must hold BEGIN IMMEDIATE, so the check-then-insert is atomic
        across connections; without an open transaction this raises RuntimeError.
        The request model must carry every target id the operation acts on (for
        example, the path's item uuid), because the receipt is keyed by owner +
        operation uuid alone. Without that, reusing one operation uuid on a
        second target with the same body would replay instead of conflicting.
        """
        owner = _require_owner(owner_id)
        if not conn.in_transaction:
            raise RuntimeError("operation receipts require the caller's write transaction")
        digest = request_hash(request_model)
        key = str(uuid.UUID(str(operation_uuid)))
        row = conn.execute(
            "SELECT kind, request_hash, result_ref FROM operation_receipts "
            "WHERE owner_id = ? AND operation_uuid = ?",
            (owner, key),
        ).fetchone()
        if row is None:
            conn.execute(
                "INSERT INTO operation_receipts "
                "(owner_id, operation_uuid, kind, request_hash, created_at, result_ref) "
                "VALUES (?, ?, ?, ?, ?, NULL)",
                (owner, key, kind, digest, now),
            )
            return OpNew()
        if row[0] == kind and row[1] == digest:
            return OpReplay(row[2])
        raise OperationConflict(
            f"operation {key} was already used for a different request"
        )

    @staticmethod
    def _set_operation_result_in(conn, *, owner_id, operation_uuid, result_ref):
        """Store the result of an operation; the caller must hold BEGIN IMMEDIATE."""
        owner = _require_owner(owner_id)
        if not conn.in_transaction:
            raise RuntimeError("operation receipts require the caller's write transaction")
        key = str(uuid.UUID(str(operation_uuid)))
        cur = conn.execute(
            "UPDATE operation_receipts SET result_ref = ? "
            "WHERE owner_id = ? AND operation_uuid = ?",
            (result_ref, owner, key),
        )
        if cur.rowcount != 1:
            raise LookupError(f"no operation receipt for {operation_uuid}")

    @staticmethod
    def _settle_storage_in(conn, reservation_id: int, *, purpose: str) -> bool:
        """Turn a reservation into a durable (unleased) row of ``purpose``; never opens
        or commits a transaction. False when nothing changed (unknown id, already settled)."""
        cursor = conn.execute(
            "UPDATE storage_reservations SET purpose = ?, lease_boot_id = NULL"
            " WHERE id = ? AND (purpose <> ? OR lease_boot_id IS NOT NULL)",
            (purpose, reservation_id, purpose),
        )
        return cursor.rowcount > 0

    @staticmethod
    def _next_revision(conn) -> int:
        """Allocate the next monotonic revision on ``conn``'s open transaction.

        Safe under SQLite's single-writer serialization — the increment and
        read-back happen inside the caller's exclusive write transaction, so
        no two writers can observe the same value. Must be called before the
        row write that stores the returned revision."""
        conn.execute("UPDATE revision_counter SET value = value + 1 WHERE id = 0")
        return conn.execute(
            "SELECT value FROM revision_counter WHERE id = 0"
        ).fetchone()[0]

    @staticmethod
    def _bump_track_revision(conn, uuid_id: str) -> int:
        """Bump the track to the next monotonic revision; returns the value
        written so callers don't need a redundant read-back."""
        revision = DatabaseCore._next_revision(conn)
        conn.execute(
            "UPDATE tracks SET revision = ?, last_updated = unixepoch() "
            "WHERE uuid_id = ?",
            (revision, uuid_id),
        )
        return revision

    @staticmethod
    def _identity_column_values(identity) -> dict[str, Any]:
        """Identity -> ``track_audio_identity`` value columns. A computed ``failed``
        hash and a missing identity are both ``exact_state='pending'`` with every
        identity value NULL (unknown, not failed). Only ``IDENTITY_COLUMNS`` are
        returned: a carried fingerprint (fp_* keys) is never an identity-table value."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import IDENTITY_COLUMNS, ExactUnavailable, identity_to_columns
        if identity is None or (
            isinstance(identity.exact, ExactUnavailable) and identity.exact.state == "failed"
        ):
            values: dict[str, Any] = dict.fromkeys(IDENTITY_COLUMNS)
            values["exact_state"] = "pending"
            return values
        columns = identity_to_columns(identity)
        return {name: columns[name] for name in IDENTITY_COLUMNS}

    @staticmethod
    def _drop_open_pairs_in(conn, uuid_id: str, kind: str) -> None:
        """Delete the track's ``open`` duplicate pairs of ``kind`` ('exact' or
        'fingerprint'), scoped to the track's owner, on the caller's connection
        (never commits). Dismissed pairs are never touched: they record the
        user's decision."""
        conn.execute(
            "DELETE FROM track_duplicate_candidates WHERE (uuid_a = ? OR uuid_b = ?) "
            "AND kind = ? AND status = 'open' "
            "AND owner_id = (SELECT owner_id FROM tracks WHERE uuid_id = ?)",
            (uuid_id, uuid_id, kind, uuid_id),
        )

    @staticmethod
    def _stat_columns(exact_state: str, stat: Optional[tuple[int, int, int]]) -> dict[str, Any]:
        """The stat columns to store with an identity: the snapshot only when an
        identity value is written (exact state not 'pending'), else all NULL."""
        if stat is None or exact_state == "pending":
            stat = (None, None, None)
        return dict(zip(("stat_size", "stat_mtime_ns", "stat_inode"), stat))

    @staticmethod
    def _insert_audio_identity_in(
        conn, uuid_id: str, identity, *, fingerprinter_present: bool,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> None:
        """SC-16a primitive: (re)write a track's audio-identity row on the caller's
        connection (never opens, commits or closes one). A computed ``failed`` hash
        and a missing identity are both stored as ``exact_state='pending'`` with
        every identity value NULL (unknown, not failed); the worker retries. A
        precomputed print (``identity.fingerprint`` is a ``FingerprintIdentity``,
        e.g. Phase 7's staged identity) is stored in the same transaction through
        ``_write_fingerprint_in``; otherwise fp_state is 'pending' with a
        fingerprinter, else 'unavailable'. match_state is 'pending' either way.
        A track written as exact 'unsupported' loses its open exact pairs in the
        same transaction (it can no longer be compared; dismissed pairs stay).
        ``stat`` (size, mtime_ns, inode of the master the identity describes) is
        stored only when an identity value is written; otherwise, or when None,
        the stat columns are NULL (unknown)."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import FingerprintIdentity, fingerprint_to_columns

        values = DatabaseCore._identity_column_values(identity)
        values["fp_state"] = "pending" if fingerprinter_present else "unavailable"
        values["fp_algorithm"] = None
        values.update(match_state="pending", priority=0, attempts=0, next_attempt_at=None)
        values.update(DatabaseCore._stat_columns(values["exact_state"], stat))
        names = list(values)
        conn.execute(
            f"INSERT INTO track_audio_identity (uuid_id, generation, {', '.join(names)}) "
            f"VALUES (?, 1, {', '.join('?' * len(names))}) "
            f"ON CONFLICT(uuid_id) DO UPDATE SET generation = generation + 1, "
            f"{', '.join(f'{n} = excluded.{n}' for n in names)}",
            (uuid_id, *values.values()),
        )
        if values["exact_state"] in EXACT_NOT_COMPARABLE_STATES:
            DatabaseCore._drop_open_pairs_in(conn, uuid_id, "exact")
        if identity is not None and isinstance(identity.fingerprint, FingerprintIdentity):
            DatabaseCore._write_fingerprint_in(conn, uuid_id, fingerprint_to_columns(identity.fingerprint))

    @staticmethod
    def _mark_audio_identity_stale_in(conn, uuid_id: str, reason: str) -> bool:
        """SC-16a primitive: the audio bytes changed, so bump ``generation`` and
        send the exact layer and the match back to pending. The exact digest is
        kept only for 'tag_write' (the audio did not change). For 'conversion'
        / 'settle' the audio changed, so the digest is cleared (unknown until
        recomputed, never a wrong exact match), open exact pairs are dropped,
        and the fingerprint is re-pended unless it is 'unavailable' (a mark
        never claims a fingerprinter exists). Returns whether a row existed;
        never inserts one."""
        if reason not in STALE_REASONS:
            raise ValueError(f"unknown audio identity stale reason {reason!r}")
        fp_state = (
            "fp_state"
            if reason == "tag_write"
            else "CASE WHEN fp_state = 'unavailable' THEN fp_state ELSE 'pending' END"
        )
        clear_digest = (
            "" if reason == "tag_write" else "exact_kind = NULL, exact_digest = NULL, "
        )
        cursor = conn.execute(
            "UPDATE track_audio_identity SET generation = generation + 1, "
            "exact_state = 'pending', match_state = 'pending', priority = 0, "
            "attempts = 0, next_attempt_at = NULL, failure_reason = NULL, "
            f"{clear_digest}fp_state = {fp_state} WHERE uuid_id = ?",
            (uuid_id,),
        )
        if cursor.rowcount > 0 and reason != "tag_write":
            DatabaseCore._drop_open_pairs_in(conn, uuid_id, "exact")
        return cursor.rowcount > 0

    @staticmethod
    def _write_conversion_identity_in(
        conn, uuid_id: str, identity, *, audio_unchanged: bool,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> bool:
        """SC-16a primitive: store the identity a conversion computed. UPDATE only
        (False if there is no row). Bumps ``generation``, keeps the fingerprint
        when the audio is unchanged (except a print failed only with the exact
        hash, which is re-pended), else re-pends it unless 'unavailable'; and
        sends the match back to pending. A fingerprint carried by ``identity`` is
        ignored (``_identity_column_values`` returns identity columns only). When
        the stored exact state is 'unsupported' the track's open exact pairs are
        removed in the same transaction (dismissed pairs stay). The old stat
        snapshot described the old master: it is replaced by ``stat`` (the new
        master's, stored only when an identity value is written), else NULL."""
        values = DatabaseCore._identity_column_values(identity)
        values.update(match_state="pending", priority=0, attempts=0, next_attempt_at=None)
        values.update(DatabaseCore._stat_columns(values["exact_state"], stat))
        sets = [f"{n} = ?" for n in values]
        if not audio_unchanged:
            sets.append("fp_state = CASE WHEN fp_state = 'unavailable' THEN fp_state ELSE 'pending' END")
        else:
            # DEV-6.5-12: a print failed only because the exact hash could not be made
            # (stored exact 'failed', or 'pending' again after a tag-edit mark) is retried
            # now that a current exact hash is written, as the worker's own exact compute
            # would (``_fp_after_exact``). SET reads the old row, so exact_state is the
            # stored one. A print that failed on its own (exact 'current') is kept.
            sets.append(
                "fp_state = CASE WHEN fp_state = 'failed' AND exact_state IN ('failed', 'pending') "
                "THEN 'pending' ELSE fp_state END"
            )
        cursor = conn.execute(
            f"UPDATE track_audio_identity SET generation = generation + 1, {', '.join(sets)} "
            "WHERE uuid_id = ?",
            (*values.values(), uuid_id),
        )
        if cursor.rowcount > 0 and values["exact_state"] in EXACT_NOT_COMPARABLE_STATES:
            DatabaseCore._drop_open_pairs_in(conn, uuid_id, "exact")
        return cursor.rowcount > 0

    _FINGERPRINT_WRITE_STATES = frozenset({"current", "low_information", "too_short", "failed"})

    @classmethod
    def _check_fingerprint(cls, fp: Mapping[str, Any]) -> None:
        """ValueError unless ``fp`` is a writable fingerprint-layer result."""
        state = fp.get("fp_state")
        if state not in cls._FINGERPRINT_WRITE_STATES:
            raise ValueError(f"fp_state not writable: {state!r}")
        if not fp.get("fp_algorithm"):
            raise ValueError("fingerprint needs fp_algorithm")
        if state in ("current", "low_information"):
            duration = fp.get("fp_duration_s")
            if (not fp.get("fp_backend") or not isinstance(fp.get("fp_data"), (bytes, bytearray))
                    or fp.get("fp_item_count") is None
                    or isinstance(duration, bool) or not isinstance(duration, (int, float))
                    or not duration > 0):
                raise ValueError("malformed fingerprint")

    @classmethod
    def _write_fingerprint_in(cls, conn, uuid_id: str, fp: Mapping[str, Any]) -> None:
        """Validate, then write the identity row's fp_state/fp_algorithm (and
        match_state = 'pending' when the state is 'current') and the
        track_audio_fingerprint row, on ``conn`` (the caller's transaction). A
        state of too_short or low_information also removes the track's open
        fingerprint pairs; a failed print (unknown) keeps them. Dismissed pairs
        stay, and matching recreates open ones if the print becomes current again."""
        cls._check_fingerprint(fp)
        state = fp["fp_state"]
        conn.execute(
            "UPDATE track_audio_identity SET fp_state = ?, fp_algorithm = ?, "
            "match_state = CASE WHEN ? = 'current' THEN 'pending' ELSE match_state END WHERE uuid_id = ?",
            (state, fp["fp_algorithm"], state, uuid_id),
        )
        if state in ("current", "low_information"):
            conn.execute(
                "INSERT INTO track_audio_fingerprint (uuid_id, backend, algorithm, duration_s, item_count, data) "
                "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(uuid_id) DO UPDATE SET backend = excluded.backend, "
                "algorithm = excluded.algorithm, duration_s = excluded.duration_s, "
                "item_count = excluded.item_count, data = excluded.data",
                (uuid_id, fp["fp_backend"], fp["fp_algorithm"], float(fp["fp_duration_s"]),
                 fp["fp_item_count"], bytes(fp["fp_data"])),
            )
        else:
            conn.execute("DELETE FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,))
        if state in FINGERPRINT_NOT_COMPARABLE_STATES:
            cls._drop_open_pairs_in(conn, uuid_id, "fingerprint")

    @staticmethod
    def _delete_cover_art_if_unreferenced_in(conn, cover_art_id: int) -> bool:
        cursor = conn.execute(
            "DELETE FROM cover_arts WHERE id = ? AND NOT EXISTS "
            "(SELECT 1 FROM trackmetadata WHERE cover_art_id = ?)",
            (cover_art_id, cover_art_id),
        )
        return cursor.rowcount > 0

    def _insert_track_in(
        self, conn, track: Track, *, owner_id: int, fingerprinter_present: bool,
        stat: Optional[tuple[int, int, int]],
    ) -> int:
        """Insert a track and its dependent rows inside the caller's transaction.

        Never opens, commits, rolls back or closes a connection; raises on any
        failure. Returns the allocated revision.
        """
        _require_owner(owner_id)
        metadata = track.metadata

        artist_id, album_id = self._upsert_identity(
            conn, owner_id, metadata.artist, metadata.album, metadata.album_artist,
            metadata.year,
        )
        self._assert_parents_owned(conn, owner_id, artist_id, album_id)

        # Clear the owner's own stale tombstone so a re-added uuid is not also
        # streamed as a delete; the fresh row's higher revision would
        # supersede it anyway, but dropping it keeps the stream clean.
        # Never another user's tombstone: that one is theirs.
        conn.execute(
            "DELETE FROM track_tombstones WHERE uuid_id = ? AND owner_id = ?",
            (track.uuid_id, owner_id),
        )

        # Insert track with a freshly allocated monotonic revision.
        revision = self._next_revision(conn)
        track.revision = revision
        track.owner_id = owner_id
        tracks_entry = (
            track.uuid_id,
            *track_path_values(track.file_path),
            track.created_at,
            track.last_updated,
            revision,
            owner_id,
        )
        tracks_sql_query = (
            "INSERT INTO tracks "
            "(uuid_id, file_path, file_path_fold, file_folder_fold, created_at, last_updated, "
            "revision, owner_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        )
        try:
            temp = conn.cursor().execute(tracks_sql_query, tracks_entry)
        except sqlite3.IntegrityError as e:
            if _is_taken_path(e):
                raise TrackPathTaken(track.uuid_id) from e
            raise
        track_db_id = temp.lastrowid

        # The write lock is held now: the art row cannot vanish between
        # this check and the commit.
        if metadata.cover_art_id is not None and conn.execute(
            "SELECT 1 FROM cover_arts WHERE id = ?", (metadata.cover_art_id,)
        ).fetchone() is None:
            raise CoverArtGone(metadata.cover_art_id)

        # Insert trackmetadata
        trackmetadata_entry = (
            track_db_id,
            track.uuid_id,
            metadata.title,
            metadata.artist,
            metadata.album,
            metadata.album_artist,
            artist_id,
            album_id,
            metadata.year,
            metadata.date,
            metadata.genre,
            metadata.track_number,
            metadata.disc_number,
            metadata.codec,
            metadata.duration,
            metadata.bitrate_kbps,
            metadata.sample_rate_hz,
            metadata.channels,
            metadata.has_album_art,
            metadata.cover_art_id,
        )
        trackmetadata_sql_query = (
            "INSERT INTO trackmetadata (track_id, uuid_id, title, artist, album, album_artist, "
            'artist_id, album_id, "year", "date", genre, track_number, disc_number, codec, duration, '
            "bitrate_kbps, sample_rate_hz, channels, has_album_art, cover_art_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        )
        conn.cursor().execute(trackmetadata_sql_query, trackmetadata_entry)

        self._fts_add_track_in(
            conn, track_db_id,
            metadata.title, metadata.artist, metadata.album, metadata.album_artist,
        )

        self._insert_audio_identity_in(
            conn, track.uuid_id, track.audio_identity,
            fingerprinter_present=fingerprinter_present,
            stat=stat,
        )
        return revision

    @staticmethod
    def _assert_parents_owned(conn, owner_id: int, artist_id, album_id) -> None:
        """Raise OwnerMismatch unless the linked artist/album belong to owner_id."""
        if artist_id is not None and conn.execute(
            "SELECT 1 FROM artists WHERE id = ? AND owner_id = ?",
            (artist_id, owner_id),
        ).fetchone() is None:
            raise OwnerMismatch(f"artist {artist_id} is not owned by {owner_id}")
        if album_id is not None and conn.execute(
            "SELECT 1 FROM albums JOIN artists ON artists.id = albums.artist_id "
            "WHERE albums.id = ? AND artists.owner_id = ?",
            (album_id, owner_id),
        ).fetchone() is None:
            raise OwnerMismatch(f"album {album_id} is not owned by {owner_id}")

    def _upsert_identity(
        self, conn, owner_id: int, artist: Optional[str], album: Optional[str],
        album_artist: Optional[str], year: Optional[int],
    ) -> tuple[Optional[int], Optional[int]]:
        """The ids of the artist and album rows a track with these tags belongs
        to, each created when new. Both None when the track has no artist (an
        album row requires one)."""
        effective, album_name = _library_identity(artist, album, album_artist)
        if effective is None:
            return None, None
        artist_id = self._upsert_artist(conn, effective, owner_id)
        album_id = self._upsert_album(conn, album_name, artist_id, year, effective)
        return artist_id, album_id

    def _upsert_artist(self, conn, effective_artist: str, owner_id: int) -> int:
        conn.execute(
            'INSERT OR IGNORE INTO artists ("name", "owner_id") VALUES (?, ?)',
            (effective_artist, owner_id),
        )
        was_new_artist = conn.execute("SELECT changes()").fetchone()[0] > 0
        row = conn.execute(
            "SELECT id FROM artists WHERE owner_id = ? AND name_lower = LOWER(?)",
            (owner_id, effective_artist),
        ).fetchone()
        artist_id = row["id"]

        if was_new_artist:
            conn.execute(
                "INSERT INTO fts_artists(rowid, name) VALUES (?, ?)",
                (artist_id, effective_artist),
            )

        return artist_id

    def _upsert_album(
        self, conn, album_name: str | None, artist_id: int, year: int | None, effective_artist: str
    ) -> int:
        if album_name is not None:
            # Regular album
            conn.execute(
                'INSERT OR IGNORE INTO albums ("name", "artist_id", "year", "is_single_grouping") '
                "VALUES (?, ?, ?, 0)",
                (album_name, artist_id, year),
            )
            was_new_album = conn.execute("SELECT changes()").fetchone()[0] > 0
            # Update year if new track's year is higher
            conn.execute(
                "UPDATE albums SET year = ? "
                "WHERE name_lower = LOWER(?) AND artist_id = ? AND is_single_grouping = 0 "
                "AND (year IS NULL OR year < ?)",
                (year, album_name, artist_id, year),
            )
            row = conn.execute(
                "SELECT id FROM albums WHERE name_lower = LOWER(?) AND artist_id = ? AND is_single_grouping = 0",
                (album_name, artist_id),
            ).fetchone()
            album_id = row["id"]

            if was_new_album:
                conn.execute(
                    "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (?, ?, ?)",
                    (album_id, album_name, effective_artist),
                )
        else:
            # Single grouping
            conn.execute(
                'INSERT OR IGNORE INTO albums ("name", "artist_id", "year", "is_single_grouping") '
                "VALUES (NULL, ?, ?, 1)",
                (artist_id, year),
            )
            was_new_album = conn.execute("SELECT changes()").fetchone()[0] > 0
            row = conn.execute(
                "SELECT id FROM albums WHERE artist_id = ? AND COALESCE(year, -1) = COALESCE(?, -1) AND is_single_grouping = 1",
                (artist_id, year),
            ).fetchone()
            album_id = row["id"]

            if was_new_album:
                conn.execute(
                    "INSERT INTO fts_albums(rowid, name, artist_name) VALUES (?, ?, ?)",
                    (album_id, "", effective_artist),
                )

        return album_id

    @staticmethod
    def _orphan_gc_album(conn, album_id: Optional[int]) -> None:
        """Delete ``album_id`` and its FTS row iff no trackmetadata references
        it. The FTS ``'delete'`` values are derived from the album's own
        artist join, so they always match what ``_upsert_album`` inserted."""
        if album_id is None:
            return
        remaining = conn.execute(
            "SELECT COUNT(*) FROM trackmetadata WHERE album_id = ?", (album_id,)
        ).fetchone()[0]
        if remaining != 0:
            return
        DatabaseCore._fts_delete_album_in(conn, album_id)
        conn.execute("DELETE FROM albums WHERE id = ?", (album_id,))

    @staticmethod
    def _fts_delete_album_in(conn, album_id: int) -> None:
        row = conn.execute(
            "SELECT a.name AS album_name, ar.name AS artist_name "
            "FROM albums a JOIN artists ar ON ar.id = a.artist_id "
            "WHERE a.id = ?",
            (album_id,),
        ).fetchone()
        album_name = (row["album_name"] or "") if row else ""
        artist_name = (row["artist_name"] or "") if row else ""
        conn.execute(
            "INSERT INTO fts_albums(fts_albums, rowid, name, artist_name) "
            "VALUES('delete', ?, ?, ?)",
            (album_id, album_name, artist_name),
        )

    @staticmethod
    def _orphan_gc_artist(conn, artist_id: Optional[int]) -> None:
        """Delete ``artist_id`` and its FTS row iff no trackmetadata references
        it. Call after ``_orphan_gc_album`` — an album row references an artist."""
        if artist_id is None:
            return
        remaining = conn.execute(
            "SELECT COUNT(*) FROM trackmetadata WHERE artist_id = ?", (artist_id,)
        ).fetchone()[0]
        if remaining != 0:
            return
        DatabaseCore._fts_delete_artist_in(conn, artist_id)
        conn.execute("DELETE FROM artists WHERE id = ?", (artist_id,))

    @staticmethod
    def _fts_delete_artist_in(conn, artist_id: int) -> None:
        row = conn.execute(
            "SELECT name FROM artists WHERE id = ?", (artist_id,)
        ).fetchone()
        artist_name = (row["name"] or "") if row else ""
        conn.execute(
            "INSERT INTO fts_artists(fts_artists, rowid, name) VALUES('delete', ?, ?)",
            (artist_id, artist_name),
        )

    def make_durable(self, *, timeout: float = 1) -> bool:
        """True only when every transaction committed before this call is in
        the database file and that file was synced (OPEN-8-01 part B). A reader
        on an older snapshot or a writer that outlasts ``timeout`` answers
        False (a FULL checkpoint holds the write lock while it waits for
        readers; the next pass retries). Exceptions propagate.

        The flush is SQLite's own, on its own descriptors. A checkpoint that
        copies the last frames syncs the database file with its connection's
        settings, and every connection ``open_connection`` makes has
        synchronous=FULL and fullfsync=ON. When nothing is left to copy, the
        checkpoint that copied the last frames (an automatic one, or a last
        connection's close) did that sync, and each commit was flushed when it
        returned. That holds while only this product's connections write to
        the database: a checkpoint by an outside program syncs with that
        program's settings.

        This method must never open a descriptor of its own on the database
        file or its -wal or -shm file: closing one drops every lock the
        process holds on that file (SQLite, "How To Corrupt An SQLite Database
        File", section 2.2), and with the held connection they would not come
        back (audit AU3-01)."""
        with self._connection(timeout=timeout) as conn:
            conn.execute("PRAGMA fullfsync=ON")
            busy, log, checkpointed = conn.execute("PRAGMA wal_checkpoint(FULL)").fetchone()
        return busy == 0 and log >= 0 and log == checkpointed

    @staticmethod
    def _fts_add_track_in(conn, track_db_id: int, title, artist, album, album_artist) -> None:
        conn.execute(
            "INSERT INTO fts_tracks(rowid, title, artist_name, album_name) VALUES (?, ?, ?, ?)",
            (track_db_id, *_track_search_text(title, artist, album, album_artist)),
        )

    @staticmethod
    def _fts_delete_track_in(conn, meta_row) -> None:
        """Remove a track's ``fts_tracks`` row. ``meta_row`` holds the stored
        track_id, title, artist, album and album_artist."""
        conn.execute(
            "INSERT INTO fts_tracks(fts_tracks, rowid, title, artist_name, album_name) "
            "VALUES('delete', ?, ?, ?, ?)",
            (
                meta_row["track_id"],
                *_track_search_text(
                    meta_row["title"], meta_row["artist"], meta_row["album"],
                    meta_row["album_artist"],
                ),
            ),
        )

    def _delete_track_in(self, conn, uuid_id: str, *, owner_id: int) -> int:
        """Delete the owner's track inside the caller's transaction.

        Runs inside the caller's ``BEGIN IMMEDIATE``; never opens, commits,
        rolls back or closes a connection. Records a tombstone (a plain INSERT,
        never a replace, so an existing tombstone is not re-bumped), deletes
        trackmetadata/tracks/FTS rows and prunes orphaned album/artist parents.
        Returns the tombstone revision. Does not touch ``deletion_journal``.

        Raises ``TrackAlreadyDeleted(uuid, revision)`` when the owner's own
        tombstone exists for the uuid, and ``TrackNotFound`` otherwise when no
        live track of this owner has it (an unknown uuid, another user's live
        track and another user's tombstone are indistinguishable). Nothing is
        written in either case.

        The deletion worker must hold the track's ``TrackLocks`` lock (lock
        order: track -> directory -> DB).
        """
        _require_owner(owner_id)
        # Fetch metadata before deletion for FTS cleanup
        meta_row = conn.execute(
            "SELECT tm.track_id, tm.artist_id, tm.album_id, tm.title, "
            "tm.artist, tm.album, tm.album_artist "
            "FROM trackmetadata tm JOIN tracks t ON t.uuid_id = tm.uuid_id "
            "WHERE tm.uuid_id = ? AND t.owner_id = ?",
            (uuid_id, owner_id),
        ).fetchone()

        if meta_row is None:
            tomb = conn.execute(
                "SELECT revision FROM track_tombstones "
                "WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone()
            if tomb is not None:
                raise TrackAlreadyDeleted(uuid_id, tomb["revision"])
            raise TrackNotFound(uuid_id)

        artist_id = meta_row["artist_id"]
        album_id = meta_row["album_id"]

        # Record a tombstone before the hard delete so incremental
        # sync clients can reconcile the removal — the row is about to
        # vanish from `tracks`/`trackmetadata`, leaving the frontend no
        # other signal that it ever existed.
        revision = self._next_revision(conn)
        conn.execute(
            "INSERT INTO track_tombstones "
            "(uuid_id, deleted_at, revision, owner_id) "
            "VALUES (?, unixepoch(), ?, ?)",
            (uuid_id, revision, owner_id),
        )

        # Delete trackmetadata and tracks
        conn.execute("DELETE FROM trackmetadata WHERE uuid_id = ?", (uuid_id,))
        conn.execute("DELETE FROM tracks WHERE uuid_id = ?", (uuid_id,))

        # Delete from FTS for tracks
        self._fts_delete_track_in(conn, meta_row)

        # Cleanup now-orphaned parents (album before artist — an album
        # row references an artist). Shared with the metadata-edit
        # spine so add/update/delete reconcile orphans one way.
        self._orphan_gc_album(conn, album_id)
        self._orphan_gc_artist(conn, artist_id)
        return revision
