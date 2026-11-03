import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';

TrackUI _track(String uuid, {String? filePath}) => TrackUI(
  uuidId: uuid,
  filePath: filePath,
  createdAt: 0,
  lastUpdated: 0,
  duration: 1,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

void main() {
  group('LibraryScope value equality (family keys must not leak)', () {
    test('AlbumScope is equal by artist and album id', () {
      const a = AlbumScope(artistId: 1, albumId: 7);
      // Built at runtime so `const` canonicalisation can't fake equality.
      final b = AlbumScope(artistId: int.parse('1'), albumId: int.parse('7'));
      expect(b, a);
      expect(b.hashCode, a.hashCode);
      expect(a == const AlbumScope(artistId: 2, albumId: 7), isFalse);
      expect(a == const AlbumScope(artistId: 1, albumId: 8), isFalse);
    });

    test('ArtistScope is equal by artist id, and never equals an AlbumScope', () {
      final a = ArtistScope(artistId: int.parse('7'));
      expect(a, const ArtistScope(artistId: 7));
      expect(a.hashCode, const ArtistScope(artistId: 7).hashCode);
      expect(a == const ArtistScope(artistId: 8), isFalse);
      // Artist 7 and album 7 are different entities.
      expect(
        const ArtistScope(artistId: 7) as LibraryScope ==
            const AlbumScope(artistId: 7, albumId: 7),
        isFalse,
      );
    });

    test('TrackScope is equal by uuid and download state', () {
      final a = TrackScope(_track('u1'));
      expect(a, TrackScope(_track('u1')));
      expect(a.hashCode, TrackScope(_track('u1')).hashCode);
      expect(a == TrackScope(_track('u2')), isFalse);
      // A download changes what the scope can do offline, so it is a new key.
      expect(a == TrackScope(_track('u1', filePath: '/f')), isFalse);
    });

    test('TracksScope is equal by its ordered tracks', () {
      final a = TracksScope([_track('u1'), _track('u2')]);
      expect(a, TracksScope([_track('u1'), _track('u2')]));
      expect(a.hashCode, TracksScope([_track('u1'), _track('u2')]).hashCode);
      expect(a == TracksScope([_track('u2'), _track('u1')]), isFalse);
      expect(a == TracksScope([_track('u1')]), isFalse);
    });
  });

  test('TracksScope with a repeated uuid is equal by position', () {
    final a = TracksScope([_track('u1'), _track('u1')]);
    expect(a, TracksScope([_track('u1'), _track('u1')]));
    expect(a == TracksScope([_track('u1')]), isFalse);
  });
}
