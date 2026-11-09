import 'package:drift/drift.dart';
import 'package:frontend/database/database.dart';
import 'package:uuid/uuid.dart';

/// The local binding to one server (SC-01): the `server_binding` row.
///
/// [instanceId] is null for a provisional binding (not yet verified against
/// `/app/info`) or a legacy server that reports none.
class ServerBindingRecord {
  const ServerBindingRecord({
    required this.instanceId,
    required this.localBindingId,
    required this.lastBaseUrl,
    required this.boundAtMs,
    required this.catalogReconciled,
  });

  final String? instanceId;
  final String localBindingId;
  final String lastBaseUrl;
  final int boundAtMs;
  final bool catalogReconciled;
}

/// A fenced write's captured `local_binding_id` no longer matches the
/// binding row (a reset deleted it, or a re-bind replaced it). The write did
/// not happen.
class BindingFencedException implements Exception {
  BindingFencedException(this.token);
  final String token;

  @override
  String toString() => 'BindingFencedException($token)';
}

/// Owns the single `server_binding` row and the durable write fence.
///
/// Writers that apply server data or background results capture
/// [ServerBindingRecord.localBindingId] when their task starts and commit
/// through [runFenced], so a write that outlives a reset or re-bind is a
/// no-op instead of resurrecting data in the new store.
class ServerBindingRepository {
  ServerBindingRepository(
    this._db, {
    String Function()? newBindingId,
    int Function()? nowMs,
  }) : _newBindingId = newBindingId ?? _uuidV4,
       _nowMs = nowMs ?? _utcNowMs;

  final AppDatabase _db;
  final String Function() _newBindingId;
  final int Function() _nowMs;

  static String _uuidV4() => const Uuid().v4();
  static int _utcNowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  Future<ServerBindingRecord?> current() async =>
      _toRecord(await _select().getSingleOrNull());

  /// Returns the binding row, creating a provisional one (NULL instance id,
  /// fresh token) for [baseUrl] if none exists. An existing row is returned
  /// unchanged.
  Future<ServerBindingRecord> ensureProvisional(String baseUrl) {
    return _db.transaction(() async {
      final existing = await _select().getSingleOrNull();
      if (existing != null) return _toRecord(existing)!;
      await _db
          .into(_db.serverBinding)
          .insert(
            ServerBindingCompanion.insert(
              localBindingId: _newBindingId(),
              lastBaseUrl: baseUrl,
              boundAt: _nowMs(),
            ),
          );
      return _toRecord(await _select().getSingle())!;
    });
  }

  /// Records a successful verification against the bound server: fills a
  /// NULL instance id in place (keeping the token) and updates
  /// `last_base_url`. Never overwrites identity: a different known instance
  /// id throws [StateError] (that server goes through the reset flow), and a
  /// null [instanceId] leaves the stored one as is.
  Future<void> recordVerified(
    String token, {
    required String? instanceId,
    required String baseUrl,
  }) {
    return runFenced(token, () async {
      final row = await _select().getSingle();
      if (row.instanceId != null &&
          instanceId != null &&
          row.instanceId != instanceId) {
        throw StateError(
          'server_binding holds instance ${row.instanceId}; '
          'refusing to rebind to $instanceId',
        );
      }
      await _db
          .update(_db.serverBinding)
          .write(
            ServerBindingCompanion(
              lastBaseUrl: Value(baseUrl),
              instanceId: instanceId == null
                  ? const Value.absent()
                  : Value(instanceId),
            ),
          );
    });
  }

  /// Sets `catalog_reconciled_at_binding`. Unfenced: must run inside the
  /// caller's [runFenced] body (catalog sync marks it with its final page).
  Future<void> markCatalogReconciledInTransaction() async {
    await _db
        .update(_db.serverBinding)
        .write(
          const ServerBindingCompanion(catalogReconciledAtBinding: Value(true)),
        );
  }

  /// Clears `catalog_reconciled_at_binding` (fenced): a server restored from
  /// a backup may reissue parent ids, so the local parents no longer match
  /// the server's until a reset.
  Future<void> clearCatalogReconciled(String token) => runFenced(token, () async {
        await _db.update(_db.serverBinding).write(
            const ServerBindingCompanion(catalogReconciledAtBinding: Value(false)));
      });

  /// Deletes the binding row: the first step of a reset. Every token
  /// captured before this point is fenced from then on.
  Future<void> fence() => _db.delete(_db.serverBinding).go();

  /// Runs [body] in one Drift transaction that first asserts the binding row
  /// still carries [token]; otherwise throws [BindingFencedException] without
  /// running [body]. A throw from [body] rolls it back.
  Future<T> runFenced<T>(String token, Future<T> Function() body) {
    return _db.transaction(() async {
      final row = await _select().getSingleOrNull();
      if (row?.localBindingId != token) throw BindingFencedException(token);
      return body();
    });
  }

  SimpleSelectStatement<$ServerBindingTable, ServerBindingData> _select() =>
      _db.select(_db.serverBinding);

  static ServerBindingRecord? _toRecord(ServerBindingData? row) {
    if (row == null) return null;
    return ServerBindingRecord(
      instanceId: row.instanceId,
      localBindingId: row.localBindingId,
      lastBaseUrl: row.lastBaseUrl,
      boundAtMs: row.boundAt,
      catalogReconciled: row.catalogReconciledAtBinding,
    );
  }
}
