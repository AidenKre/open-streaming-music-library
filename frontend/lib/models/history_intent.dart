import 'package:frontend/models/collection_ref.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

/// The entity a user explicitly asked to play (Phase 5 §6). Null intent on
/// a request means no clicked entity (automations, shuffle-all).
class HistoryIntent {
  const HistoryIntent(this.entityType, this.entityRef);
  const HistoryIntent.track(String trackUuid) : this('track', trackUuid);

  /// SC-06 model function: the clicked entity of a scope action. A track
  /// (or a one-track list) is a track click. Album/artist scopes give one
  /// collection intent via [CollectionRef] (never one click per member
  /// track), or null until SC-04 readiness holds for [binding].
  static HistoryIntent? forScope(
          LibraryScope scope, ServerBindingRecord? binding) =>
      switch (scope) {
        TrackScope(:final track) => HistoryIntent.track(track.uuidId),
        TracksScope(:final tracks) when tracks.length == 1 =>
          HistoryIntent.track(tracks.single.uuidId),
        AlbumScope() => _collection('album', scope, binding),
        ArtistScope() => _collection('artist', scope, binding),
        _ => null,
      };

  static HistoryIntent? _collection(
      String type, LibraryScope scope, ServerBindingRecord? binding) {
    final ref = CollectionRef.fromScope(scope, binding);
    return ref == null ? null : HistoryIntent(type, ref.format());
  }

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
