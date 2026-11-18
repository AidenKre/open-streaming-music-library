import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/uploads/upload_source.dart';

/// The /tracks/uploads transport (Phase 7 spec §4, server as built).
///
/// Every call first waits for the binding gate ([ServerBindingGate.
/// awaitVerified]): nothing is built or sent to a server this connection has
/// not verified (OPEN-M-11, plan §6). Every call goes through the bound
/// client (`boundApiClientProvider`): an answer stamped by another instance
/// throws `ServerInstanceChangedException` (never a body or an
/// [ApiException]); before rethrowing it, this class reports it to the gate
/// with the connection captured with the token, so the different-server
/// flow runs and later calls wait at the gate. The caller leaves its local
/// row as it was before the send.
///
/// Errors otherwise: [ApiException] (SC-22 envelope: `errorCode`,
/// `retryable`, `retryAfter`, `details`), [NetworkException], and for
/// [putContent] also [UploadSourceChanged], [UploadSourceUnavailable] and
/// [UploadTransferAborted]. No call retries a mutation on its own.
class UploadsApi {
  UploadsApi({required ApiClient api, required ServerBindingGate gate})
      : _api = api,
        _gate = gate;

  final ApiClient _api;
  final ServerBindingGate _gate;

  /// Waits for the gate, then runs [send]; an answer from another instance
  /// is reported to the gate (with the connection captured alongside the
  /// token) before it is rethrown.
  ///
  /// [abortTrigger] (completing, with or without an error) ends a wait at
  /// the gate with [UploadTransferAborted] and sends nothing. Once [send]
  /// is under way only [putContent] can be stopped (its body stream); the
  /// JSON calls are short and the client can't cancel them mid-flight.
  Future<T> _gated<T>(
    Future<T> Function() send, [
    Future<void>? abortTrigger,
  ]) async {
    var aborted = false;
    final signal = Completer<void>();
    void fire() {
      aborted = true;
      if (!signal.isCompleted) signal.complete();
    }

    abortTrigger?.then((_) => fire(), onError: (Object _) => fire());
    if (aborted) throw const UploadTransferAborted();
    final verified = _gate.awaitVerified();
    if (abortTrigger == null) {
      await verified;
    } else {
      // Future.any keeps listening to both, so a later error of either is
      // handled.
      await Future.any<Object?>([
        verified,
        signal.future.then<Object?>((_) => throw const UploadTransferAborted()),
      ]);
    }
    final connection = _gate.verifiedConnection;
    if (aborted) throw const UploadTransferAborted();
    try {
      return await send();
    } on ServerInstanceChangedException catch (e) {
      if (connection != null) _gate.reportDifferentInstance(connection, e);
      rethrow;
    }
  }

  Map<String, String> _pageQuery(String? after, int? limit) => {
    if (after != null) 'after': after,
    if (limit != null) 'limit': '$limit',
  };

  /// `POST /tracks/uploads` with [frozenBodyJson] (an
  /// [AllocationRequest.toFrozenJson] stored by `DurableSubmission`). 201 new
  /// and 200 exact replay answer alike.
  Future<AllocationResult> allocate(
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) => _gated(() async {
    final json = await _api.postJson(
      ['tracks', 'uploads'],
      body: jsonDecode(frozenBodyJson) as Map<String, dynamic>,
    );
    return AllocationResult.fromJson(json);
  }, abortTrigger);

  /// `GET /tracks/uploads/items/{item}`: the authoritative status.
  Future<UploadItem> getItem(String itemUuid, {Future<void>? abortTrigger}) => _gated(() async {
    final json = await _api.getJson(['tracks', 'uploads', 'items', itemUuid]);
    return UploadItem.fromJson(json);
  }, abortTrigger);

  /// `GET /tracks/uploads/{batch}`.
  Future<UploadBatch> getBatch(String batchUuid, {Future<void>? abortTrigger}) => _gated(() async {
    final json = await _api.getJson(['tracks', 'uploads', batchUuid]);
    return UploadBatch.fromJson(json);
  }, abortTrigger);

