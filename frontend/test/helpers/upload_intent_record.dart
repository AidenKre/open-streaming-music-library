// One builder for a local upload intent row in tests, so a new field of
// UploadIntentRecord is added here once instead of in every test file. Every
// default is a hand-written fixture value (nothing computed by production
// code); a test passes whatever it asserts on.
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_source.dart';

UploadIntentRecord intentRecord(
  String itemUuid, {
  String batchUuid = 'b-1',
  String? parentItemUuid,
  int selectionIndex = 0,
  String displayName = 'song.flac',
  String state = 'review_ready',
  String? lastErrorCode,
  String? lastErrorMessage,
  String? operationUuid,
  String? transferOperationUuid,
  int? reviewGeneration,
  String? draftJson,
  String localBindingId = 'bind',
  int createdAtMs = 0,
  int updatedAtMs = 0,
  int? expectedLength,
  String? expectedSha256,
  UploadSourceDescriptor? descriptor,
}) => UploadIntentRecord(
  itemUuid: itemUuid,
  batchUuid: batchUuid,
  parentItemUuid: parentItemUuid,
  selectionIndex: selectionIndex,
  displayName: displayName,
  lastState: state,
  lastErrorCode: lastErrorCode,
  lastErrorMessage: lastErrorMessage,
  operationUuid: operationUuid,
  transferOperationUuid: transferOperationUuid,
  reviewGeneration: reviewGeneration,
  draftJson: draftJson,
  localBindingId: localBindingId,
  createdAtMs: createdAtMs,
  updatedAtMs: updatedAtMs,
  expectedLength: expectedLength,
  expectedSha256: expectedSha256,
  descriptor: descriptor,
);
