import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';

/// Downloads that failed to play although their file exists (Phase 5
/// decision 6). A Drift watch: a re-download or a Delete drops the row.
final damagedDownloadsProvider = StreamProvider<List<TrackUI>>((ref) {
  return ref.watch(browseRepositoryProvider).watchDamagedDownloads();
});
