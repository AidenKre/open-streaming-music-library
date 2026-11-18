import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';

/// A history event payload; `play` events carry measures, others none.
HistoryEventPayload historyEvent(
  String uuid, {
  String kind = 'play',
  String ref = 'track-1',
  int at = 1000,
}) => HistoryEventPayload(
  eventUuid: uuid,
  kind: kind,
  entityType: 'track',
  entityRef: ref,
  occurredAt: at,
  secondsPlayed: kind == 'play' ? 30.0 : null,
  trackLength: kind == 'play' ? 200.0 : null,
);

HistoryServerEvent serverEvent(HistoryEventPayload p, int revision) =>
    HistoryServerEvent(payload: p, revision: revision, receivedAt: 5000);

/// One final pulled page holding [events].
HistoryPage pulledPage(List<HistoryServerEvent> events) => HistoryPage(
  events: events,
  nextCursor: null,
  latestRevision: events.isEmpty ? 0 : events.last.revision,
);

/// "Keep server version" for [uuid] with its time changed to [at]: the one
/// legal payload UPDATE, which bumps `history_content` (SC-11).
Future<void> keepServerVersion(
  HistoryRepository history,
  String token,
  String uuid, {
  String kind = 'play',
  int at = 1,
  int revision = 1,
}) => history.keepServerVersion(
  token,
  serverEvent(historyEvent(uuid, kind: kind, at: at), revision),
);
