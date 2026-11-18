// 8B.3 S1: the pair rules of Possible duplicates.
//  * Spec §6 "List": "Each row shows the pair side by side with the differing
//    fields highlighted (a NULL/unknown value is shown as unknown and never
//    counts as a difference, SC-16l; format, bitrate, sample rate, duration,
//    album, added date) and a badge: Exact copy, Very likely same recording
//    or Possibly same song."
//  * Brief: fingerprint matches are advisory; only an exact pair is called an
//    exact copy, never "duplicate" as a fact.
//  * 8A.4 hand-over: order is band exact -> strong -> possible, then score
//    descending, then uuid_a, uuid_b; score is null for an exact pair.
//  * Spec §6: the row is "available when library_tools.duplicate_review is
//    true".
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/duplicates/duplicates_review.dart';
import 'package:frontend/services/feature_providers.dart';

// The product formats "Added" in local time, so the instants are built from
// local wall-clock times: 2026-03-15 12:00 and 13:00, and 2026-03-18 12:00 in
// whatever zone the machine runs, the same local day in every zone.
int _localEpochS(int day, int hour) =>
    DateTime(2026, 3, day, hour).millisecondsSinceEpoch ~/ 1000;
final _mar15noon = _localEpochS(15, 12);
final _mar15one = _localEpochS(15, 13);
final _mar18noon = _localEpochS(18, 12);

DuplicatePairTrackDto track(
  String uuid, {
  int revision = 1,
  String? title = 'Song',
  String? artist = 'Band',
  String? album = 'Album',
  String? codec = 'flac',
  double? bitrateKbps = 900.4,
  int? sampleRateHz = 44100,
  int? channels = 2,
  double? durationS = 185.6,
  int? addedAt,
  bool? masterPresent = true,
}) => DuplicatePairTrackDto(
  uuidId: uuid,
  revision: revision,
  title: title,
  artist: artist,
  album: album,
  codec: codec,
  bitrateKbps: bitrateKbps,
  sampleRateHz: sampleRateHz,
  channels: channels,
  durationS: durationS,
  addedAt: addedAt ?? _mar15noon,
  masterPresent: masterPresent,
);

DuplicatePairDto pair(
  String a,
  String b, {
  String kind = 'fingerprint',
  String band = 'strong',
  double? score = 0.9,
  String status = 'open',
}) => DuplicatePairDto(
  uuidA: a,
  uuidB: b,
  kind: kind,
  band: band,
  score: score,
  status: status,
  detectedAt: 1,
  trackA: track(a),
  trackB: track(b),
);

