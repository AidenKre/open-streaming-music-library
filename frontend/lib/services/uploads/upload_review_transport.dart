// The seam for review actions (commit, resolve-duplicate). The manager sends
// through this interface; the default is the HTTP transport over
// [UploadsApi].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/uploads_api.dart';

/// Which review action a request is.
enum ReviewActionKind { commit, resolveDuplicate }

/// Thrown by [UnavailableUploadReviewTransport]: no review route to send to.
class UploadReviewRouteUnavailable implements Exception {
  const UploadReviewRouteUnavailable();
}

/// Sends one frozen review request and returns the server's item JSON.
abstract interface class UploadReviewTransport {
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  });
}

/// Every send throws [UploadReviewRouteUnavailable].
class UnavailableUploadReviewTransport implements UploadReviewTransport {
  const UnavailableUploadReviewTransport();
  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) => throw const UploadReviewRouteUnavailable();
}

/// Sends review requests through [UploadsApi] and returns the item as JSON.
class HttpUploadReviewTransport implements UploadReviewTransport {
  HttpUploadReviewTransport(this._api);
  final UploadsApi _api;

  @override
  Future<Map<String, dynamic>> send(
    ReviewActionKind kind,
    String itemUuid,
    String frozenBodyJson, {
    Future<void>? abortTrigger,
  }) async {
    final item = switch (kind) {
      ReviewActionKind.commit => await _api.commit(
        itemUuid,
        frozenBodyJson,
        abortTrigger: abortTrigger,
      ),
      ReviewActionKind.resolveDuplicate => await _api.resolveDuplicate(
        itemUuid,
        frozenBodyJson,
        abortTrigger: abortTrigger,
      ),
    };
    return item.toJson();
  }
}

final uploadReviewTransportProvider = Provider<UploadReviewTransport>(
  (ref) => HttpUploadReviewTransport(ref.read(uploadsApiProvider)),
);
