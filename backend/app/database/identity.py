"""Audio identity rows, the identity worker's queue, duplicate candidates.

One part of ``Database`` (``app/database/database.py``). It imports the shared
core and never another part.
"""

import logging
from typing import Any, Callable, List, Mapping, Optional

from app.core.owner import ANY_OWNER, Owner, _require_owner
from app.database.core import (
    DatabaseCore,
    EXACT_NOT_COMPARABLE_STATES,
    FINGERPRINT_NOT_COMPARABLE_STATES,
)

# The log name is the one these lines had in database.py.
logger = logging.getLogger("app.database.database")

MATCHER_VERSION_SETTING = "matcher_version"
FINGERPRINT_DURATION_RULE_SETTING = "fingerprint_duration_rule"
FINGERPRINT_CLASSIFIER_VERSION_SETTING = "fingerprint_classifier_version"


class IdentityPart(DatabaseCore):
    """The ``track_audio_identity``, ``track_audio_fingerprint`` and
    ``track_duplicate_candidates`` rows: the worker's queue and compare-and-set
    writes, the candidate store and its reads, the start-up reconcile. The
    primitives that other domains run inside their transactions are in the core."""

    @staticmethod
    def _requeue_match_in(conn, uuid_ids) -> int:
        """Send these tracks' matching back to pending on the caller's
        connection (never commits). Only ``match_state`` changes, and only on
        rows not already pending: the audio bytes did not change, so nothing is
        re-hashed. Returns the number of rows requeued."""
        uuid_ids = list(uuid_ids)
        if not uuid_ids:
            return 0
        return conn.execute(
            "UPDATE track_audio_identity SET match_state = 'pending' "
            f"WHERE match_state <> 'pending' AND uuid_id IN ({', '.join('?' * len(uuid_ids))})",
            uuid_ids,
        ).rowcount

    def mark_audio_identity_stale(self, uuid_id: str, reason: str, *, owner_id: int) -> bool:
        """Owner-scoped mark; used by the in-place edit after ``os.replace`` and by
        journal recovery. False (nothing changed) for a track the owner lacks."""
        _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            if conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone() is None:
                return False
            return self._mark_audio_identity_stale_in(conn, uuid_id, reason)

    def write_conversion_identity(
        self, uuid_id: str, identity, *, audio_unchanged: bool = False, owner_id: int,
        stat: Optional[tuple[int, int, int]] = None,
    ) -> bool:
        """Owner-scoped short transaction for the in-place conversion, after
        ``os.replace``; ``stat`` is the new master's snapshot. False (nothing
        changed) for a track the owner lacks."""
        _require_owner(owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            if conn.execute(
                "SELECT 1 FROM tracks WHERE uuid_id = ? AND owner_id = ?",
                (uuid_id, owner_id),
            ).fetchone() is None:
                return False
            return self._write_conversion_identity_in(
                conn, uuid_id, identity, audio_unchanged=audio_unchanged, stat=stat
            )

    def get_audio_identity(self, uuid_id: str, *, owner_id: int) -> Optional[dict]:
        """The ``track_audio_identity`` row as a dict, for a track the owner owns."""
        _require_owner(owner_id)
        with self._connection() as conn:
            cursor = conn.execute(
                "SELECT i.* FROM track_audio_identity i JOIN tracks t ON t.uuid_id = i.uuid_id "
                "WHERE i.uuid_id = ? AND t.owner_id = ?",
                (uuid_id, owner_id),
            )
            row = cursor.fetchone()
            if row is None:
                return None
            return dict(zip([d[0] for d in cursor.description], tuple(row)))

    # Columns the identity worker may write; never generation, priority or match_state.
    _IDENTITY_WORKER_COLUMNS = frozenset({
        "exact_state", "exact_kind", "exact_digest", "sample_rate_hz", "channels",
        "bits_per_sample", "fp_state", "failure_reason", "attempts", "next_attempt_at",
        "stat_size", "stat_mtime_ns", "stat_inode", "computed_at", "tool_versions",
    })

    # Work is: (a) a due pending exact layer; (b) only for the fingerprint variant, a due pending
    # fingerprint whose exact layer is settled (current/unsupported; a failed exact
    # never queues its fingerprint); (c) pending matching once exact is not pending,
    # NOT gated by next_attempt_at (that backoff belongs to the exact/fingerprint
    # layer and never holds back matching). ORDER BY follows idx_tai_work
    # (priority, next_attempt_at); rows never backed off (NULL) keep rowid order,
    # due retries follow them.
    _IDENTITY_QUEUE_SQL_TEMPLATE = (
        "SELECT uuid_id, generation FROM track_audio_identity i "
        "WHERE ((exact_state = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?1)) "
        "OR (FP_CLAUSE fp_state = 'pending' AND exact_state IN ('current', 'unsupported') "
        "AND (next_attempt_at IS NULL OR next_attempt_at <= ?1)) "
        "OR (match_state = 'pending' AND exact_state <> 'pending')) "
        # Redundant; it states idx_tai_work's own predicate so the planner may use it.
        "AND (exact_state = 'pending' OR fp_state = 'pending' OR match_state = 'pending') "
        "AND NOT EXISTS (SELECT 1 FROM edit_journal j WHERE j.uuid_id = i.uuid_id) "
        "AND EXISTS (SELECT 1 FROM live_tracks lt WHERE lt.uuid_id = i.uuid_id) "
        # A user being deleted gets no more work.
        "AND NOT EXISTS (SELECT 1 FROM tracks t JOIN users u ON u.id = t.owner_id "
        "WHERE t.uuid_id = i.uuid_id AND u.deleting_at IS NOT NULL) "
        "ORDER BY priority, next_attempt_at, rowid"
    )

    # Two fixed texts (one bound parameter, ?1 = now): without a fingerprinter the
    # fingerprint branch is constant false.
    _IDENTITY_QUEUE_SQL = _IDENTITY_QUEUE_SQL_TEMPLATE.replace("FP_CLAUSE", "0 = 1 AND")

    _IDENTITY_QUEUE_FP_SQL = _IDENTITY_QUEUE_SQL_TEMPLATE.replace("FP_CLAUSE", "1 = 1 AND")

    def next_identity_work(
        self, now: int, *, skip: Mapping[str, int], owner_id: Owner, fingerprint: bool = False
    ) -> Optional[str]:
        """The next due uuid by (priority, rowid), skipping any with an edit_journal
        row or a pending deletion (not in live_tracks) and any in ``skip``
        (uuid -> generation) while its generation still matches. Pending
        fingerprints count as work only when ``fingerprint`` is true (see
        ``_IDENTITY_QUEUE_SQL``). The queue spans every owner, so only
        ANY_OWNER is accepted."""
        if owner_id is not ANY_OWNER:
            raise TypeError("next_identity_work requires owner_id=ANY_OWNER")
        with self._connection() as conn:
            cursor = conn.execute(
                self._IDENTITY_QUEUE_FP_SQL if fingerprint else self._IDENTITY_QUEUE_SQL, (now,)
            )
            for uuid_id, generation in cursor:
                if skip.get(uuid_id) != generation:
                    return uuid_id
            return None

    def get_identity_subject(self, uuid_id: str, *, owner_id: Owner) -> Optional[dict]:
        """Identity row joined with its track's owner, path and codec, for any owner."""
        if owner_id is not ANY_OWNER:
            raise TypeError("get_identity_subject requires owner_id=ANY_OWNER")
        with self._connection() as conn:
            row = conn.execute(
                "SELECT i.uuid_id, t.owner_id, i.generation, t.file_path, m.codec, "
                "i.exact_state, i.exact_kind, i.exact_digest, i.fp_state, i.attempts, "
                "i.match_state, i.sample_rate_hz, i.channels, i.bits_per_sample, "
                "i.next_attempt_at, i.fp_algorithm, m.duration AS duration "
                "FROM track_audio_identity i JOIN tracks t ON t.uuid_id = i.uuid_id "
                "LEFT JOIN trackmetadata m ON m.uuid_id = i.uuid_id WHERE i.uuid_id = ?",
                (uuid_id,),
            ).fetchone()
            return dict(row) if row is not None else None

    def update_identity_if_unchanged(
        self,
        uuid_id: str,
        *,
        generation: int,
        file_path: str,
        values: Mapping[str, Any],
        verify: Optional[Callable[[], bool]] = None,
        owner_id: int,
        fingerprint: Optional[Mapping[str, Any]] = None,
    ) -> bool:
        """The worker's compare-and-set write: one transaction that writes ``values``
        only if the row still has ``generation``, the track still has this owner and
        path, no edit_journal row exists, the track is not pending deletion (refused
        like an edit journal), and ``verify()`` (run inside the
        transaction) is true. Otherwise changes nothing and returns False.

        ``fingerprint`` (optional) is the fingerprint layer's result, a mapping
        with the ``audio_identity.FINGERPRINT_COLUMNS`` keys (fp_state is one of
        current, low_information, too_short, failed). It is validated before
        anything is written, then written in the same transaction: the identity
        row's fp_state and fp_algorithm, ``match_state = 'pending'`` only when
        fp_state is 'current', and the ``track_audio_fingerprint`` row (upsert
        for current/low_information with duration_s > 0, deleted for
        too_short/failed). ``values`` may then be empty but must not contain
        fp_state. Any database error rolls the whole write back.

        Layers that settle as not comparable drop the track's open duplicate
        pairs of that kind in the same transaction: exact 'unsupported' in
        ``values`` drops exact pairs; a fingerprint of too_short or
        low_information drops fingerprint pairs. A failed layer (unknown) keeps
        its pairs. Dismissed pairs are kept."""
        _require_owner(owner_id)
        unknown = set(values) - self._IDENTITY_WORKER_COLUMNS
        if unknown or (not values and fingerprint is None):
            raise ValueError(f"not writable by the identity worker: {sorted(unknown)}")
        if fingerprint is not None:
            if "fp_state" in values:
                raise ValueError("fp_state must come from fingerprint, not values")
            self._check_fingerprint(fingerprint)
        with self._connection(commit=True, immediate=True) as conn:
            current = conn.execute(
                "SELECT 1 FROM track_audio_identity i JOIN live_tracks t ON t.uuid_id = i.uuid_id "
                "WHERE i.uuid_id = ? AND i.generation = ? AND t.owner_id = ? AND t.file_path = ? "
                "AND NOT EXISTS (SELECT 1 FROM edit_journal j WHERE j.uuid_id = i.uuid_id)",
                (uuid_id, generation, owner_id, file_path),
            ).fetchone()
            if current is None or (verify is not None and not verify()):
                return False
            if values:
                assignments = ", ".join(f"{column} = ?" for column in values)
                conn.execute(
                    f"UPDATE track_audio_identity SET {assignments} WHERE uuid_id = ?",
                    (*values.values(), uuid_id),
                )
                if values.get("exact_state") in EXACT_NOT_COMPARABLE_STATES:
                    self._drop_open_pairs_in(conn, uuid_id, "exact")
            if fingerprint is not None:
                self._write_fingerprint_in(conn, uuid_id, fingerprint)
            return True

    def find_duplicates_for_track(self, uuid_id: str, identity, *, owner_id: int):
        """The worker's read: the matches of one library track against its owner's
        live library, uncapped, excluding the track itself; the matches only,
        without the coverage counts. ``owner_id`` is the track's real owner, never
        ANY_OWNER."""
        # Local import: app.services' package init imports this module (cycle).
        from app.services import duplicate_detection

        owner = _require_owner(owner_id)
        with self._connection() as conn:
            return duplicate_detection.find_matches(
                conn, identity, owner_id=owner, exclude=frozenset({uuid_id})
            )

    def get_identity_fingerprint(self, uuid_id: str, *, owner_id: int):
        """The stored print of one of ``owner_id``'s tracks as a ``FingerprintIdentity``.

        ``owner_id`` is a real owner, never ANY_OWNER. Returns None when the
        track has no fingerprint row or is not that owner's. The state is the
        identity row's ``fp_state``; the rest comes from the fingerprint row.
        """
        # Local imports: app.services' package init imports this module (cycle).
        from app.services.audio_identity import FingerprintIdentity
        from app.services.fingerprinter import unpack_fingerprint

        owner = _require_owner(owner_id)
        with self._connection() as conn:
            row = conn.execute(
                "SELECT i.fp_state, f.backend, f.algorithm, f.duration_s, f.data "
                "FROM track_audio_fingerprint f "
                "JOIN track_audio_identity i ON i.uuid_id = f.uuid_id "
                "JOIN tracks t ON t.uuid_id = f.uuid_id "
                "WHERE f.uuid_id = ? AND t.owner_id = ?",
                (uuid_id, owner),
            ).fetchone()
        if row is None:
            return None
        return FingerprintIdentity(row[0], row[1], row[2], row[3], unpack_fingerprint(row[4]))

    # The store's delete rule: this track's open exact pairs whose partner is a
    # live, exact-current track of the same owner (?1 = uuid, ?2 = owner).
    # The unary plus on status/owner_id disables idx_tdc_list for them, so SQLite uses
    # the primary key (uuid_a) and idx_tdc_b instead of reading every open pair of the
    # owner inside the write lock. Semantics are unchanged.
    _CANDIDATE_PARTNERS_SQL = (
        "SELECT c.uuid_a, c.uuid_b, i.exact_kind, i.exact_digest, "
        "i.sample_rate_hz, i.channels, i.bits_per_sample "
        "FROM track_duplicate_candidates c "
        "JOIN live_tracks lt ON lt.uuid_id = CASE WHEN c.uuid_a = ?1 THEN c.uuid_b ELSE c.uuid_a END "
        "JOIN track_audio_identity i ON i.uuid_id = lt.uuid_id "
        "WHERE (c.uuid_a = ?1 OR c.uuid_b = ?1) AND +c.status = 'open' AND c.kind = 'exact' "
        "AND +c.owner_id = ?2 AND lt.owner_id = ?2 AND i.exact_state = 'current'"
    )

    # The fingerprint twin of the rule above (?1 = uuid, ?2 = owner, ?3 = the subject's
    # print algorithm): open fingerprint pairs whose partner is a live same-owner track,
    # fp-'current' with a stored print of that algorithm. Same index steering.
    _FINGERPRINT_PARTNERS_SQL = (
        "SELECT c.uuid_a, c.uuid_b, lt.uuid_id "
        "FROM track_duplicate_candidates c "
        "JOIN live_tracks lt ON lt.uuid_id = CASE WHEN c.uuid_a = ?1 THEN c.uuid_b ELSE c.uuid_a END "
        "JOIN track_audio_identity i ON i.uuid_id = lt.uuid_id "
        "JOIN track_audio_fingerprint f ON f.uuid_id = lt.uuid_id "
        "WHERE (c.uuid_a = ?1 OR c.uuid_b = ?1) AND +c.status = 'open' AND c.kind = 'fingerprint' "
        "AND +c.owner_id = ?2 AND lt.owner_id = ?2 AND i.fp_state = 'current' AND f.algorithm = ?3"
    )

    def store_duplicate_candidates(
        self,
        uuid_id: str,
        *,
        generation: int,
        exact_state: str,
        fp_state: str,
        matches,
        matcher_version: str,
        now: int,
        owner_id: int,
    ) -> bool:
        """Store one subject track's duplicate matches (the worker's matching step).

        Opens its own immediate transaction. It writes only if the subject's
        identity row is unchanged since it was read: same ``generation``,
        ``exact_state`` and ``fp_state``, ``match_state`` still 'pending', the
        track belongs to ``owner_id``, is live (no deletion journal) and has no
        ``edit_journal`` row. Otherwise it returns False
        and changes nothing.

        Each ``TrackRef`` match is upserted in canonical (min, max) uuid order.
        An existing row gets its kind, band, score and matcher version updated;
        ``status`` (e.g. dismissed) is never changed. A partner that is no
        longer a live track of the same owner is skipped. Tracks of different
        owners are never paired. ``StagedRef`` matches are ignored.

        When the subject is exact-'current', an open exact row is deleted only
        if the partner is a live same-owner track that is also exact-'current'
        and the two hashes no longer match (compared, did not match). Unknown
        is not 'no match': pending, failed, non-live or identity-less partners,
        dismissed rows and fingerprint rows are kept. Finally ``match_state``
        becomes 'current' and ``matcher_version`` is stored. Returns True.

        When the subject is fp-'current', an open fingerprint row is likewise
        deleted only if the partner is a live same-owner track that is
        fp-'current' with a print of the subject's algorithm and is absent from
        ``matches`` (``matches`` holds every current same-algorithm print in the
        duration window that matched, so an absent one was compared and did not
        match). Pending, failed, other-algorithm, non-live partners and
        dismissed rows are kept.

        Separately from this step, a track whose layer settles as not
        comparable (exact unsupported; fingerprint too_short or
        low_information) has its open pairs of that kind removed when
        that state is written; dismissed pairs are never removed that way.
        """
        owner = _require_owner(owner_id)
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import ExactAudioHash, exact_match
        from app.services.duplicate_detection import BAND_RANK, TrackRef

        with self._connection(commit=True, immediate=True) as conn:
            subject_row = conn.execute(
                "SELECT i.exact_kind, i.exact_digest, i.sample_rate_hz, i.channels, i.bits_per_sample, "
                "i.fp_algorithm "
                "FROM track_audio_identity i JOIN live_tracks t ON t.uuid_id = i.uuid_id "
                "WHERE i.uuid_id = ? AND i.generation = ? AND i.exact_state = ? "
                "AND i.fp_state = ? AND i.match_state = 'pending' AND t.owner_id = ? "
                "AND NOT EXISTS (SELECT 1 FROM edit_journal j WHERE j.uuid_id = i.uuid_id)",
                (uuid_id, generation, exact_state, fp_state, owner),
            ).fetchone()
            if subject_row is None:
                return False
            for match in matches:
                if not isinstance(match.subject, TrackRef) or match.subject.uuid_id == uuid_id:
                    continue
                partner = match.subject.uuid_id
                uuid_a, uuid_b = min(uuid_id, partner), max(uuid_id, partner)
                score = 1.0 if match.score is None else match.score
                conn.execute(
                    "INSERT INTO track_duplicate_candidates "
                    "(owner_id, uuid_a, uuid_b, kind, band_rank, sort_score, matcher_version, detected_at) "
                    "SELECT ?, ?, ?, ?, ?, ?, ?, ? "
                    "WHERE EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = ? AND owner_id = ?) "
                    "ON CONFLICT(uuid_a, uuid_b) DO UPDATE SET kind = excluded.kind, "
                    "band_rank = excluded.band_rank, sort_score = excluded.sort_score, "
                    "matcher_version = excluded.matcher_version",
                    (owner, uuid_a, uuid_b, match.kind, BAND_RANK[match.band], score,
                     matcher_version, now, partner, owner),
                )
            if exact_state == "current":
                subject = ExactAudioHash(*subject_row[:5])
                rows = conn.execute(self._CANDIDATE_PARTNERS_SQL, (uuid_id, owner)).fetchall()
                for row in rows:
                    if not exact_match(subject, ExactAudioHash(*row[2:])):
                        conn.execute(
                            "DELETE FROM track_duplicate_candidates WHERE uuid_a = ? AND uuid_b = ?",
                            (row[0], row[1]),
                        )
            if fp_state == "current":
                matched = {
                    m.subject.uuid_id for m in matches if isinstance(m.subject, TrackRef)
                }
                for a, b, partner in conn.execute(
                    self._FINGERPRINT_PARTNERS_SQL, (uuid_id, owner, subject_row[5])
                ).fetchall():
                    if partner not in matched:
                        conn.execute(
                            "DELETE FROM track_duplicate_candidates WHERE uuid_a = ? AND uuid_b = ?",
                            (a, b),
                        )
            conn.execute(
                "UPDATE track_audio_identity SET match_state = 'current', matcher_version = ? "
                "WHERE uuid_id = ?",
                (matcher_version, uuid_id),
            )
            return True

    def set_duplicate_candidate_status(
        self, uuid_a: str, uuid_b: str, status: str, *, owner_id: int
    ) -> bool:
        """Dismiss ('dismissed') or restore ('open') one duplicate pair.

        The pair may be given in either order. Only the owner's own pair of
        live tracks is found: a foreign or unknown pair is "not found" and
        returns False with nothing changed. Setting the status it already has
        returns True and writes nothing. Opens its own transaction.

        A restore that reopens a dismissed pair also sends both tracks'
        matching back to pending in the same transaction: the matcher never
        re-checks a dismissed pair, so it may be stale (a track changed while
        dismissed), and only a new match run removes or re-types it. The
        caller wakes the identity worker after the commit.

        The not-comparable rule (DEV-6.5-15) runs when a track's state is
        written and skips dismissed pairs, so a pair restored after one of its
        tracks became not comparable for the pair's kind is dropped here, in
        the same transaction (with that track's other open pairs of the kind).
        A track that becomes not comparable later is handled by the
        write-time rule.
        """
        if status not in ("open", "dismissed"):
            raise ValueError(f"status must be 'open' or 'dismissed', got {status!r}")
        owner = _require_owner(owner_id)
        a, b = min(uuid_a, uuid_b), max(uuid_a, uuid_b)
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT c.status, c.kind FROM track_duplicate_candidates c "
                "WHERE c.uuid_a = ? AND c.uuid_b = ? AND c.owner_id = ? "
                "AND EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = c.uuid_a AND owner_id = ?) "
                "AND EXISTS (SELECT 1 FROM live_tracks WHERE uuid_id = c.uuid_b AND owner_id = ?)",
                (a, b, owner, owner, owner),
            ).fetchone()
            if row is None:
                return False
            if row[0] != status:
                conn.execute(
                    "UPDATE track_duplicate_candidates SET status = ?, status_changed_at = unixepoch() "
                    "WHERE uuid_a = ? AND uuid_b = ?",
                    (status, a, b),
                )
                if status == "open":
                    self._requeue_match_in(conn, (a, b))
                    self._drop_restored_not_comparable_in(conn, (a, b), row[1])
            return True

    @staticmethod
    def _drop_restored_not_comparable_in(conn, uuid_ids, kind: str) -> None:
        """For a just-restored pair of ``kind``: each track whose layer of that
        kind is not comparable loses its open pairs of that kind (the pair
        included), on the caller's connection (never commits). A track without
        an identity row has nothing to drop."""
        column, not_comparable = {
            "exact": ("exact_state", EXACT_NOT_COMPARABLE_STATES),
            "fingerprint": ("fp_state", FINGERPRINT_NOT_COMPARABLE_STATES),
        }[kind]
        for uuid_id in uuid_ids:
            state = conn.execute(
                f"SELECT {column} FROM track_audio_identity WHERE uuid_id = ?", (uuid_id,)
            ).fetchone()
            if state is not None and state[0] in not_comparable:
                DatabaseCore._drop_open_pairs_in(conn, uuid_id, kind)

    def list_duplicate_candidates(
        self,
        *,
        owner_id: int,
        status: str,
        after: tuple[int, float, str, str] | None,
        limit: int,
    ) -> list[dict]:
        """One keyset page of the owner's duplicate pairs with the given status.

        Ordered by (band_rank, sort_score DESC, uuid_a, uuid_b); ``after`` is
        the last row's (band_rank, sort_score, uuid_a, uuid_b) and the page
        starts strictly after it. Returns at most ``limit`` rows. Both members
        join through ``live_tracks``, so a pair with a pending-deletion member
        is omitted. Each row carries both tracks' summaries (``file_path`` is
        for the service layer); a NULL audio property stays None.
        """
        owner = _require_owner(owner_id)
        params: dict[str, object] = {
            "owner": owner,
            "status": status,
            "min_band": after[0] if after is not None else 0,
            "limit": limit,
        }
        keyset = ""
        if after is not None:
            params.update(r=after[0], s=after[1], a=after[2], b=after[3])
            keyset = (
                "AND (c.band_rank > :r OR (c.band_rank = :r AND (c.sort_score < :s "
                "OR (c.sort_score = :s AND (c.uuid_a > :a OR (c.uuid_a = :a AND c.uuid_b > :b))))))"
            )

        def cols(p: str) -> str:
            return (
                f"t{p}.uuid_id AS {p}_uuid_id, t{p}.revision AS {p}_revision, "
                f"m{p}.title AS {p}_title, m{p}.artist AS {p}_artist, m{p}.album AS {p}_album, "
                f"m{p}.codec AS {p}_codec, m{p}.bitrate_kbps AS {p}_bitrate_kbps, "
                f"m{p}.sample_rate_hz AS {p}_sample_rate_hz, m{p}.channels AS {p}_channels, "
                f"m{p}.duration AS {p}_duration_s, t{p}.created_at AS {p}_added_at, "
                f"l{p}.file_path AS {p}_file_path"
            )

        def join(p: str) -> str:
            return (
                f"CROSS JOIN live_tracks l{p} ON l{p}.uuid_id = c.uuid_{p} AND l{p}.owner_id = c.owner_id "
                f"CROSS JOIN tracks t{p} ON t{p}.id = l{p}.id "
                f"LEFT JOIN trackmetadata m{p} ON m{p}.uuid_id = c.uuid_{p} "
            )

        sql = (
            "SELECT c.uuid_a, c.uuid_b, c.kind, c.band_rank, c.sort_score, c.detected_at, c.status, "
            f"{cols('a')}, {cols('b')} "
            f"FROM track_duplicate_candidates c {join('a')}{join('b')}"
            "WHERE c.owner_id = :owner AND c.status = :status AND c.band_rank >= :min_band "
            f"{keyset} "
            "ORDER BY c.band_rank, c.sort_score DESC, c.uuid_a, c.uuid_b LIMIT :limit"
        )
        with self._connection() as conn:
            rows = conn.execute(sql, params).fetchall()

        def side(row, p: str) -> dict:
            return {
                k: row[f"{p}_{k}"]
                for k in (
                    "uuid_id", "revision", "title", "artist", "album", "codec",
                    "bitrate_kbps", "sample_rate_hz", "channels", "duration_s",
                    "added_at", "file_path",
                )
            }

        return [
            {
                "uuid_a": r["uuid_a"],
                "uuid_b": r["uuid_b"],
                "kind": r["kind"],
                "band_rank": r["band_rank"],
                "sort_score": r["sort_score"],
                "detected_at": r["detected_at"],
                "status": r["status"],
                "track_a": side(r, "a"),
                "track_b": side(r, "b"),
            }
            for r in rows
        ]

    def count_duplicate_candidates(self, *, owner_id: int) -> dict:
        """Open/dismissed pair counts per band for one owner.

        Returns ``{band: {"open": n, "dismissed": n}}`` for every band, with a
        real 0 where there are no pairs. Both members join through
        ``live_tracks`` (same owner), so a pair with a pending-deletion member
        is not counted.
        """
        from app.services.duplicate_detection import BAND_RANK  # import cycle

        owner = _require_owner(owner_id)
        counts = {band: {"open": 0, "dismissed": 0} for band in BAND_RANK}
        band_of = {rank: band for band, rank in BAND_RANK.items()}
        with self._connection() as conn:
            rows = conn.execute(
                "SELECT c.band_rank, c.status, COUNT(*) FROM track_duplicate_candidates c "
                "CROSS JOIN live_tracks la ON la.uuid_id = c.uuid_a AND la.owner_id = c.owner_id "
                "CROSS JOIN live_tracks lb ON lb.uuid_id = c.uuid_b AND lb.owner_id = c.owner_id "
                "WHERE c.owner_id = ? GROUP BY c.band_rank, c.status",
                (owner,),
            ).fetchall()
        for rank, status, n in rows:
            counts[band_of[rank]][status] = n
        return counts

    def get_identity_coverage_summary(self, *, owner_id: int) -> dict:
        """Per-layer state counts over one owner's live tracks.

        Returns ``{"exact": {...}, "fingerprint": {...}, "match": {...}}`` with
        every state key present (a real 0 when none). ``exact``: pending,
        current, failed, unsupported. ``fingerprint``: pending, current,
        unavailable, too_short, low_information, failed. ``match``: pending,
        current. A live track with no identity row counts as pending in all
        three layers (unknown, never checked). The active fingerprinter is not
        part of this summary; the caller adds it from app state.
        """
        owner = _require_owner(owner_id)
        layers = {
            "exact": ("exact_state", ("pending", "current", "failed", "unsupported")),
            "fingerprint": (
                "fp_state",
                ("pending", "current", "unavailable", "too_short", "low_information", "failed"),
            ),
            "match": ("match_state", ("pending", "current")),
        }
        summary = {name: dict.fromkeys(states, 0) for name, (_, states) in layers.items()}
        with self._connection() as conn:
            for name, (column, _) in layers.items():
                for state, count in conn.execute(
                    f"SELECT COALESCE(i.{column}, 'pending'), COUNT(*) "
                    "FROM live_tracks lt LEFT JOIN track_audio_identity i ON i.uuid_id = lt.uuid_id "
                    "WHERE lt.owner_id = ? GROUP BY 1",
                    (owner,),
                ):
                    summary[name][state] = count
        return summary

    # --- identity startup reconcile (spec §6.4): maintenance over every owner's rows ---

    @staticmethod
    def _require_any_owner(method: str, owner_id: object) -> None:
        if owner_id is not ANY_OWNER:
            raise TypeError(f"{method} requires owner_id=ANY_OWNER")

    def insert_missing_identity_rows(self, *, fingerprinter_present: bool, owner_id: Owner) -> int:
        """A pending, priority-0 identity row for every track lacking one."""
        self._require_any_owner("insert_missing_identity_rows", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            return conn.execute(
                "INSERT INTO track_audio_identity "
                "(uuid_id, exact_state, fp_state, match_state, priority) "
                "SELECT uuid_id, 'pending', ?, 'pending', 0 FROM tracks t WHERE NOT EXISTS "
                "(SELECT 1 FROM track_audio_identity i WHERE i.uuid_id = t.uuid_id)",
                ("pending" if fingerprinter_present else "unavailable",),
            ).rowcount

    # attempts / next_attempt_at / failure_reason belong to the fingerprint layer only
    # while the exact layer is settled; otherwise they are the exact layer's.
    _FP_OWNS_ATTEMPTS = "exact_state IN ('current', 'unsupported')"

    _FP_RESET_ATTEMPTS_SQL = (
        f"attempts = CASE WHEN {_FP_OWNS_ATTEMPTS} THEN 0 ELSE attempts END, "
        f"next_attempt_at = CASE WHEN {_FP_OWNS_ATTEMPTS} THEN NULL ELSE next_attempt_at END, "
        f"failure_reason = CASE WHEN {_FP_OWNS_ATTEMPTS} THEN NULL ELSE failure_reason END"
    )

    # The worker never fingerprints a row whose exact layer failed (an unreadable
    # file), so reconcile marks such a print 'failed' (it is retried when the exact
    # layer is revived) instead of 'pending', which would strand it.
    _EXACT_FAILED = "exact_state = 'failed'"

    @classmethod
    def _print_again_state_sql(cls, fingerprinter_present: bool) -> str:
        """SQL value for the fp_state of a row whose print is to be computed again:
        'pending' (or 'failed' when its exact layer failed) with a fingerprinter,
        else 'unavailable'."""
        if not fingerprinter_present:
            return "'unavailable'"
        return f"CASE WHEN {cls._EXACT_FAILED} THEN 'failed' ELSE 'pending' END"

    @classmethod
    def _delete_failed_print_blobs(cls, conn, where: str, params: tuple) -> None:
        """A 'failed' print stores no blob: drop the fingerprint rows of the identity
        rows matching ``where`` (run BEFORE the UPDATE that changes their state)."""
        conn.execute(
            "DELETE FROM track_audio_fingerprint WHERE uuid_id IN "
            f"(SELECT uuid_id FROM track_audio_identity WHERE {where})",
            params,
        )

    def set_fingerprint_availability(
        self, present: bool, *, algorithm: Optional[str] = None, owner_id: Owner
    ) -> int:
        """With a fingerprinter 'unavailable' becomes 'pending' (rows whose exact layer
        failed, whether unavailable or pending, become 'failed' with ``algorithm``
        when it is given; without it they stay as they are); without one 'pending'
        becomes 'unavailable' (clearing the attempt columns where the fingerprint
        owns them). Stored prints are kept. Returns the rows changed."""
        self._require_any_owner("set_fingerprint_availability", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            if present:
                if algorithm is None:
                    return conn.execute(
                        "UPDATE track_audio_identity SET fp_state = 'pending' "
                        f"WHERE fp_state = 'unavailable' AND NOT ({self._EXACT_FAILED})"
                    ).rowcount
                self._delete_failed_print_blobs(
                    conn, f"{self._EXACT_FAILED} AND fp_state IN ('unavailable', 'pending')", ())
                return conn.execute(
                    f"UPDATE track_audio_identity SET fp_state = CASE WHEN {self._EXACT_FAILED} "
                    "THEN 'failed' ELSE 'pending' END, "
                    f"fp_algorithm = CASE WHEN {self._EXACT_FAILED} THEN ? ELSE fp_algorithm END "
                    f"WHERE fp_state = 'unavailable' OR (fp_state = 'pending' AND {self._EXACT_FAILED})",
                    (algorithm,),
                ).rowcount
            return conn.execute(
                f"UPDATE track_audio_identity SET fp_state = 'unavailable', {self._FP_RESET_ATTEMPTS_SQL} "
                "WHERE fp_state = 'pending'"
            ).rowcount

    def requeue_fingerprint_algorithm(self, algorithm: str, *, owner_id: Owner) -> int:
        """Send every stored print (current, too_short, low_information, failed) whose
        fp_algorithm differs from ``algorithm`` back to pending. A print leaving
        'current' re-queues matching in the same statement. A row whose exact layer
        failed becomes 'failed' with ``algorithm`` (no blob) instead of 'pending'."""
        self._require_any_owner("requeue_fingerprint_algorithm", owner_id)
        stale = "fp_state NOT IN ('pending', 'unavailable') AND fp_algorithm IS NOT ?"
        with self._connection(commit=True, immediate=True) as conn:
            self._delete_failed_print_blobs(conn, f"{self._EXACT_FAILED} AND {stale}", (algorithm,))
            return conn.execute(
                "UPDATE track_audio_identity SET "
                "match_state = CASE WHEN fp_state = 'current' THEN 'pending' ELSE match_state END, "
                f"fp_state = CASE WHEN {self._EXACT_FAILED} THEN 'failed' ELSE 'pending' END, "
                f"fp_algorithm = CASE WHEN {self._EXACT_FAILED} THEN ? ELSE fp_algorithm END, "
                f"{self._FP_RESET_ATTEMPTS_SQL} WHERE {stale}",
                (algorithm, algorithm),
            ).rowcount

    def requeue_matching(self, matcher_version: str, *, owner_id: Owner) -> int:
        """Re-match everything when the matcher version changed (spec 6.4 reconcile).

        If ``app_settings`` already holds ``matcher_version`` this does nothing
        and returns 0. Otherwise, in one transaction, every row not already
        pending gets ``match_state='pending'`` (no decoding; no other column
        changes) and the new version is stored, so a crash cannot keep the
        version without the requeue. Returns the number of rows requeued.
        """
        self._require_any_owner("requeue_matching", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (MATCHER_VERSION_SETTING,)
            ).fetchone()
            if row is not None and row[0] == matcher_version:
                return 0
            count = conn.execute(
                "UPDATE track_audio_identity SET match_state = 'pending' WHERE match_state <> 'pending'"
            ).rowcount
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (MATCHER_VERSION_SETTING, matcher_version),
            )
            return count

    def requeue_unknown_duration_prints(self, rule_version: str, *, owner_id: Owner) -> int:
        """Retry prints that gave up with ``duration_unknown`` when the duration
        rule version changed (reconcile).

        If ``app_settings`` already holds ``rule_version`` this does nothing and
        returns 0. Otherwise, in one transaction, those rows go back to
        ``fp_state='pending'`` with attempts, backoff and failure reason cleared
        (``match_state`` and the exact columns are untouched) and the version is
        stored. Returns the number of rows requeued.
        """
        self._require_any_owner("requeue_unknown_duration_prints", owner_id)
        with self._connection(commit=True, immediate=True) as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (FINGERPRINT_DURATION_RULE_SETTING,)
            ).fetchone()
            if row is not None and row[0] == rule_version:
                return 0
            count = conn.execute(
                "UPDATE track_audio_identity SET fp_state = 'pending', attempts = 0, "
                "next_attempt_at = NULL, failure_reason = NULL "
                "WHERE failure_reason = 'duration_unknown' AND fp_state IN ('failed', 'pending') "
                f"AND {self._FP_OWNS_ATTEMPTS}"
            ).rowcount
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (FINGERPRINT_DURATION_RULE_SETTING, rule_version),
            )
            return count

    # Prints reclassified per transaction (also bounds the rows held in memory).
    RECLASSIFY_BATCH_SIZE = 500

    def reclassify_fingerprints(
        self,
        classifier_version: str,
        algorithm: Optional[str],
        classify: Callable[[tuple], str],
        *,
        owner_id: Owner,
        fingerprinter_present: bool = True,
    ) -> int:
        """Apply a changed print classification to stored prints (reconcile).

        If ``app_settings`` already holds ``classifier_version`` this does
        nothing and returns 0. Otherwise the work is done in bounded batches,
        each in its own short transaction, and the new version is stored last,
        so a crash or error part-way leaves the finished batches valid and the
        rest still due (a rerun repeats nothing harmful):

        - when a version was stored before, every 'too_short' row of
          ``algorithm`` goes back to 'pending' with a fingerprinter (to 'failed'
          when its exact layer failed, as the worker never prints such a row),
          else to 'unavailable' (its print is computed again when one is
          present, since a too_short row keeps no print); matching is untouched,
          and the attempt columns are reset only where the fingerprint layer
          owns them;
        - every 'current' or 'low_information' row of ``algorithm`` with a
          stored print of that algorithm is classified again from the stored
          items by ``classify(items)``. A row whose class changed is written
          with its new class (too_short keeps no print; a class that cannot be
          compared drops the row's open pairs) and gets ``match_state =
          'pending'``. Rows whose class did not change are not touched. A print
          that cannot be decoded is deleted and re-pended like a too_short row
          (its pairs are kept) and logged; any other error propagates.

        ``algorithm`` None means any: classification does not depend on the
        algorithm, so without a fingerprinter every stored print is handled; each
        row keeps its own algorithm and backend.

        Returns the number of rows changed."""
        self._require_any_owner("reclassify_fingerprints", owner_id)
        # Local import: app.services' package init imports this module (cycle).
        from app.services.fingerprinter import unpack_fingerprint

        with self._connection() as conn:
            row = conn.execute(
                "SELECT value FROM app_settings WHERE key = ?", (FINGERPRINT_CLASSIFIER_VERSION_SETTING,)
            ).fetchone()
        if row is not None and row[0] == classifier_version:
            return 0
        again_state = self._print_again_state_sql(fingerprinter_present)
        changed = 0
        if row is not None:
            with self._connection(commit=True, immediate=True) as conn:
                changed += conn.execute(
                    f"UPDATE track_audio_identity SET fp_state = {again_state}, "
                    f"{self._FP_RESET_ATTEMPTS_SQL} "
                    "WHERE fp_state = 'too_short' AND (? IS NULL OR fp_algorithm = ?)",
                    (algorithm, algorithm),
                ).rowcount
        last_rowid = 0
        while True:
            with self._connection(commit=True, immediate=True) as conn:
                prints = conn.execute(
                    "SELECT i.rowid, i.uuid_id, i.fp_state, f.backend, f.algorithm, f.duration_s, "
                    "f.item_count, f.data "
                    "FROM track_audio_identity i JOIN track_audio_fingerprint f ON f.uuid_id = i.uuid_id "
                    "WHERE i.fp_state IN ('current', 'low_information') AND i.fp_algorithm = f.algorithm "
                    "AND (? IS NULL OR f.algorithm = ?) AND i.rowid > ? ORDER BY i.rowid LIMIT ?",
                    (algorithm, algorithm, last_rowid, self.RECLASSIFY_BATCH_SIZE),
                ).fetchall()
                for rowid, uuid_id, old_state, backend, row_algorithm, duration_s, item_count, data in prints:
                    last_rowid = rowid
                    try:
                        raw = unpack_fingerprint(data)
                    except ValueError:
                        logger.warning("stored print for %s is undecodable; computing it again", uuid_id)
                        conn.execute("DELETE FROM track_audio_fingerprint WHERE uuid_id = ?", (uuid_id,))
                        conn.execute(
                            "UPDATE track_audio_identity SET "
                            "match_state = CASE WHEN fp_state = 'current' THEN 'pending' ELSE match_state END, "
                            f"fp_state = {again_state}, {self._FP_RESET_ATTEMPTS_SQL} WHERE uuid_id = ?",
                            (uuid_id,),
                        )
                        changed += 1
                        continue
                    new_state = classify(raw)
                    if new_state == old_state:
                        continue
                    self._write_fingerprint_in(conn, uuid_id, {
                        "fp_state": new_state, "fp_algorithm": row_algorithm, "fp_backend": backend,
                        "fp_duration_s": duration_s, "fp_item_count": item_count, "fp_data": data,
                    })
                    conn.execute(
                        "UPDATE track_audio_identity SET match_state = 'pending' WHERE uuid_id = ?",
                        (uuid_id,),
                    )
                    changed += 1
            if len(prints) < self.RECLASSIFY_BATCH_SIZE:
                break
        with self._connection(commit=True, immediate=True) as conn:
            conn.execute(
                "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?, ?)",
                (FINGERPRINT_CLASSIFIER_VERSION_SETTING, classifier_version),
            )
        return changed

    # The stored tool_versions split at the first "; " (mirror of
    # audio_identity.split_tool_versions): the ffmpeg part, and the fingerprinter
    # part (NULL when absent). Exact string comparison, never LIKE.
    _TV_SEP = "instr(tool_versions, '; ')"

    _TV_FFMPEG_SQL = f"CASE WHEN {_TV_SEP} > 0 THEN substr(tool_versions, 1, {_TV_SEP} - 1) ELSE tool_versions END"

    _TV_FINGERPRINTER_SQL = f"CASE WHEN {_TV_SEP} > 0 THEN substr(tool_versions, {_TV_SEP} + 2) END"

    def reset_failed_identity_rows(
        self, tool_versions: str, *, owner_id: Owner, fingerprint: bool = False
    ) -> int:
        """Make every failed exact layer eligible again when its ffmpeg version differs;
        with ``fingerprint`` also every failed print the fingerprint owns whose
        fingerprinter version differs. Each layer compares only its own part of
        ``tool_versions`` (``audio_identity.split_tool_versions``), except that a print
        failed for ``duration_unknown`` also follows the ffmpeg part (the decoded
        duration comes from ffmpeg)."""
        self._require_any_owner("reset_failed_identity_rows", owner_id)
        # Local import: app.services' package init imports this module (cycle).
        from app.services.audio_identity import split_tool_versions

        ffmpeg_part, fingerprinter_part = split_tool_versions(tool_versions)
        # Any path that sends a settled exact layer back to pending re-queues matching.
        with self._connection(commit=True, immediate=True) as conn:
            count = conn.execute(
                "UPDATE track_audio_identity SET exact_state = 'pending', match_state = 'pending', "
                "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                f"WHERE exact_state = 'failed' AND ({self._TV_FFMPEG_SQL}) IS NOT ?",
                (ffmpeg_part,),
            ).rowcount
            if fingerprint:
                count += conn.execute(
                    "UPDATE track_audio_identity SET fp_state = 'pending', "
                    "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                    f"WHERE fp_state = 'failed' AND ({self._TV_FINGERPRINTER_SQL}) IS NOT ? "
                    f"AND {self._FP_OWNS_ATTEMPTS}",
                    (fingerprinter_part,),
                ).rowcount
                # The decoded duration (third source) comes from ffmpeg, so a
                # duration_unknown print is also retried on an ffmpeg change.
                count += conn.execute(
                    "UPDATE track_audio_identity SET fp_state = 'pending', "
                    "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                    "WHERE fp_state = 'failed' AND failure_reason = 'duration_unknown' "
                    f"AND ({self._TV_FFMPEG_SQL}) IS NOT ? AND {self._FP_OWNS_ATTEMPTS}",
                    (ffmpeg_part,),
                ).rowcount
            return count

    _FP_MASTER_MISSING_SQL = (
        f"failure_reason = 'master_missing' AND {_FP_OWNS_ATTEMPTS} AND fp_state IN ('failed', 'pending')"
    )

    def list_master_missing_identity(
        self, *, owner_id: Owner, fingerprint: bool = False
    ) -> list[tuple[str, str]]:
        """(uuid_id, file_path) of rows whose exact layer failed for a missing master;
        with ``fingerprint`` also rows whose print failed for one."""
        self._require_any_owner("list_master_missing_identity", owner_id)
        with self._connection() as conn:
            return [
                (row[0], row[1])
                for row in conn.execute(
                    "SELECT i.uuid_id, t.file_path FROM track_audio_identity i "
                    "JOIN tracks t ON t.uuid_id = i.uuid_id "
                    "WHERE (i.failure_reason = 'master_missing' "
                    "AND i.exact_state IN ('failed', 'pending'))"
                    + (f" OR ({self._FP_MASTER_MISSING_SQL})" if fingerprint else "")
                )
            ]

    def reset_master_missing_identity(
        self, uuids: List[str], *, owner_id: Owner, fingerprint: bool = False
    ) -> int:
        """Make the given master_missing rows eligible again (exact layer, and with
        ``fingerprint`` the print when the fingerprint owns the failure)."""
        self._require_any_owner("reset_master_missing_identity", owner_id)
        # Any path that sends a settled exact layer back to pending re-queues matching.
        if not uuids:
            return 0
        in_list = f"uuid_id IN ({', '.join('?' * len(uuids))})"
        with self._connection(commit=True, immediate=True) as conn:
            count = conn.execute(
                "UPDATE track_audio_identity SET exact_state = 'pending', match_state = 'pending', "
                "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                f"WHERE {in_list} "
                "AND failure_reason = 'master_missing' AND exact_state IN ('failed', 'pending')",
                tuple(uuids),
            ).rowcount
            if fingerprint:
                count += conn.execute(
                    "UPDATE track_audio_identity SET fp_state = 'pending', "
                    "attempts = 0, next_attempt_at = NULL, failure_reason = NULL "
                    f"WHERE {in_list} AND {self._FP_MASTER_MISSING_SQL}",
                    tuple(uuids),
                ).rowcount
            return count
