import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';

/// The uploads block network work may act on (SC-03): only one read from
/// the server on this connection. Null when the server doesn't advertise
/// uploads or the block came from the cache (`fromCache`), which the UI may
/// show but which never starts an upload request.
UploadsFeature? uploadsFeatureForNetwork(
  AdvertisedFeature<UploadsFeature>? advertised,
) => advertised == null || advertised.fromCache ? null : advertised.block;
