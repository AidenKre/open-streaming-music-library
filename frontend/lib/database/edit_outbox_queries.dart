part of 'database.dart';

mixin _EditOutboxQueries on _$AppDatabase, _SearchIndex {
  /// A tombstoned track can never accept its unsent edits: resolve the
  /// `pending`/`conflicted` ones as rejected (visible in the banner), without
  /// sending anything. Rows already rejected keep their own reason; `take_server`
  /// rows are untouched. Run inside the transaction that deletes the tracks.
  Future<void> rejectUnsentEditsOfDeletedTracks(List<String> uuids) =>
      (update(pendingEdits)
            ..where(
              (t) =>
                  t.uuidId.isIn(uuids) &
                  t.status.isIn(const [PendingEditStatus.pending, PendingEditStatus.conflicted]),
            ))
          .write(
        const PendingEditsCompanion(
          status: Value(PendingEditStatus.rejected),
          rejectionReason: Value(trackGoneRejectionReason),
          serverRevision: Value(null),
        ),
      );

  // ── Optimistic edit write (outbox) ────────────────────────────────────

  /// Applies the touched fields of a pending edit to the local denormalized
  /// `trackmetadata` text + a targeted single-row FTS update, so the edit shows
  /// immediately. Deliberately does NOT repoint `artist_id`/`album_id` (that is
  /// the server helper's job) — so after an artist rename the tile shows the new
  /// text but the track stays under the old artist node until flush+sync.
  Future<void> applyOptimisticTrackEdit(
    String uuidId,
    Map<String, Object?> values,
  ) async {
    final cols = values.keys.where(editableMetadataColumns.contains).toList();
    if (cols.isEmpty) return;

    await transaction(() async {
      final before = await readTrackFtsEntry(uuidId);
      if (before == null) return;

      final setSql = cols.map((c) => '"$c" = ?').join(', ');
      // customUpdate (not customStatement) so drift notifies `trackmetadata`
      // stream watchers — the reactive browse lists must re-render on the edit.
      await customUpdate(
        'UPDATE trackmetadata SET $setSql WHERE uuid_id = ?',
        variables: [
          ...cols.map((c) => Variable(values[c])),
          Variable.withString(uuidId),
        ],
        updates: {trackmetadata},
        updateKind: UpdateKind.update,
      );

      await applyTrackFtsDelta(uuidId, before);
    });
  }

  /// Raises a track's stored `revision` to [revision]; never lowers it, so a
  /// concurrently-synced higher revision is not regressed. No app code calls
  /// it: a successful edit records its revision through
  /// [recordOwnEditRevision]. Tests use it to stand in for a server-side
  /// revision change.
  Future<void> updateTrackRevision(String uuidId, int revision) async {
    await customUpdate(
      'UPDATE tracks SET revision = ? '
      'WHERE uuid_id = ? AND (revision IS NULL OR revision < ?)',
      variables: [
        Variable.withInt(revision),
        Variable.withString(uuidId),
        Variable.withInt(revision),
      ],
      updates: {tracks},
      updateKind: UpdateKind.update,
    );
  }

  /// Snapshot of a track's editable column values (the pre-edit state), used to
  /// revert an optimistic edit locally on take-server/discard. Returns an empty
  /// map if the track row is missing.
  Future<Map<String, Object?>> readEditableColumns(String uuidId) async {
    final cols = editableMetadataColumns.toList();
    final select = cols.map((c) => '"$c"').join(', ');
    final row = await customSelect(
      'SELECT $select FROM trackmetadata WHERE uuid_id = ?',
      variables: [Variable.withString(uuidId)],
      readsFrom: {trackmetadata},
    ).getSingleOrNull();
    if (row == null) return {};
    return {for (final c in cols) c: row.data[c]};
  }

  /// The queued write mode (`db_only`/`db_and_master`) for a track's pending
  /// edit, or null if none is queued. Lets Get Info reflect a queued master
  /// write when it reopens. Only `pending`/`conflicted` rows are active edits
  /// whose write mode should inform a new save's default — a `take_server`
  /// marker's write mode is a leftover from the batch it's discarding, and a
  /// `rejected` row's edit was already reverted, so neither should leak into
  /// a fresh save.
  Future<String?> pendingWriteMode(String uuidId) async {
    final row = await (select(pendingEdits)
          ..where((t) => t.uuidId.equals(uuidId))
          ..where((t) => t.status.isIn(const [PendingEditStatus.pending, PendingEditStatus.conflicted])))
        .getSingleOrNull();
    return row?.writeMode;
  }

  /// Records the revision the user's OWN successful edit produced (raising
  /// `revision` exactly like [updateTrackRevision]) and, when the downloaded
  /// file was current as of [currentAsOf] -- the revision the server held
  /// immediately before the edit -- advances `downloaded_at_revision` to
  /// [newRevision] in the same statement. The app displays metadata from this
  /// DB, not the file's tags, so a self-edit doesn't make the download
  /// meaningfully outdated; server-originated changes (a conversion, another
  /// device's edit, new artwork) never pass through here and still flag.
  /// Likewise, a stale-download warning the user dismissed as of
  /// [currentAsOf] is carried forward to [newRevision], so their own edit
  /// doesn't resurrect a warning they already dismissed.
  /// Pass a null [currentAsOf] to only raise the revision.
  Future<void> recordOwnEditRevision(
    String uuidId,
    int newRevision, {
    required int? currentAsOf,
  }) async {
    // SET expressions all read the pre-update row, so the CASEs see the old
    // downloaded_at_revision / stale_dismissed_at_revision regardless of
    // clause order.
    await customUpdate(
      'UPDATE tracks SET '
      'downloaded_at_revision = CASE '
      'WHEN ?1 IS NOT NULL AND file_path IS NOT NULL '
      'AND downloaded_at_revision = ?1 AND ?2 > ?1 THEN ?2 '
      'ELSE downloaded_at_revision END, '
      'stale_dismissed_at_revision = CASE '
      'WHEN ?1 IS NOT NULL AND stale_dismissed_at_revision = ?1 '
      'AND ?2 > ?1 THEN ?2 '
      'ELSE stale_dismissed_at_revision END, '
      'revision = CASE WHEN revision IS NULL OR revision < ?2 THEN ?2 '
      'ELSE revision END '
      'WHERE uuid_id = ?3',
      variables: [
        currentAsOf == null
            ? const Variable<int>(null)
            : Variable.withInt(currentAsOf),
        Variable.withInt(newRevision),
        Variable.withString(uuidId),
      ],
      updates: {tracks},
      updateKind: UpdateKind.update,
    );
  }

  /// Live counts of outstanding edits for the pending-edits surface.
  /// `take_server` rows are excluded at the source: they are resolution
  /// markers awaiting their refetch, not user-visible outbox rows.
  Stream<({int pending, int conflicted, int rejected})>
      watchPendingEditCounts() =>
          _pendingEditCountsQuery().watch().map(_editCounts);

  /// One-shot form of [watchPendingEditCounts] (same definition).
  Future<({int pending, int conflicted, int rejected})> pendingEditCounts() =>
      _pendingEditCountsQuery().get().then(_editCounts);

  Selectable<QueryRow> _pendingEditCountsQuery() => customSelect(
    "SELECT "
    "SUM(CASE WHEN status = '${PendingEditStatus.conflicted}' "
    "THEN 1 ELSE 0 END) AS conflicted, "
    "SUM(CASE WHEN status = '${PendingEditStatus.rejected}' "
    "THEN 1 ELSE 0 END) AS rejected, "
    "COUNT(*) AS total FROM pending_edits "
    "WHERE status IN ('${PendingEditStatus.pending}', "
    "'${PendingEditStatus.conflicted}', '${PendingEditStatus.rejected}')",
    readsFrom: {pendingEdits},
  );

  static ({int pending, int conflicted, int rejected}) _editCounts(
    List<QueryRow> rows,
  ) {
    final row = rows.first;
    final conflicted = row.readNullable<int>('conflicted') ?? 0;
    final rejected = row.readNullable<int>('rejected') ?? 0;
    final total = row.read<int>('total');
    return (
      pending: total - conflicted - rejected,
      conflicted: conflicted,
      rejected: rejected,
    );
  }
}
