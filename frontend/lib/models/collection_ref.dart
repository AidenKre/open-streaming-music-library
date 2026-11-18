import 'package:flutter/foundation.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

/// A collection history reference (SC-04, Phase 6 §4):
/// `<server_instance_id>:<positive canonical decimal id>`.
///
/// The only formatter and parser of collection refs in the app.
@immutable
final class CollectionRef {
  const CollectionRef._(this.instanceId, this.id);

  final String instanceId;
  final int id;

  /// Builds a ref for an album or artist scope. Returns null unless the
  /// binding has an instance id and its catalog is reconciled (SC-04), the
  /// scope is a collection scope, and the id is positive.
  static CollectionRef? fromScope(
    LibraryScope scope,
    ServerBindingRecord? binding,
  ) {
    if (binding == null) return null;
    final instanceId = binding.instanceId;
    if (instanceId == null || instanceId.isEmpty) return null;
    if (!binding.catalogReconciled) return null;
    final int id;
    switch (scope) {
      case AlbumScope():
        id = scope.albumId;
      case ArtistScope():
        id = scope.artistId;
      case TrackScope():
      case TracksScope():
        return null;
    }
    if (id <= 0) return null;
    return CollectionRef._(instanceId, id);
  }

  /// Parses exactly `<boundInstanceId>:<canonical positive decimal>`;
  /// anything else (other instance, leading zeros, signs, overflow) is null.
  static CollectionRef? tryParse(
    String ref, {
    required String boundInstanceId,
  }) {
    if (boundInstanceId.isEmpty) return null;
    final prefix = '$boundInstanceId:';
    if (!ref.startsWith(prefix)) return null;
    final idPart = ref.substring(prefix.length);
    if (idPart.isEmpty) return null;
    for (final unit in idPart.codeUnits) {
      if (unit < 0x30 || unit > 0x39) return null;
    }
    final id = int.tryParse(idPart);
    if (id == null || id <= 0 || id.toString() != idPart) return null;
    return CollectionRef._(boundInstanceId, id);
  }

  String format() => '$instanceId:$id';

  @override
  bool operator ==(Object other) =>
      other is CollectionRef && other.instanceId == instanceId && other.id == id;

  @override
  int get hashCode => Object.hash(instanceId, id);

  @override
  String toString() => 'CollectionRef(${format()})';
}
