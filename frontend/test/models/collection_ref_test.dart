import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/collection_ref.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

const _bound = 'inst-A';

ServerBindingRecord _binding({
  String? instanceId = _bound,
  bool reconciled = true,
}) =>
    ServerBindingRecord(
      instanceId: instanceId,
      localBindingId: 'token',
      lastBaseUrl: 'http://test',
      boundAtMs: 0,
      catalogReconciled: reconciled,
      userId: 1,
    );

void main() {
  group('tryParse accepts only <bound instance>:<canonical positive id>', () {
    // ref -> expected id (null = rejected). Spec §4: the bound prefix and a
    // canonical positive decimal (`id.toString() == idPart`), no casts.
    const table = <String, int?>{
      'inst-A:1': 1,
      'inst-A:42': 42,
      'inst-A:9223372036854775807': 9223372036854775807, // 2^63 - 1
      'inst-A:0': null,
      'inst-A:-1': null,
      'inst-A:01': null,
      'inst-A:007': null,
      'inst-A:+1': null,
      'inst-A: 1': null,
      'inst-A:1 ': null,
      'inst-A:\t1': null,
      'inst-A:1.0': null,
      'inst-A:1e3': null,
      'inst-A:0x1F': null,
      'inst-A:１': null, // fullwidth digit one
      'inst-A:abc': null,
      'inst-A:12abc': null,
      'inst-A:9223372036854775808': null, // 2^63
      'inst-A:99999999999999999999999999999999': null,
      'inst-A:': null, // empty id
      'inst-A:1:2': null,
      '1': null, // bare integer
      '42': null,
      'inst-B:1': null, // foreign prefix
      'inst-:1': null, // a prefix of the bound id
      'inst-AB:1': null, // the bound id is a prefix of it
      'INST-A:1': null, // prefixes compare exactly
      ' inst-A:1': null,
      ':1': null,
      '': null,
      'inst-A': null,
    };
    table.forEach((ref, expected) {
      test('"$ref" -> ${expected ?? 'rejected'}', () {
        final parsed = CollectionRef.tryParse(ref, boundInstanceId: _bound);
        if (expected == null) {
          expect(parsed, isNull);
        } else {
          expect(parsed, isNotNull);
          expect(parsed!.id, expected);
          expect(parsed.instanceId, _bound);
          expect(parsed.format(), ref, reason: 'canonical round trip');
        }
      });
    });

    test('an empty bound instance id parses nothing', () {
      expect(CollectionRef.tryParse(':1', boundInstanceId: ''), isNull);
      expect(CollectionRef.tryParse('1', boundInstanceId: ''), isNull);
    });

    test('an instance id containing a colon is matched as a whole prefix', () {
      final parsed = CollectionRef.tryParse('a:b:7', boundInstanceId: 'a:b');
      expect(parsed?.id, 7);
      expect(parsed?.instanceId, 'a:b');
      expect(CollectionRef.tryParse('a:7', boundInstanceId: 'a:b'), isNull);
    });
  });

  group('fromScope: only under SC-04 readiness', () {
    const album = AlbumScope(artistId: 3, albumId: 17);
    const artist = ArtistScope(artistId: 3);

    test('reconciled binding with an instance: album and artist refs', () {
      expect(CollectionRef.fromScope(album, _binding())?.format(),
          'inst-A:17');
      expect(CollectionRef.fromScope(artist, _binding())?.format(),
          'inst-A:3');
    });

    test('readiness absent: no ref', () {
      expect(CollectionRef.fromScope(album, _binding(reconciled: false)),
          isNull);
      expect(CollectionRef.fromScope(artist, _binding(reconciled: false)),
          isNull);
    });

    test('no instance id (provisional or legacy binding): no ref', () {
      expect(CollectionRef.fromScope(album, _binding(instanceId: null)),
          isNull);
      expect(CollectionRef.fromScope(album, _binding(instanceId: '')),
          isNull);
    });

    test('no binding row: no ref', () {
      expect(CollectionRef.fromScope(album, null), isNull);
      expect(CollectionRef.fromScope(artist, null), isNull);
    });

    test('track scopes are not collections', () {
      const track = TrackUI(
        uuidId: 't1',
        createdAt: 0,
        lastUpdated: 0,
        duration: 1,
        bitrateKbps: null,
        sampleRateHz: 44100,
        channels: 2,
        hasAlbumArt: false,
      );
      expect(CollectionRef.fromScope(TrackScope(track), _binding()), isNull);
      expect(CollectionRef.fromScope(TracksScope(const [track]), _binding()),
          isNull);
    });

    test('a non-positive parent id is never formatted', () {
      expect(
          CollectionRef.fromScope(
              const AlbumScope(artistId: 3, albumId: 0), _binding()),
          isNull);
      expect(
          CollectionRef.fromScope(const ArtistScope(artistId: -2), _binding()),
          isNull);
    });

    test('what fromScope formats, tryParse reads back', () {
      final ref = CollectionRef.fromScope(album, _binding())!;
      expect(
          CollectionRef.tryParse(ref.format(), boundInstanceId: _bound), ref);
    });
  });

  test('value equality', () {
    final a = CollectionRef.tryParse('inst-A:5', boundInstanceId: _bound);
    final b = CollectionRef.tryParse('inst-A:5', boundInstanceId: _bound);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == CollectionRef.tryParse('inst-A:6', boundInstanceId: _bound),
        isFalse);
  });
}
