import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';

/// Downloaded tracks whose server master has changed since the download
/// (e.g. a Phase 2 conversion) and haven't been dismissed. Reuses
/// `BrowseRepository.watchTracks(downloadedOnly: true)` -- a genuine Drift
/// stream, so this auto-updates on the next `/changes` upsert with no manual
/// "bump a version counter" plumbing needed (unlike the download-count
/// providers, which wrap a non-reactive imperative query).
final staleDownloadsProvider = StreamProvider<List<TrackUI>>((ref) {
  return ref
      .watch(browseRepositoryProvider)
      .watchTracks(downloadedOnly: true)
      .map((tracks) => tracks.where((t) => t.isStaleDownload).toList());
});
