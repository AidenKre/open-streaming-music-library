import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _minimalMetadataJson() => {
  'duration': 0.0,
  'bitrate_kbps': 0.0,
  'sample_rate_hz': 0,
  'channels': 0,
  'has_album_art': false,
};

Map<String, dynamic> _trackJson(String uuid) => {
  'uuid_id': uuid,
  'created_at': 1000,
  'last_updated': 2000,
  'metadata': _minimalMetadataJson(),
};

Response _tracksResponse(List<String> uuids, {String? nextCursor}) => Response(
  jsonEncode({
    'data': uuids.map(_trackJson).toList(),
    'nextCursor': nextCursor,
  }),
  200,
);

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  ProviderContainer createContainer() {
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        tracksApiProvider.overrideWithValue(TracksApi()),
      ],
    );
    return container;
  }

  Future<void> waitForBuild(ProviderContainer c) async {
    await c.read(trackSyncProvider.future);
  }

  group('TrackSyncNotifier', () {
    test('first sync sends older_than and limit, upserts tracks, saves lastFetchTime',
        () async {
      final requestUrls = <Uri>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          requestUrls.add(req.url);
          return _tracksResponse(['uuid-1', 'uuid-2']);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      // Verify query params
      expect(requestUrls.length, 1);
      final params = requestUrls[0].queryParameters;
      expect(params.containsKey('older_than'), true);
      expect(params.containsKey('newer_than'), false);
      expect(params['limit'], '500');

      // Verify tracks upserted into DB
      final tracks = await db.select(db.tracks).get();
      expect(tracks.length, 2);
      expect(tracks.map((t) => t.uuidId).toSet(), {'uuid-1', 'uuid-2'});

      final metadata = await db.select(db.trackmetadata).get();
      expect(metadata.length, 2);

      // Verify lastFetchTime saved
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(TrackSyncNotifier.lastFetchTimeKey) != null, true);
    });

    test('subsequent sync sends newer_than and older_than', () async {
      SharedPreferences.setMockInitialValues({
        TrackSyncNotifier.lastFetchTimeKey: 1000,
      });

      Uri? captured;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          captured = req.url;
          return _tracksResponse([]);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      final params = captured!.queryParameters;
      expect(params['newer_than'], '1000');
      expect(params.containsKey('older_than'), true);
    });

    test('multi-page sync follows nextCursor until null', () async {
      var callCount = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          callCount++;
          if (callCount == 1) {
            return _tracksResponse(['uuid-1'], nextCursor: 'cursor-1');
          } else if (callCount == 2) {
            // Cursor follow-up should only have cursor param
            expect(req.url.queryParameters['cursor'], 'cursor-1');
            return _tracksResponse(['uuid-2'], nextCursor: 'cursor-2');
          } else {
            return _tracksResponse(['uuid-3']);
          }
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      expect(callCount, 3);

      final tracks = await db.select(db.tracks).get();
      expect(tracks.length, 3);
    });

    test('upsert updates existing track rather than failing', () async {
      // Insert a track first
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1'])),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);
      await notifier.sync();

      var tracks = await db.select(db.tracks).get();
      expect(tracks.length, 1);

      // Reset prefs so second sync runs fresh
      SharedPreferences.setMockInitialValues({});

      // Sync again with same track — should upsert, not fail
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async => _tracksResponse(['uuid-1'])),
      );

      await notifier.sync();

      tracks = await db.select(db.tracks).get();
      expect(tracks.length, 1);
    });

    test('concurrent sync call is a no-op', () async {
      var callCount = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          callCount++;
          // Simulate slow response
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _tracksResponse(['uuid-1']);
        }),
      );

      final c = createContainer();
      await waitForBuild(c);
      final notifier = c.read(trackSyncProvider.notifier);

      // Fire two syncs concurrently
      final f1 = notifier.sync();
      final f2 = notifier.sync();
      await Future.wait([f1, f2]);

      // Only one API call should have been made
      expect(callCount, 1);
    });
  });
}