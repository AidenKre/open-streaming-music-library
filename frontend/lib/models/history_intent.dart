import 'package:frontend/models/library_scope.dart';

/// The entity a user explicitly asked to play (Phase 5 §6). Null intent on
/// a request means no clicked entity (automations, shuffle-all).
class HistoryIntent {
  const HistoryIntent(this.entityType, this.entityRef);
  const HistoryIntent.track(String trackUuid) : this('track', trackUuid);

  /// SC-06 model function: the clicked entity of a scope action. A track
  /// (or a one-track list) is a track click; album/artist intents arrive
  /// with Phase 6's collection producers, so they are null here (never one
  /// click per member track).
  static HistoryIntent? forScope(LibraryScope scope) => switch (scope) {
        TrackScope(:final track) => HistoryIntent.track(track.uuidId),
        TracksScope(:final tracks) when tracks.length == 1 =>
          HistoryIntent.track(tracks.single.uuidId),
        _ => null,
      };
  final String entityType;
  final String entityRef;

  @override
  bool operator ==(Object other) =>
      other is HistoryIntent &&
      other.entityType == entityType &&
      other.entityRef == entityRef;

  @override
  int get hashCode => Object.hash(entityType, entityRef);

  @override
  String toString() => 'HistoryIntent($entityType, $entityRef)';
}