  /// `GET /tracks/uploads?after=&limit=` (server default limit 25, 1–100).
  Future<UploadBatchPage> listBatches({
    String? after,
    int? limit,
    Future<void>? abortTrigger,
  }) =>
      _gated(() async {
        final json = await _api.getJson(
          ['tracks', 'uploads'],
          query: _pageQuery(after, limit),
        );
        return UploadBatchPage.fromJson(json);
      }, abortTrigger);

  /// `GET /tracks/uploads/{batch}/items?after=&limit=`.
  Future<UploadItemPage> listItems(
    String batchUuid, {
    String? after,
    int? limit,
    Future<void>? abortTrigger,
  }) => _gated(() async {
    final json = await _api.getJson(
      ['tracks', 'uploads', batchUuid, 'items'],
      query: _pageQuery(after, limit),
    );
    return UploadItemPage.fromJson(json);
  }, abortTrigger);

  /// `DELETE /tracks/uploads/items/{item}`: cancel (a repeat answers 200).
  Future<UploadItem> cancelItem(String itemUuid, {Future<void>? abortTrigger}) => _gated(() async {
    final json = await _api.deleteJson(['tracks', 'uploads', 'items', itemUuid]);
    return UploadItem.fromJson(json);
  }, abortTrigger);

  /// `POST /tracks/uploads/items/{item}/commit`: [frozenBodyJson] is the
  /// frozen body with the operation id. 202 on acceptance and 200 on a
  /// replay are both success; one attempt only (the durable layer retries).
  Future<UploadItem> commit(
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) => _postItem(itemUuid, 'commit', jsonDecode(frozenBodyJson), abortTrigger);

  /// `POST /tracks/uploads/items/{item}/resolve-duplicate`: same shape and
  /// answers as [commit].
  Future<UploadItem> resolveDuplicate(
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) => _postItem(
    itemUuid,
    'resolve-duplicate',
    jsonDecode(frozenBodyJson),
    abortTrigger,
  );

  /// `POST /tracks/uploads/items/{item}/retry` with
  /// `{expected_review_version}`; answers the item.
  Future<UploadItem> retry(
    String itemUuid, {
    required int expectedReviewVersion,
    Future<void>? abortTrigger,
  }) => _postItem(itemUuid, 'retry', {
    'expected_review_version': expectedReviewVersion,
  }, abortTrigger);

  Future<UploadItem> _postItem(
    String itemUuid,
    String action,
    Object? body,
    Future<void>? abortTrigger,
  ) => _gated(() async {
    final json = await _api.postJson([
      'tracks',
      'uploads',
      'items',
      itemUuid,
      action,
    ], body: body as Map<String, dynamic>);
    return UploadItem.fromJson(json);
  }, abortTrigger);

  /// `PUT /tracks/uploads/items/{item}/content`: streams [source] checked
  /// against the allocation ([verifiedUploadBody]); the PUT's identity is
  /// the item plus [expectedSha256] / [expectedLength] (SC-14).
  Future<UploadItem> putContent(
    String itemUuid,
    UploadSource source, {
    required int expectedLength,
    required String expectedSha256,
    void Function(int sentBytes)? onProgress,
    Future<void>? abortTrigger,
  }) => _gated(() async {
    final json = await _api.putStream(
      ['tracks', 'uploads', 'items', itemUuid, 'content'],
      body: verifiedUploadBody(
        source,
        expectedLength: expectedLength,
        expectedSha256: expectedSha256,
      ),
      length: expectedLength,
      onProgress: onProgress,
      abortTrigger: abortTrigger,
    );
    return UploadItem.fromJson(json);
  }, abortTrigger);
}

/// The scope's uploads API: the bound client and the scope's binding gate.
final uploadsApiProvider = Provider<UploadsApi>(
  (ref) => UploadsApi(
    api: ref.read(boundApiClientProvider),
    gate: ref.read(serverBindingGateProvider),
  ),
);
