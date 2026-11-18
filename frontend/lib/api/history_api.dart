import 'dart:convert';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/models/instance_stamp.dart';

/// The /history transport (Phase 5 §4).
class HistoryApi {
  HistoryApi({required ApiClient api}) : _api = api;

  final ApiClient _api;

  /// POST /history with [batch]'s exact body. Returns the raw `acknowledged`
  /// value (validated by `HistoryRepository.applyAck`); HTTP rejections are
  /// [ApiException]s (409 `history_event_conflict` carries
  /// `conflicting_event_uuids` in its details).
  ///
  /// The body is [batch]'s `jsonEncode` output; decoding it and letting the
  /// client re-encode it reproduces the same bytes. Retried on transient
  /// failures: the POST is idempotent by event UUID.
  Future<Object?> post(HistoryUploadBatch batch) async {
    final body = jsonDecode(utf8.decode(batch.body)) as Map<String, dynamic>;
    final json = await _api.postJson(['history'], body: body, retry: true);
    return json['acknowledged'];
  }

  /// GET /history/changes. A response of the wrong shape is a
  /// [FormatException].
  Future<HistoryPage> changes({required int after, int limit = 200}) async {
    final response = await _api.getJsonResponse(
      ['history', 'changes'],
      query: {'after': '$after', 'limit': '$limit'},
    );
    final json = response.body;
    final events = json['events'];
    if (events is! List) throw const FormatException('events is not a list');
    final nextCursor = json['nextCursor'];
    if (nextCursor != null && nextCursor is! int) {
      throw const FormatException('nextCursor is not an int or null');
    }
    // The same check and message as before the shared event reader.
    final latestRevision = json['latestRevision'];
    if (latestRevision is! int) {
      throw json.containsKey('latestRevision')
          ? const FormatException('latestRevision is not an int')
          : const FormatException('missing latestRevision');
    }
    return HistoryPage(
      events: [for (final e in events) HistoryServerEvent.fromJson(e)],
      nextCursor: nextCursor as int?,
      latestRevision: latestRevision,
      servedBy: instanceStampFrom(response.headers),
    );
  }
}
