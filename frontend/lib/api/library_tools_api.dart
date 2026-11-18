import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// A request's abort trigger fired before it was sent: nothing went out.
class LibraryToolsRequestAborted implements Exception {
  const LibraryToolsRequestAborted();

  @override
  String toString() => 'LibraryToolsRequestAborted';
}

/// `POST /tracks/deletions` was accepted (2xx) but its receipt could not be
/// read (8-R1-23): the server holds the job; only its body is unknown.
class DeletionReceiptUnreadable implements Exception {
  const DeletionReceiptUnreadable();

  @override
  String toString() => 'DeletionReceiptUnreadable';
}

/// A page read asked not to wait for the binding found it unverified:
/// nothing was sent (U33-B-02).
class LibraryToolsNotConnected implements Exception {
  const LibraryToolsNotConnected();

  @override
  String toString() => 'LibraryToolsNotConnected';
}

/// The /tracks/deletions and /tracks/duplicates transport (Phase 8 spec §4,
/// server as built).
///
/// Every call first waits for the binding gate
/// ([ServerBindingGate.awaitVerified]): nothing is sent to a server this
/// connection has not verified. Every call goes through the bound client
/// (`boundApiClientProvider`): an answer stamped by another instance throws
/// `ServerInstanceChangedException` (never a body); this class reports it to
/// the gate with the connection captured alongside the token, then
/// rethrows.
///
/// Errors otherwise: [ApiException] (SC-22 envelope) and [NetworkException].
/// No call retries a mutation on its own.
class LibraryToolsApi {
  LibraryToolsApi({required ApiClient api, required ServerBindingGate gate})
    : _api = api,
      _gate = gate;

  final ApiClient _api;
  final ServerBindingGate _gate;

  /// Waits for the gate, then runs [send]; an answer from another instance
  /// is reported to the gate before it is rethrown. [abortTrigger]
  /// (completing, with or without an error) ends a wait at the gate with
  /// [LibraryToolsRequestAborted] and sends nothing.
  ///
  /// A page read that must not wait ([waitForBinding] false) reads a
  /// withheld token (the token client refused: not verified, or offline) as
  /// not connected: its page shows the existing "needs a connection" state
  /// and reloads by itself. Every other call keeps the raw
  /// [TokenWithheldException] (sign-off OPEN-M-11, E8).
  Future<T> _gated<T>(
    Future<T> Function() send,
    Future<void>? abortTrigger, {
    bool waitForBinding = true,
  }) async {
    // A read that must not wait (U33-B-02): not verified, or not allowed by
    // the token client's own rule (URL, online), means not connected.
    if (!waitForBinding &&
        !_gate.allowsTokenTo(Uri.parse(_api.baseUrl))) {
      throw const LibraryToolsNotConnected();
    }
    var aborted = false;
    final signal = Completer<void>();
    void fire() {
      aborted = true;
      if (!signal.isCompleted) signal.complete();
    }

    abortTrigger?.then((_) => fire(), onError: (Object _) => fire());
    if (aborted) throw const LibraryToolsRequestAborted();
    final verified = _gate.awaitVerified();
    if (abortTrigger == null) {
      await verified;
    } else {
      await Future.any<Object?>([
        verified,
        signal.future.then<Object?>(
          (_) => throw const LibraryToolsRequestAborted(),
        ),
      ]);
    }
    final connection = _gate.verifiedConnection;
    if (aborted) throw const LibraryToolsRequestAborted();
    try {
      return await send();
    } on ServerInstanceChangedException catch (e) {
      if (connection != null) _gate.reportDifferentInstance(connection, e);
      rethrow;
    } on TokenWithheldException {
      if (!waitForBinding) throw const LibraryToolsNotConnected();
      rethrow;
    }
  }

  /// Completes when the binding is (or becomes) verified; a page that
  /// failed fast as not connected reloads then (review r1 R7). Errors when
  /// the gate closes.
  Future<void> whenVerified() => _gate.awaitVerified().then<void>((_) {});

  Map<String, String> _query({String? status, String? after, int? limit}) => {
    if (status != null) 'status': status,
    if (after != null) 'after': after,
    if (limit != null) 'limit': '$limit',
  };

