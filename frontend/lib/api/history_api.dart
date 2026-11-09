import 'dart:convert';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';

/// The /history transport (Phase 5 §4).
class HistoryApi {
  HistoryApi({ApiClient? api}) : _api = api ?? ApiClient.instance;

  final ApiClient _api;

  /// POST /history with [batch]'s exact body. Returns the raw `acknowledged`
  /// value (validated by [HistoryRepository.applyAck]); HTTP rejections are
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
    final json = await _api.getJson(
      ['history', 'changes'],
      query: {'after': '$after', 'limit': '$limit'},
    );
    final events = json['events'];
    if (events is! List) throw const FormatException('events is not a list');
    final nextCursor = json['nextCursor'];
    if (nextCursor != null && nextCursor is! int) {
      throw const FormatException('nextCursor is not an int or null');
    }
    return HistoryPage(
      events: [for (final e in events) _event(e)],
      nextCursor: nextCursor as int?,
      latestRevision: _int(json, 'latestRevision'),
    );
  }

  static HistoryServerEvent _event(Object? raw) {
    if (raw is! Map) throw const FormatException('event is not an object');
    return HistoryServerEvent(
      payload: HistoryEventPayload(
        eventUuid: _string(raw, 'event_uuid'),
        kind: _string(raw, 'kind'),
        entityType: _string(raw, 'entity_type'),
        entityRef: _string(raw, 'entity_ref'),
        occurredAt: _int(raw, 'occurred_at'),
        secondsPlayed: _measure(raw, 'seconds_played'),
        trackLength: _measure(raw, 'track_length'),
      ),
      revision: _int(raw, 'revision'),
      receivedAt: _int(raw, 'received_at'),
    );
  }

  static void _require(Map raw, String key) {
    if (!raw.containsKey(key)) throw FormatException('missing $key');
  }

  static int _int(Map raw, String key) {
    _require(raw, key);
    final v = raw[key];
    if (v is! int) throw FormatException('$key is not an int');
    return v;
  }

  static String _string(Map raw, String key) {
    _require(raw, key);
    final v = raw[key];
    if (v is! String) throw FormatException('$key is not a string');
    return v;
  }

  /// A measure: a number (as double) or null; unknown is not zero.
  static double? _measure(Map raw, String key) {
    _require(raw, key);
    final v = raw[key];
    if (v == null) return null;
    if (v is! num) throw FormatException('$key is not a number or null');
    return v.toDouble();
  }
}
