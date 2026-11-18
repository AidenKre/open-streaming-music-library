import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/playback/audio_dependencies.dart';

void prefetchCoverArt(WidgetRef ref, List<int> coverArtIds) {
  ref.read(coverArtCacheProvider).prefetch(coverArtIds);
}