  /// `POST /tracks/deletions/preview`.
  Future<DeletionPreviewDto> preview(
    List<DeletionTargetDto> targets, {
    Future<void>? abortTrigger,
  }) => _gated(() async {
    final json = await _api.postJson(
      ['tracks', 'deletions', 'preview'],
      body: DeletionPreviewRequestDto(targets: targets).toJson(),
    );
    return DeletionPreviewDto.fromJson(json);
  }, abortTrigger);

  /// `POST /tracks/deletions` with [frozenBodyJson] exactly (a
  /// [DeletionJobRequestDto.toFrozenJson]); 202 new and exact replay alike.
  Future<DeletionJobDto> createJob(
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) => _gated(() async {
    final Map<String, dynamic> json;
    try {
      json = await _api.postJson(
        ['tracks', 'deletions'],
        body: jsonDecode(frozenBodyJson) as Map<String, dynamic>,
      );
    } on ApiException catch (e) {
      // A 2xx whose body is not JSON / not an object: accepted, receipt
      // unreadable (8-R1-23).
      if (e.statusCode >= 200 && e.statusCode < 300) {
        throw const DeletionReceiptUnreadable();
      }
      rethrow;
    }
    try {
      return DeletionJobDto.fromJson(json);
    } on FormatException {
      throw const DeletionReceiptUnreadable();
    }
  }, abortTrigger);

  /// `GET /tracks/deletions/{operation}`.
  Future<DeletionJobDto> getJob(
    String operationUuid, {
    Future<void>? abortTrigger,
  }) => _gated(() async {
    final json = await _api.getJson(['tracks', 'deletions', operationUuid]);
    return DeletionJobDto.fromJson(json);
  }, abortTrigger);

  /// `GET /tracks/deletions?after=&limit=`.
  Future<DeletionJobPageDto> listJobs({
    String? after,
    int? limit,
    Future<void>? abortTrigger,
    bool waitForBinding = true,
  }) => _gated(() async {
    final json = await _api.getJson(
      ['tracks', 'deletions'],
      query: _query(after: after, limit: limit),
    );
    return DeletionJobPageDto.fromJson(json);
  }, abortTrigger, waitForBinding: waitForBinding);

  /// `GET /tracks/duplicates?status=&after=&limit=`.
  Future<DuplicatePairPageDto> listDuplicates({
    String? status,
    String? after,
    int? limit,
    Future<void>? abortTrigger,
    bool waitForBinding = true,
  }) => _gated(() async {
    final json = await _api.getJson(
      ['tracks', 'duplicates'],
      query: _query(status: status, after: after, limit: limit),
    );
    return DuplicatePairPageDto.fromJson(json);
  }, abortTrigger, waitForBinding: waitForBinding);

  /// `GET /tracks/duplicates/summary`.
  Future<DuplicateSummaryDto> duplicateSummary({
    Future<void>? abortTrigger,
    bool waitForBinding = true,
  }) => _gated(() async {
    final json = await _api.getJson(['tracks', 'duplicates', 'summary']);
    return DuplicateSummaryDto.fromJson(json);
  }, abortTrigger, waitForBinding: waitForBinding);

  /// `POST /tracks/duplicates/dismiss`.
  Future<DuplicatePairStatusDto> dismissPair(
    String uuidA,
    String uuidB, {
    Future<void>? abortTrigger,
  }) => _pairAction('dismiss', uuidA, uuidB, abortTrigger);

  /// `POST /tracks/duplicates/restore`.
  Future<DuplicatePairStatusDto> restorePair(
    String uuidA,
    String uuidB, {
    Future<void>? abortTrigger,
  }) => _pairAction('restore', uuidA, uuidB, abortTrigger);

  Future<DuplicatePairStatusDto> _pairAction(
    String action,
    String uuidA,
    String uuidB,
    Future<void>? abortTrigger,
  ) => _gated(() async {
    final json = await _api.postJson(
      ['tracks', 'duplicates', action],
      body: {'uuid_a': uuidA, 'uuid_b': uuidB},
    );
    return DuplicatePairStatusDto.fromJson(json);
  }, abortTrigger);
}

final libraryToolsApiProvider = Provider<LibraryToolsApi>(
  (ref) => LibraryToolsApi(
    api: ref.read(boundApiClientProvider),
    gate: ref.read(serverBindingGateProvider),
  ),
);
