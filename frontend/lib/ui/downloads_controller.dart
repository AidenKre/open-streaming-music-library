import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/settings_service.dart';

/// Download-queue, stale- and damaged-download input (SC-26
/// `DownloadsController`): the Downloading page, the stale-downloads sheet
/// and the Downloaded page's damaged section. Library-scope
/// downloads/deletes stay on `LibraryActions`.
abstract interface class DownloadsControls {
  void clearFinished();

  void cancelQueued(String uuidId);

  Future<void> dismissStale(String uuidId);

  Future<void> dismissAllStale(Iterable<String> uuidIds);

  /// Re-download stale copies; how many of [tracks] could not be queued.
  Future<({int failed, int total})> redownloadStale(List<TrackUI> tracks);

  /// Re-download damaged copies at the default download quality; the new
  /// download replaces the damaged file (decision 6).
  Future<void> redownloadDamaged(List<TrackUI> tracks);

  /// Delete a damaged copy (its kept file) for good.
  Future<void> deleteDamaged(String uuidId);
}

final downloadsControlsProvider = Provider<DownloadsControls>(
  (ref) => DownloadsController(ref),
);

class DownloadsController implements DownloadsControls {
  DownloadsController(this._ref);

  final Ref _ref;

  @override
  void clearFinished() => _ref.read(downloadManagerProvider).clearFinished();

  @override
  void cancelQueued(String uuidId) =>
      _ref.read(downloadManagerProvider).cancelQueued(uuidId);

  @override
  Future<void> dismissStale(String uuidId) =>
      _ref.read(databaseProvider).dismissStaleDownload(uuidId);

  @override
  Future<void> dismissAllStale(Iterable<String> uuidIds) =>
      _ref.read(databaseProvider).dismissStaleDownloads(uuidIds);

  @override
  Future<({int failed, int total})> redownloadStale(
    List<TrackUI> tracks,
  ) async {
    final failed = await _ref
        .read(downloadManagerProvider)
        .redownloadStale(
          tracks,
          fallbackQuality: _ref.read(downloadQualityProvider),
        );
    return (failed: failed, total: tracks.length);
  }

  @override
  Future<void> redownloadDamaged(List<TrackUI> tracks) => _ref
      .read(downloadManagerProvider)
      .redownloadDamaged(
        tracks,
        fallbackQuality: _ref.read(downloadQualityProvider),
      );

  @override
  Future<void> deleteDamaged(String uuidId) =>
      _ref.read(downloadManagerProvider).deleteDownload(uuidId);
}
