import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/app_info_service.dart';

/// One SC-03 feature block as this scope knows it.
class AdvertisedFeature<T> {
  const AdvertisedFeature(this.block, {required this.fromCache});
  final T block;

  /// The block came from the cached blob or the built-in default, not from a
  /// server response on this read. A network runner must not start work on a
  /// `fromCache` block; the UI may show it.
  final bool fromCache;
}

/// `history`, or null when the server doesn't advertise it.
final historyFeatureProvider =
    FutureProvider<AdvertisedFeature<HistoryFeature>?>((ref) async {
      final info = await ref.watch(appInfoProvider.future);
      final block = info.features.history;
      return block == null
          ? null
          : AdvertisedFeature(block, fromCache: info.fromCache);
    });

/// `uploads`, or null when the server doesn't advertise it.
final uploadsFeatureProvider =
    FutureProvider<AdvertisedFeature<UploadsFeature>?>((ref) async {
      final info = await ref.watch(appInfoProvider.future);
      final block = info.features.uploads;
      return block == null
          ? null
          : AdvertisedFeature(block, fromCache: info.fromCache);
    });

/// The server advertises `uploads`, from a live answer or the cache (offline,
/// the page still shows cached statuses). False while loading, on error, or
/// with no block.
final uploadsAdvertisedProvider = Provider<bool>(
  (ref) => ref.watch(uploadsFeatureProvider).value != null,
);
