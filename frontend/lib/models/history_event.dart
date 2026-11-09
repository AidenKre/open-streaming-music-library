import 'package:flutter/foundation.dart';

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

/// An event as the server returns it from GET /history/changes.
@immutable
class HistoryServerEvent {
  const HistoryServerEvent({
    required this.payload,
    required this.revision,
    required this.receivedAt,
  });

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
  });

  final List<HistoryServerEvent> events;
  final int? nextCursor;
  final int latestRevision;
}
