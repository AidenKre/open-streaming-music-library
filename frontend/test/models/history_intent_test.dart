import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/history_intent.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

TrackUI _track(String uuid) => TrackUI(
      uuidId: uuid,
      createdAt: 0,
      lastUpdated: 0,
      duration: 1,
      bitrateKbps: null,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
    );

ServerBindingRecord _binding({
  String? instanceId = 'srv-1',
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
  const album = AlbumScope(artistId: 4, albumId: 21);
  const artist = ArtistScope(artistId: 4);

  group('HistoryIntent.forScope (SC-06): collection intents under readiness',
      () {
    test('an album is one album click with the bound-prefix ref', () {
      expect(HistoryIntent.forScope(album, _binding()),
          const HistoryIntent('album', 'srv-1:21'));
    });

    test('an artist is one artist click with the bound-prefix ref', () {
      expect(HistoryIntent.forScope(artist, _binding()),
          const HistoryIntent('artist', 'srv-1:4'));
    });

    test('before readiness, no collection click', () {
      final notReady = _binding(reconciled: false);
      expect(HistoryIntent.forScope(album, notReady), isNull);
      expect(HistoryIntent.forScope(artist, notReady), isNull);
    });

    test('without an instance id or a binding row, no collection click', () {
      expect(HistoryIntent.forScope(album, _binding(instanceId: null)),
          isNull);
      expect(HistoryIntent.forScope(artist, null), isNull);
    });

    test('tracks click as tracks whatever the readiness', () {
      for (final binding in [
        null,
        _binding(reconciled: false),
        _binding(),
      ]) {
        expect(HistoryIntent.forScope(TrackScope(_track('t1')), binding),
            const HistoryIntent.track('t1'));
        expect(HistoryIntent.forScope(TracksScope([_track('t2')]), binding),
            const HistoryIntent.track('t2'));
        expect(
            HistoryIntent.forScope(
                TracksScope([_track('a'), _track('b')]), binding),
            isNull,
            reason: 'a multi-track list is not one clicked entity');
      }
    });
  });
}
