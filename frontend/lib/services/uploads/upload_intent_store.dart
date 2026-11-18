// The local upload intents (spec §7): batch, item and operation UUIDs, the
// source descriptor, expected digest and length, the last state and error,
// and the SC-01 local_binding_id. Every write asserts the binding inside its
// transaction (a late write after a reset is a no-op), and every read is for
// one binding, so rows left by an earlier sign-in are never sent.
import 'package:drift/drift.dart' show
        BooleanExpressionOperators,
        Constant,
        InsertMode,
        OrderingTerm,
        SimpleSelectStatement,
        Value;
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/uploads/upload_item_rules.dart';
import 'package:frontend/services/uploads/upload_source.dart';

class NewUploadIntent {
  const NewUploadIntent({
    required this.itemUuid,
    required this.batchUuid,
    required this.selectionIndex,
    required this.displayName,
    required this.descriptor,
  });
  final String itemUuid;
  final String batchUuid;
  final int selectionIndex;
  final String displayName;
  final UploadSourceDescriptor descriptor;
}

class UploadIntentRecord {
  const UploadIntentRecord({
    required this.itemUuid,
    required this.batchUuid,
    required this.parentItemUuid,
    required this.selectionIndex,
    required this.displayName,
    required this.lastState,
    required this.lastErrorCode,
    required this.lastErrorMessage,
    required this.operationUuid,
    required this.transferOperationUuid,
    required this.reviewGeneration,
    required this.draftJson,
    required this.localBindingId,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.expectedLength,
    required this.expectedSha256,
    required this.descriptor,
  });

  final String itemUuid;
  final String batchUuid;
  final String? parentItemUuid;
  final int selectionIndex;
  final String displayName;
  final String lastState;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final String? operationUuid;
  final String? transferOperationUuid;
  final int? reviewGeneration;
  final String? draftJson;
  final String localBindingId;
  final int createdAtMs;
  final int updatedAtMs;

  /// The allocated digest and length (kept when the source location is
  /// gone); null = unknown.
  final int? expectedLength;
  final String? expectedSha256;

  /// The server's busy answer: the file waits for a slot, which the page
  /// shows as "Waiting for the server", never as an error (O13).
  static const slotsBusyCode = 'upload_slots_busy';

  /// The bytes are on this device: a top-level row picked here (every local
  /// pick stores its digest; an adopted row never has one).
  bool get bytesOnThisDevice =>
      parentItemUuid == null && expectedSha256 != null;

  bool get waitingForServer =>
      lastState == UploadIntentState.allocated && lastErrorCode == slotsBusyCode;

  /// Null when the source must be selected again.
  final UploadSourceDescriptor? descriptor;

  static UploadIntentRecord _fromRow(UploadIntent r) => UploadIntentRecord(
    itemUuid: r.itemUuid,
    batchUuid: r.batchUuid,
    parentItemUuid: r.parentItemUuid,
    selectionIndex: r.selectionIndex,
    displayName: r.displayName,
    lastState: r.lastState,
    lastErrorCode: r.lastErrorCode,
    lastErrorMessage: r.lastErrorMessage,
    operationUuid: r.operationUuid,
    transferOperationUuid: r.transferOperationUuid,
    reviewGeneration: r.reviewGeneration,
    draftJson: r.draftJson,
    localBindingId: r.localBindingId,
    createdAtMs: r.createdAt,
    updatedAtMs: r.updatedAt,
    expectedLength: r.expectedLength,
    expectedSha256: r.expectedSha256,
    descriptor: UploadSourceDescriptor.fromColumns(
      locationJson: r.sourceDescriptorJson,
      expectedLength: r.expectedLength,
      expectedSha256: r.expectedSha256,
    ),
  );
}

class UploadIntentStore {
  UploadIntentStore({
    required AppDatabase db,
    required ServerBindingRepository binding,
    required Clock clock,
  }) : _db = db,
       _binding = binding,
       _clock = clock;

  final AppDatabase _db;
  final ServerBindingRepository _binding;
  final Clock _clock;