void main() {
  group('badge', () {
    test('the three bands read as the spec words them', () {
      expect(
        duplicateBadgeText(pair('a', 'b', kind: 'exact', band: 'exact', score: null)),
        'Exact copy',
      );
      expect(
        duplicateBadgeText(pair('a', 'b', band: 'strong')),
        'Very likely same recording',
      );
      expect(
        duplicateBadgeText(pair('a', 'b', band: 'possible', score: 0.6)),
        'Possibly same song',
      );
    });

    test('only an exact pair is called an exact copy; nothing is called a '
        'duplicate as a fact', () {
      // A fingerprint pair is never an exact copy, whatever band it carries.
      final odd = duplicateBadgeText(
        pair('a', 'b', kind: 'fingerprint', band: 'exact'),
      );
      expect(odd, isNot('Exact copy'));
      final unknown = duplicateBadgeText(pair('a', 'b', band: 'someday'));
      expect(unknown, isNot('Exact copy'));
      for (final text in [odd, unknown]) {
        expect(text.toLowerCase(), isNot(contains('duplicate')));
        expect(text, isNotEmpty);
      }
    });

    test('an unknown band string is kept apart from the three bands', () {
      expect(duplicateBandOf('exact'), DuplicateBand.exact);
      expect(duplicateBandOf('strong'), DuplicateBand.strong);
      expect(duplicateBandOf('possible'), DuplicateBand.possible);
      expect(duplicateBandOf('someday'), DuplicateBand.unknown);
    });
  });

  group('file status (sign-off OPEN-A-11)', () {
    test('a present file needs no line', () {
      expect(copyFileStatusText(track('a', masterPresent: true)), isNull);
    });

    test('a file really gone says it is missing', () {
      expect(
        copyFileStatusText(track('a', masterPresent: false)),
        'File missing on the server',
      );
    });

    test('a file the server could not check is unknown, never missing', () {
      expect(
        copyFileStatusText(track('a', masterPresent: null)),
        'File status unknown',
      );
    });
  });

  group('field words', () {
    final t = track('a');

    test('each field reads plainly', () {
      expect(duplicateFieldText(t, DuplicateField.format), 'FLAC');
      expect(duplicateFieldText(t, DuplicateField.bitrate), '900 kbps');
      expect(duplicateFieldText(t, DuplicateField.sampleRate), '44.1 kHz');
      expect(
        duplicateFieldText(track('x', sampleRateHz: 48000), DuplicateField.sampleRate),
        '48 kHz',
      );
      expect(duplicateFieldText(t, DuplicateField.duration), '3:05');
      expect(duplicateFieldText(t, DuplicateField.album), 'Album');
      expect(duplicateFieldText(t, DuplicateField.addedDate), '2026-03-15');
    });

    test('an unknown value reads Unknown, never 0 or empty (SC-16l)', () {
      final u = track(
        'u',
        album: null,
        codec: null,
        bitrateKbps: null,
        sampleRateHz: null,
        durationS: null,
      );
      for (final f in [
        DuplicateField.format,
        DuplicateField.bitrate,
        DuplicateField.sampleRate,
        DuplicateField.duration,
        DuplicateField.album,
      ]) {
        expect(duplicateFieldText(u, f), 'Unknown', reason: '$f');
      }
    });

    test('a known 0 is a real reading, not unknown', () {
      expect(
        duplicateFieldText(track('z', durationS: 0), DuplicateField.duration),
        '0:00',
      );
    });

    test('labels', () {
      expect(
        [for (final f in DuplicateField.values) duplicateFieldLabel(f)],
        ['Format', 'Bitrate', 'Sample rate', 'Duration', 'Album', 'Added'],
      );
    });

    test('a copy is named by every known field, in order', () {
      expect(copyIdentityLines(track('a')), [
        'Format: FLAC',
        'Bitrate: 900 kbps',
        'Sample rate: 44.1 kHz',
        'Duration: 3:05',
        'Album: Album',
        'Added: 2026-03-15',
      ]);
      expect(
        copyIdentityLines(
          track('b', codec: 'mp3', bitrateKbps: 320, album: null, sampleRateHz: null),
        ),
        ['Format: MP3', 'Bitrate: 320 kbps', 'Duration: 3:05', 'Added: 2026-03-15'],
      );
    });
  });

  group('differing fields', () {
    test('identical copies differ in nothing', () {
      expect(differingFields(track('a'), track('b')), isEmpty);
    });

    test('each field that reads differently is a difference', () {
      final a = track('a');
      final b = track(
        'b',
        codec: 'mp3',
        bitrateKbps: 320,
        sampleRateHz: 48000,
        durationS: 190,
        album: 'Live',
        addedAt: _mar18noon,
      );
      expect(differingFields(a, b), DuplicateField.values.toSet());
    });

    test('a value unknown on either side is never a difference', () {
      final a = track('a');
      final b = track(
        'b',
        codec: null,
        bitrateKbps: null,
        sampleRateHz: null,
        durationS: null,
        album: null,
      );
      expect(differingFields(a, b), isEmpty);
      expect(differingFields(b, a), isEmpty);
      // Both unknown is not a difference either.
      expect(differingFields(b, b), isEmpty);
    });

    test('values that read the same are not a difference', () {
      final a = track('a', codec: 'FLAC', bitrateKbps: 900.2, durationS: 185.1, addedAt: _mar15noon);
      final b = track('b', codec: 'flac', bitrateKbps: 899.8, durationS: 185.9, addedAt: _mar15one);
      expect(differingFields(a, b), isEmpty);
    });

    test('title and artist are shown but are not compared fields', () {
      final a = track('a', title: 'Song');
      final b = track('b', title: 'Song (Remastered)', artist: 'Other');
      expect(differingFields(a, b), isEmpty);
    });
  });

  group('order', () {
    test('band, then score descending, then uuid_a, then uuid_b', () {
      final exact1 = pair('a1', 'b1', kind: 'exact', band: 'exact', score: null);
      final exact2 = pair('a1', 'b2', kind: 'exact', band: 'exact', score: null);
      final exact3 = pair('a2', 'b0', kind: 'exact', band: 'exact', score: null);
      final strongHi = pair('a0', 'b0', band: 'strong', score: 0.95);
      final strongLo = pair('a0', 'b1', band: 'strong', score: 0.85);
      final possible = pair('a0', 'b0', band: 'possible', score: 0.99);
      final expected = [exact1, exact2, exact3, strongHi, strongLo, possible];
      final shuffled = [possible, strongLo, exact3, strongHi, exact2, exact1];
      expect(shuffled..sort(compareDuplicatePairs), expected);
    });

    test('an exact pair (null score) ranks as 1.0 within its band', () {
      final scored = pair('a9', 'b9', kind: 'exact', band: 'exact', score: 0.5);
      final unscored = pair('a1', 'b1', kind: 'exact', band: 'exact', score: null);
      // 1.0 > 0.5, so the unscored pair comes first despite its later uuid order
      // being irrelevant here.
      expect(compareDuplicatePairs(unscored, scored), lessThan(0));
    });

    test('an unknown band sorts after the three known bands', () {
      final unknown = pair('a0', 'b0', band: 'someday', score: 1);
      final possible = pair('z', 'z', band: 'possible', score: 0.1);
      expect(compareDuplicatePairs(possible, unknown), lessThan(0));
    });
  });

  group('availability', () {
    LibraryToolsFeature block({required bool duplicateReview}) =>
        LibraryToolsFeature(
          version: 1,
          serverDelete: false,
          duplicateReview: duplicateReview,
        );

    Future<bool> advertised(AdvertisedFeature<LibraryToolsFeature>? f) async {
      final c = ProviderContainer(
        overrides: [libraryToolsFeatureProvider.overrideWith((ref) async => f)],
      );
      addTearDown(c.dispose);
      c.listen(duplicateReviewAdvertisedProvider, (_, _) {});
      await c.read(libraryToolsFeatureProvider.future);
      return c.read(duplicateReviewAdvertisedProvider);
    }

    test('offered only when the block says duplicate_review', () async {
      expect(
        await advertised(
          AdvertisedFeature(block(duplicateReview: true), fromCache: false),
        ),
        isTrue,
      );
      expect(
        await advertised(
          AdvertisedFeature(block(duplicateReview: false), fromCache: false),
        ),
        isFalse,
      );
      expect(await advertised(null), isFalse);
    });

    test('a cached block may show the row (requests stay gated)', () async {
      expect(
        await advertised(
          AdvertisedFeature(block(duplicateReview: true), fromCache: true),
        ),
        isTrue,
      );
    });
  });
}
