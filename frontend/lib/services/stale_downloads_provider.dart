import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';

/// Downloaded tracks that changed on the server since they were downloaded
/// (audio, tags or artwork) and haven't been dismissed. A genuine Drift watch
/// filtered in SQL, so it re-emits on the next `/changes` upsert with no
/// manual "bump a version counter" plumbing.
final staleDownloadsProvider = StreamProvider<List<TrackUI>>((ref) {
  return ref.watch(browseRepositoryProvider).watchStaleDownloads();
});