  /// Inserts the rows in one fenced transaction.
  Future<void> insertAll(
    String bindingToken,
    List<NewUploadIntent> intents, {
    required String state,
  }) => _binding.runFenced(bindingToken, () async {
    final now = _clock.nowUtcMs();
    for (final i in intents) {
      await _db
          .into(_db.uploadIntents)
          .insert(
            UploadIntentsCompanion.insert(
              itemUuid: i.itemUuid,
              batchUuid: i.batchUuid,
              selectionIndex: i.selectionIndex,
              displayName: i.displayName,
              sourceDescriptorJson: Value(i.descriptor.locationJson()),
              expectedSha256: Value(i.descriptor.sha256),
              expectedLength: Value(i.descriptor.length),
              lastState: state,
              localBindingId: bindingToken,
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
  });

  /// Adopts the listed items that are ZIP children of a local intent of this
  /// binding and have no intent yet. Anything else listed is ignored.
  Future<void> adoptListedChildren(
    String bindingToken,
    List<UploadItem> listed,
  ) async {
    final known = {for (final i in await forBinding(bindingToken)) i.itemUuid};
    final children = [
      for (final i in listed)
        if (i.parentItemUuid != null &&
            known.contains(i.parentItemUuid) &&
            !known.contains(i.itemUuid))
          i,
    ];
    if (children.isNotEmpty) await adoptChildren(bindingToken, children);
  }

  /// Adopts every listed item this binding has no row for, when it is
  /// top-level or its parent is known (or adopted earlier in [listed]): work
  /// staged on another device or before a reset (7-R1-22). No source, so it
  /// is never transferred from here. A listed item is always represented by
  /// a row of this binding; a row of another binding is dead (7-R2-02). A
  /// finished top-level item (imported, duplicate, cancelled, expired) is not
  /// adopted; one still waiting for its bytes is stored `on_other_device`.
  Future<void> adoptListedItems(
    String bindingToken,
    List<UploadItem> listed,
  ) async {
    final known = {for (final i in await forBinding(bindingToken)) i.itemUuid};
    final adopt = <UploadItem>[];
    for (final i in listed) {
      if (known.contains(i.itemUuid)) continue;
      if (i.parentItemUuid != null && !known.contains(i.parentItemUuid)) {
        continue;
      }
      // Finished work elsewhere has nothing left to do here.
      if (i.parentItemUuid == null && endedStates.contains(i.rawState)) {
        continue;
      }
      known.add(i.itemUuid);
      adopt.add(i);
    }
    if (adopt.isNotEmpty) await adoptChildren(bindingToken, adopt);
  }

  /// Adds a row of [bindingToken] for each listed item (a ZIP child or an
  /// adopted item). A row of this binding is never touched; a row with the
  /// same item of another binding (an earlier sign-in) is dead and is deleted
  /// first, so the item is adopted afresh (7-R2-02). Such a row has no source
  /// and is never sent.
  Future<void> adoptChildren(String bindingToken, List<UploadItem> children) =>
      _binding.runFenced(bindingToken, () async {
        final now = _clock.nowUtcMs();
        for (final c in children) {
          await (_db.delete(_db.uploadIntents)..where(
                (t) =>
                    t.itemUuid.equals(c.itemUuid) &
                    t.localBindingId.equals(bindingToken).not(),
              ))
              .go();
          await _db
              .into(_db.uploadIntents)
              .insert(
                UploadIntentsCompanion.insert(
                  itemUuid: c.itemUuid,
                  batchUuid: c.batchUuid,
                  parentItemUuid: Value(c.parentItemUuid),
                  selectionIndex: c.selectionIndex,
                  displayName: c.filename,
                  expectedLength: Value(c.expectedBytes),
                  // Bytes a top-level item still needs are on another device.
                  lastState:
                      c.parentItemUuid == null &&
                          UploadIntentState.awaitingBytes.contains(c.rawState)
                      ? UploadIntentState.onOtherDevice
                      : c.rawState,
                  lastErrorCode: Value(c.error?.code),
                  localBindingId: bindingToken,
                  createdAt: now,
                  updatedAt: now,
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }
      });

  /// The one mirror rule for a fresh server read (7-R1-21): a row still
  /// `review_ready`, `duplicate_conflict`, `on_other_device`, `failed` or
  /// `expanded` locally takes
  /// the state and error code of an item the server now reports differently.
  /// A read that agrees never touches the row; submitted or committing rows
  /// are never written, and an `on_other_device` row is not flipped back by a
  /// read that still waits for bytes (allocated, receiving, transferring).
  /// Over a reviewable row only an ended state (imported, duplicate,
  /// cancelled, expired) is mirrored, never one reviewable state over the
  /// other (reads are not ordered against local writes). A `failed` row
  /// takes any other state that does not wait for bytes (a retry, cancel or
  /// expiry done elsewhere), never one that does: this device writes
  /// `failed` over a refused send the server still waits for. An unpacked
  /// archive (`expanded`) takes only an ended state.
  Future<void> mirrorReviewStates(
    String bindingToken,
    List<UploadItem> items,
  ) async {
    for (final item in items) {
      final ended = endedStates.contains(item.rawState);
      final waitsForBytes = const {
        'allocated',
        'receiving',
        'transferring',
      }.contains(item.rawState);
      final from = {
        if (ended) ...reviewableStates,
        if (ended) ServerItemState.expanded,
        if (!waitsForBytes) ...{
          UploadIntentState.onOtherDevice,
          ServerItemState.failed,
        },
      }.difference({item.rawState});
      if (from.isEmpty) continue;
      await update(
        bindingToken,
        [item.itemUuid],
        lastState: Value(item.rawState),
        lastErrorCode: Value(item.error?.code),
        onlyIfStateIn: from,
      );
    }
  }

  /// Writes the present values (an explicit `Value(null)` clears a column)
  /// and `updated_at` to the rows, in one fenced transaction. With
  /// [onlyIfStateIn], only rows whose `last_state` is in the set are written
  /// (a write based on an earlier read never overwrites a newer state).
  Future<void> update(
    String bindingToken,
    List<String> itemUuids, {
    Value<String> lastState = const Value.absent(),
    Value<String?> lastErrorCode = const Value.absent(),
    Value<String?> lastErrorMessage = const Value.absent(),
    Value<String?> sourceDescriptorJson = const Value.absent(),
    Value<String?> expectedSha256 = const Value.absent(),
    Value<int?> expectedLength = const Value.absent(),
    Value<String?> transferOperationUuid = const Value.absent(),
    Value<String?> operationUuid = const Value.absent(),
    Value<int?> reviewGeneration = const Value.absent(),
    Value<String?> draftJson = const Value.absent(),
    Set<String>? onlyIfStateIn,
  }) => _binding.runFenced(bindingToken, () async {
    await (_db.update(_db.uploadIntents)
          ..where(
            (t) =>
                t.itemUuid.isIn(itemUuids) &
                t.localBindingId.equals(bindingToken) &
                (onlyIfStateIn == null
                    ? const Constant(true)
                    : t.lastState.isIn(onlyIfStateIn)),
          ))
        .write(
          UploadIntentsCompanion(
            lastState: lastState,
            lastErrorCode: lastErrorCode,
            lastErrorMessage: lastErrorMessage,
            sourceDescriptorJson: sourceDescriptorJson,
            expectedSha256: expectedSha256,
            expectedLength: expectedLength,
            transferOperationUuid: transferOperationUuid,
            operationUuid: operationUuid,
            reviewGeneration: reviewGeneration,
            draftJson: draftJson,
            updatedAt: Value(_clock.nowUtcMs()),
          ),
        );
  });

  SimpleSelectStatement<$UploadIntentsTable, UploadIntent> _query(
    String bindingToken,
  ) => _db.select(_db.uploadIntents)
    ..where((t) => t.localBindingId.equals(bindingToken))
    ..orderBy([
      (t) => OrderingTerm.asc(t.createdAt),
      (t) => OrderingTerm.asc(t.batchUuid),
      (t) => OrderingTerm.asc(t.selectionIndex),
      (t) => OrderingTerm.asc(t.itemUuid),
    ]);

  Future<List<UploadIntentRecord>> forBinding(String bindingToken) async => [
    for (final r in await _query(bindingToken).get()) UploadIntentRecord._fromRow(r),
  ];

  /// Every row of every binding, for counting what a log-out kept. Read-only.
  Future<List<UploadIntentRecord>> all() async => [
    for (final r in await (_db.select(_db.uploadIntents)).get())
      UploadIntentRecord._fromRow(r),
  ];

  Stream<List<UploadIntentRecord>> watch(String bindingToken) => _query(
    bindingToken,
  ).watch().map((rows) => [for (final r in rows) UploadIntentRecord._fromRow(r)]);

  /// Rows left by an earlier sign-in.
  Future<int> countOtherBindings(String bindingToken) async =>
      (await (_db.select(
        _db.uploadIntents,
      )..where((t) => t.localBindingId.isNotValue(bindingToken))).get())
          .length;
}
