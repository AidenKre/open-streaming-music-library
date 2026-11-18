import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// A request's abort trigger fired before it was sent: nothing went out.
class LibraryToolsRequestAborted implements Exception {
  const LibraryToolsRequestAborted();

  @override
  String toString() => 'LibraryToolsRequestAborted';
}

/// `POST /tracks/deletions` was accepted (2xx) but its receipt could not be
/// read: the server holds the job; only its body is unknown.
class DeletionReceiptUnreadable implements Exception {
  const DeletionReceiptUnreadable();

  @override
  String toString() => 'DeletionReceiptUnreadable';
}

/// A page read asked not to wait for the binding found it unverified:
/// nothing was sent (U33-B-02).
typedef LibraryToolsNotConnected = BindingNotVerified;

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

  /// Waits for the gate without a limit, then runs [send]
  /// ([sendWhenVerified]); an answer from another instance is reported to
  /// the gate before it is rethrown. [abortTrigger] (completing, with or
  /// without an error) ends a wait at the gate with
  /// [LibraryToolsRequestAborted] and sends nothing.
  ///
  /// A page read that must not wait ([waitForBinding] false, U33-B-02)
  /// fails at once unless the binding is verified now and the token
  /// client's own rule (URL, online) allows the request: not connected,
  /// with its reason (Phase 9, 9-R2-04; sign-off OPEN-M-11, E8). It also
  /// reads a token withheld at the send (the token client refused: not
  /// verified, or offline) as not connected: its page shows the existing
  /// "needs a connection" state and reloads by itself. Every other call
  /// keeps the raw [TokenWithheldException] (sign-off OPEN-M-11, E8).
  Future<T> _gated<T>(
    Future<T> Function() send,
    Future<void>? abortTrigger, {
    bool waitForBinding = true,
  }) =>
      // Future.sync: a base URL that does not parse fails the call's future,
      // as every other refusal does; it is never thrown at the caller.
      Future.sync(
        () => sendWhenVerified(
          _gate,
          send,
          wait: waitForBinding
              ? BindingWait.untilVerified
              : BindingWait.failFast,
          url: waitForBinding ? null : Uri.parse(_api.baseUrl),
          abortTrigger: abortTrigger,
          abortError: const LibraryToolsRequestAborted(),
          withheldAsNotVerified: !waitForBinding,
        ),
      );

  /// Completes when the binding is (or becomes) verified; a page that
  /// failed fast as not connected reloads then, by itself. Errors when the
  /// gate closes.
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
      // A 2xx whose body is not JSON / not an object: the job was accepted,
      // only its receipt is unreadable.
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
