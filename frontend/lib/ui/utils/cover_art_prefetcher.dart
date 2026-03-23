import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:frontend/api/api_client.dart';

void prefetchCoverArt(BuildContext context, List<int> coverArtIds) {
  for (final id in coverArtIds) {
    precacheImage(
      CachedNetworkImageProvider(ApiClient.instance.coverArtUrl(id)),
      context,
    );
  }
}
