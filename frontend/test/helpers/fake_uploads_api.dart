import 'dart:async';
import 'dart:convert';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/uploads/upload_source.dart';

/// One upload item as the server answers it (wire shape).
Map<String, dynamic> itemJson(
  String itemUuid, {
  String batchUuid = 'b-1',
  String state = 'allocated',
  int selectionIndex = 0,
  String filename = 'song.flac',
  int? expectedBytes,
  String? expectedSha256,
  int receivedBytes = 0,
  int reviewVersion = 0,
  Map<String, dynamic>? error,
}) => {
  'item_uuid': itemUuid,
  'batch_uuid': batchUuid,
  'parent_item_uuid': null,
  'filename': filename,
  'selection_index': selectionIndex,
  'member_order_key': '',
  'state': state,
  'expected_bytes': expectedBytes,
  'expected_sha256': expectedSha256,
  'received_bytes': receivedBytes,
  'review_version': reviewVersion,
  'error': error,
  'created_at': 1,
  'updated_at': 1,
  'duplicate_check': null,
};

Map<String, dynamic> batchJson(String batchUuid, {int itemCount = 1}) => {
  'batch_uuid': batchUuid,
  'label': null,
  'created_at': 1,
  'updated_at': 1,
  'item_count': itemCount,
  'state_counts': <String, int>{},
  'items_path': '/tracks/uploads/$batchUuid/items',
};

/// An SC-22 error answer.
ApiException apiError(
  int status,
  String code, {
  bool? retryable,
  int? retryAfterS,
}) => ApiException(
  status,
  jsonEncode({
    'detail': {
      'error': code,
      'message': code,
      'retryable': ?retryable,
      'retry_after_s': ?retryAfterS,
    },
  }),
);

/// One content PUT the fake received; the test settles it.
class FakePut {
  FakePut(this.itemUuid, this.expectedLength, this.expectedSha256,
      this.onProgress, this.abortTrigger);
  final String itemUuid;
  final int expectedLength;
  final String expectedSha256;
  final void Function(int sentBytes)? onProgress;
  final Future<void>? abortTrigger;
  final _done = Completer<UploadItem>();
  bool aborted = false;

  bool get isSettled => _done.isCompleted;

  /// The server stored the body: answers the item in [state].
  void complete({String state = 'validating', String batchUuid = 'b-1'}) {
    if (!_done.isCompleted) {
      _done.complete(UploadItem.fromJson(itemJson(itemUuid,
          batchUuid: batchUuid, state: state, receivedBytes: expectedLength)));
    }
  }

  /// The PUT ends with [error] (an [ApiException], a transport failure, a
  /// source outcome, a different-server answer…).
  void fail(Object error) {
    if (!_done.isCompleted) _done.completeError(error);
  }
}

/// A scriptable [UploadsApi]. Every call is recorded in [calls] (as
/// `'<method> <id>'`) together with whether the binding gate was verified
/// when it was made ([callsBeforeVerified] counts the others). Answers come
/// from the handlers a test sets; content PUTs stay open until the test
/// settles them through [puts]. An abort trigger ends an open PUT with
/// [UploadTransferAborted], like the real transport.
class FakeUploadsApi implements UploadsApi {
  FakeUploadsApi({this.gate});

  /// When set, each call records whether this gate was verified.
  final ServerBindingGate? gate;

  final calls = <String>[];
  int callsBeforeVerified = 0;

  /// Allocation bodies as sent (the frozen JSON string).
  final allocations = <String>[];

  /// Every content PUT, in order.
  final puts = <FakePut>[];

  List<FakePut> get openPuts => [for (final p in puts) if (!p.isSettled) p];

  /// Default: a fresh allocation with every item `allocated`.
  Future<AllocationResult> Function(String frozenBodyJson) onAllocate =
      (body) async {
        final m = jsonDecode(body) as Map<String, dynamic>;
        final batch = m['batch_uuid'] as String;
        final items = (m['items'] as List).cast<Map<String, dynamic>>();
        return AllocationResult.fromJson({
          'batch': batchJson(batch, itemCount: items.length),
          'items': [
            for (final (i, it) in items.indexed)
              itemJson(it['item_uuid'] as String,
                  batchUuid: batch,
                  selectionIndex: i,
                  filename: it['filename'] as String,
                  expectedBytes: it['byte_length'] as int,
                  expectedSha256: it['sha256'] as String),
          ],
          'limits': <String, dynamic>{},
        });
      };

  /// Default: the item is `allocated`.
  Future<UploadItem> Function(String itemUuid) onGetItem = (item) async =>
      UploadItem.fromJson(itemJson(item));

  /// Default: the batch is unknown (404 upload_batch_not_found).
  Future<UploadBatch> Function(String batchUuid) onGetBatch = (batch) async =>
      throw apiError(404, 'upload_batch_not_found', retryable: false);

  /// Default: no batches.
  Future<UploadBatchPage> Function(String? after) onListBatches = (after) async =>
      UploadBatchPage.fromJson({'batches': <Object>[], 'next_after': null});

  /// Default: an empty page.
  Future<UploadItemPage> Function(String batchUuid, String? after)
  onListItems = (batch, after) async =>
      UploadItemPage.fromJson({'items': <Object>[], 'next_after': null});

