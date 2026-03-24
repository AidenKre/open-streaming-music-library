import 'package:frontend/providers/cover_art_cache_manager.dart';

void prefetchCoverArt(List<int> coverArtIds) {
  coverArtCache.prefetch(coverArtIds);
}
