// SC-03 / 7B.1a: "The cached blob must never enable a network action while
// offline." The uploads block decides whether upload network work may start
// only when it came from this connection's live /app/info answer; a block
// from the cache (or the built-in default) may be shown, never acted on.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/uploads_network_feature.dart';

const _block = UploadsFeature(
  version: 1,
  limits: UploadLimits(maxFilesPerBatch: 100, receivesPerUser: 1),
);

void main() {
  test('a live block allows network work and carries its limits', () {
    final feature = uploadsFeatureForNetwork(
      const AdvertisedFeature(_block, fromCache: false),
    );

    expect(feature, same(_block));
    expect(feature!.limits.receivesPerUser, 1);
  });

  test('a cached block never starts network work', () {
    expect(
      uploadsFeatureForNetwork(const AdvertisedFeature(_block, fromCache: true)),
      isNull,
    );
  });

  test('no block (server without uploads) never starts network work', () {
    expect(uploadsFeatureForNetwork(null), isNull);
  });
}
