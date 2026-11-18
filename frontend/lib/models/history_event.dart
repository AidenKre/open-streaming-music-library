import 'package:flutter/foundation.dart';

/// The history event kinds this app writes and reads, as stored and sent
/// (`history_events.kind`, the wire `kind`). Strings, not an enum: a kind
/// from a newer server stays a valid event.
abstract final class HistoryKind {
  /// A listen (Phase 5): the listening statistics and suggestions read it.
  static const play = 'play';

  /// An accepted play request for a track, album or artist (the click
  /// recorder writes it): Recently played reads it.
  static const clicked = 'clicked';
}

/// Why an event is held back from upload (`history_sync_failures.reason`).
abstract final class HistoryFailureReason {
  /// The server answered 409: it holds another payload under the event id.
  static const conflict = 'conflict';

  /// The server refused the event (413 for a single event, or 422).
  static const rejected = 'rejected';

  /// The event alone is larger than an upload batch may be.
  static const oversized = 'oversized';
}

/// The immutable history event payload (Phase 5 §3). `occurredAt` is Unix
/// milliseconds UTC; measures are seconds, null when unknown (never 0).
@immutable
class HistoryEventPayload {
  const HistoryEventPayload({
    required this.eventUuid,
    required this.kind,
    required this.entityType,
    required this.entityRef,
    required this.occurredAt,
    this.secondsPlayed,
    this.trackLength,
  });

  final String eventUuid;
  final String kind;
  final String entityType;
  final String entityRef;
  final int occurredAt;
  final double? secondsPlayed;
  final double? trackLength;

  /// The wire object (snake_case keys, the POST /history event shape).
  Map<String, Object?> toJson() => {
    'event_uuid': eventUuid,
    'kind': kind,
    'entity_type': entityType,
    'entity_ref': entityRef,
    'occurred_at': occurredAt,
    'seconds_played': secondsPlayed,
    'track_length': trackLength,
  };

  /// The one strict reader of [toJson]'s shape, for the /history/changes
  /// transport and the listen drafts' stored payload: every key present;
  /// the strings and `occurred_at` (an int) of their exact types; a measure a
  /// number (read as a double) or null (unknown is not zero). Anything else
  /// is a [FormatException].
  factory HistoryEventPayload.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('event is not an object');
    return HistoryEventPayload(
      eventUuid: _string(json, 'event_uuid'),
      kind: _string(json, 'kind'),
      entityType: _string(json, 'entity_type'),
      entityRef: _string(json, 'entity_ref'),
      occurredAt: _int(json, 'occurred_at'),
      secondsPlayed: _measure(json, 'seconds_played'),
      trackLength: _measure(json, 'track_length'),
    );
  }

  /// Typed payload equality (server metadata excluded).
  bool samePayload(HistoryEventPayload other) =>
      eventUuid == other.eventUuid &&
      kind == other.kind &&
      entityType == other.entityType &&
      entityRef == other.entityRef &&
      occurredAt == other.occurredAt &&
      secondsPlayed == other.secondsPlayed &&
      trackLength == other.trackLength;

  @override
  bool operator ==(Object other) =>
      other is HistoryEventPayload && samePayload(other);

  @override
  int get hashCode => Object.hash(
    eventUuid, kind, entityType, entityRef, occurredAt, secondsPlayed,
    trackLength,
  );

  @override
  String toString() => 'HistoryEventPayload(${toJson()})';
}

void _require(Map raw, String key) {
  if (!raw.containsKey(key)) throw FormatException('missing $key');
}

int _int(Map raw, String key) {
  _require(raw, key);
  final v = raw[key];
  if (v is! int) throw FormatException('$key is not an int');
  return v;
}

String _string(Map raw, String key) {
  _require(raw, key);
  final v = raw[key];
  if (v is! String) throw FormatException('$key is not a string');
  return v;
}

/// A measure: a number (as double) or null; unknown is not zero.
double? _measure(Map raw, String key) {
  _require(raw, key);
  final v = raw[key];
  if (v == null) return null;
  if (v is! num) throw FormatException('$key is not a number or null');
  return v.toDouble();
}

/// An event as the server returns it from GET /history/changes.
@immutable
class HistoryServerEvent {
  const HistoryServerEvent({
    required this.payload,
    required this.revision,
    required this.receivedAt,
  });

  /// A GET /history/changes event: the payload ([HistoryEventPayload.fromJson])
  /// plus the integer `revision` and `received_at`. Anything else is a
  /// [FormatException].
  factory HistoryServerEvent.fromJson(Object? json) {
    final payload = HistoryEventPayload.fromJson(json);
    final map = json as Map;
    return HistoryServerEvent(
      payload: payload,
      revision: _int(map, 'revision'),
      receivedAt: _int(map, 'received_at'),
    );
  }

  final HistoryEventPayload payload;
  final int revision;
  final int receivedAt;
}

/// One GET /history/changes page.
@immutable
class HistoryPage {
  const HistoryPage({
    required this.events,
    required this.nextCursor,
    required this.latestRevision,
    this.servedBy,
  });

  final List<HistoryServerEvent> events;
  final int? nextCursor;
  final int latestRevision;

  /// The server instance that served this page (SC-01 rule 6); null when
  /// the response carried no stamp.
  final String? servedBy;
}

/// One upload batch: the events and the exact UTF-8 request body.
class HistoryUploadBatch {
  HistoryUploadBatch(this.events, this.body);
  final List<HistoryEventPayload> events;
  final Uint8List body;
  List<String> get eventUuids => [for (final e in events) e.eventUuid];
}