  /// Default: the item is `cancelled`.
  Future<UploadItem> Function(String itemUuid) onCancel = (item) async =>
      UploadItem.fromJson(itemJson(item, state: 'cancelled'));

  /// Default: the commit is accepted (`committing`).
  Future<UploadItem> Function(String itemUuid, Map<String, dynamic> body)
  onCommit = (item, body) async => UploadItem.fromJson(itemJson(item,
      state: 'committing',
      reviewVersion: body['base_review_version'] as int? ?? 0));

  /// Default: the item is closed as `duplicate`.
  Future<UploadItem> Function(String itemUuid, Map<String, dynamic> body)
  onResolveDuplicate = (item, body) async =>
      UploadItem.fromJson(itemJson(item, state: 'duplicate'));

  /// Default: the item is `validating` at the next review version.
  Future<UploadItem> Function(String itemUuid, int expectedReviewVersion)
  onRetry = (item, version) async => UploadItem.fromJson(
      itemJson(item, state: 'validating', reviewVersion: version + 1));

  /// Ends [answer] with [UploadTransferAborted] once [abortTrigger] fires,
  /// like the real API's gate wait (a hanging answer never holds a quiesce).
  Future<T> _abortable<T>(Future<T> answer, Future<void>? abortTrigger) {
    if (abortTrigger == null) return answer;
    final out = Completer<T>();
    answer.then((v) {
      if (!out.isCompleted) out.complete(v);
    }, onError: (Object e, StackTrace st) {
      if (!out.isCompleted) out.completeError(e, st);
    });
    void abort(Object? _) {
      if (!out.isCompleted) out.completeError(const UploadTransferAborted());
    }
    abortTrigger.then(abort, onError: abort);
    return out.future;
  }

  void _record(String call) {
    calls.add(call);
    final g = gate;
    if (g != null && g.verifiedConnection == null) callsBeforeVerified++;
  }

  @override
  Future<AllocationResult> allocate(
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) {
    final batch =
        (jsonDecode(frozenBodyJson) as Map<String, dynamic>)['batch_uuid'];
    _record('allocate $batch');
    allocations.add(frozenBodyJson);
    return _abortable(Future.sync(() => onAllocate(frozenBodyJson)), abortTrigger);
  }

  @override
  Future<UploadItem> getItem(String itemUuid, {Future<void>? abortTrigger}) {
    _record('getItem $itemUuid');
    return _abortable(Future.sync(() => onGetItem(itemUuid)), abortTrigger);
  }

  @override
  Future<UploadBatch> getBatch(String batchUuid, {Future<void>? abortTrigger}) {
    _record('getBatch $batchUuid');
    return _abortable(Future.sync(() => onGetBatch(batchUuid)), abortTrigger);
  }

  @override
  Future<UploadBatchPage> listBatches({
    String? after,
    int? limit,
    Future<void>? abortTrigger,
  }) {
    _record('listBatches');
    return _abortable(Future.sync(() => onListBatches(after)), abortTrigger);
  }

  @override
  Future<UploadItemPage> listItems(
    String batchUuid, {
    String? after,
    int? limit,
    Future<void>? abortTrigger,
  }) {
    _record('listItems $batchUuid');
    return _abortable(Future.sync(() => onListItems(batchUuid, after)), abortTrigger);
  }

  @override
  Future<UploadItem> cancelItem(String itemUuid, {Future<void>? abortTrigger}) {
    _record('cancelItem $itemUuid');
    return _abortable(Future.sync(() => onCancel(itemUuid)), abortTrigger);
  }

  @override
  Future<UploadItem> commit(String itemUuid, String frozenBodyJson,
      {Future<void>? abortTrigger}) {
    _record('commit $itemUuid');
    return _abortable(
        Future.sync(() => onCommit(
            itemUuid, jsonDecode(frozenBodyJson) as Map<String, dynamic>)),
        abortTrigger);
  }

  @override
  Future<UploadItem> resolveDuplicate(String itemUuid, String frozenBodyJson,
      {Future<void>? abortTrigger}) {
    _record('resolveDuplicate $itemUuid');
    return _abortable(
        Future.sync(() => onResolveDuplicate(
            itemUuid, jsonDecode(frozenBodyJson) as Map<String, dynamic>)),
        abortTrigger);
  }

  @override
  Future<UploadItem> retry(String itemUuid,
      {required int expectedReviewVersion, Future<void>? abortTrigger}) {
    _record('retry $itemUuid');
    return _abortable(
        Future.sync(() => onRetry(itemUuid, expectedReviewVersion)),
        abortTrigger);
  }

  @override
  Future<UploadItem> putContent(
    String itemUuid,
    UploadSource source, {
    required int expectedLength,
    required String expectedSha256,
    void Function(int sentBytes)? onProgress,
    Future<void>? abortTrigger,
  }) {
    _record('putContent $itemUuid');
    final put = FakePut(
        itemUuid, expectedLength, expectedSha256, onProgress, abortTrigger);
    puts.add(put);
    abortTrigger?.then((_) {
      put.aborted = true;
      put.fail(const UploadTransferAborted());
    }, onError: (Object _) {
      put.aborted = true;
      put.fail(const UploadTransferAborted());
    });
    return put._done.future;
  }
}
