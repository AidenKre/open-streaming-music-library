import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/playback_availability.dart';

PlaybackAvailability _of(bool offline, int downloaded, int total) =>
    PlaybackAvailability.of(
      offline: offline,
      downloaded: downloaded,
      total: total,
    );

void main() {
  group('PlaybackAvailability.of: online/offline x remote/partial/downloaded',
      () {
    // (offline, downloaded, total) -> coverage, canPlay, canDownload,
    // hasAnyDownloaded, isFullyDownloaded. Phase 4 keeps today's offline rule:
    // play/queue only when the whole scope is downloaded (Phase 6 makes
    // partial playable).
    final table = <(bool, int, int), (LocalCoverage, bool, bool, bool, bool)>{
      (false, 0, 4): (LocalCoverage.remote, true, true, false, false),
      (false, 2, 4): (LocalCoverage.partial, true, true, true, false),
      (false, 4, 4): (LocalCoverage.downloaded, true, false, true, true),
      (true, 0, 4): (LocalCoverage.remote, false, false, false, false),
      (true, 2, 4): (LocalCoverage.partial, false, false, true, false),
      (true, 4, 4): (LocalCoverage.downloaded, true, false, true, true),
      // An empty scope is never "fully downloaded".
      (false, 0, 0): (LocalCoverage.remote, true, true, false, false),
      (true, 0, 0): (LocalCoverage.remote, false, false, false, false),
    };
    table.forEach((input, expected) {
      final (offline, downloaded, total) = input;
      test('offline=$offline $downloaded/$total', () {
        final a = _of(offline, downloaded, total);
        expect(a.isUnknown, isFalse);
        expect(a.coverage, expected.$1);
        expect(a.canPlay, expected.$2, reason: 'canPlay');
        expect(a.canDownload, expected.$3, reason: 'canDownload');
        expect(a.hasAnyDownloaded, expected.$4, reason: 'hasAnyDownloaded');
        expect(a.isFullyDownloaded, expected.$5, reason: 'isFullyDownloaded');
      });
    });
  });

  group('unknown (counts still loading) is not zero', () {
    test('offline unknown is not yet playable and claims nothing downloaded',
        () {
      const a = PlaybackAvailability.unknown(offline: true);
      expect(a.isUnknown, isTrue);
      expect(a.coverage, isNull);
      expect(a.canPlay, isFalse);
      expect(a.canDownload, isFalse);
      expect(a.hasAnyDownloaded, isFalse);
      expect(a.isFullyDownloaded, isFalse);
      // Distinct from a known "nothing downloaded".
      expect(a == _of(true, 0, 4), isFalse);
    });

    test('online unknown stays playable (online never depended on counts)',
        () {
      const a = PlaybackAvailability.unknown(offline: false);
      expect(a.isUnknown, isTrue);
      expect(a.canPlay, isTrue);
      expect(a.canDownload, isTrue);
      expect(a.isFullyDownloaded, isFalse);
    });
  });

  test('value equality', () {
    expect(_of(true, 2, 4), _of(true, 1, 3));
    expect(_of(true, 2, 4).hashCode, _of(true, 1, 3).hashCode);
    expect(_of(true, 2, 4) == _of(false, 2, 4), isFalse);
    expect(
      const PlaybackAvailability.unknown(offline: true),
      // ignore: prefer_const_constructors
      PlaybackAvailability.unknown(offline: true),
    );
  });
}
