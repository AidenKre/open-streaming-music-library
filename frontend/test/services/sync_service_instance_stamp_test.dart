// Phase 7B.1a exit proof (SC-01 rule 6, catalog stream): each `/changes`
// page is compared with the bound instance before it commits.
//  * a page from a different instance on page 2 leaves exactly page 1's
//    rows and cursor (nothing of page 2: no rows, no cursor, no reconciled
//    flag) and fails the sync with ServerInstanceChangedException;
//  * the check comes before SC-01 rule 5: another instance's low
//    latestRevision is not taken for a restored server (the reconciled flag
//    stays, the error is the instance change);
//  * a legacy server (no header) syncs exactly as before;
//  * the bound instance's stamps (any case) sync normally.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';

const _bound = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const _other = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';

Map<String, Object?> _upsert(String uuid, int rev) => {
  'type': 'upsert',
  'revision': rev,
  'uuid_id': uuid,
  'track': {
    'uuid_id': uuid,
    'created_at': 1,
    'last_updated': 1,
    'revision': rev,
    'metadata': {
      'title': 'title-$uuid',
      'artist': 'Artist',
      'album': 'Album',
      'artist_id': 1,
      'album_id': 1,
      'codec': 'flac',
      'duration': 10.0,
      'bitrate_kbps': 900.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  },
};

Map<String, Object?> _page(
  List<Map<String, Object?>> changes, {
  int? next,
  required int latest,
}) => {'changes': changes, 'nextCursor': next, 'latestRevision': latest};

void main() {
  late AppDatabase db;
  late ServerBindingRepository binding;
  late SyncCursorStore cursors;
  late String token;
  // after_revision -> (page, stamp header value or null for no header)
  late Map<int, (Map<String, Object?>, String?)> pages;

  Future<SyncService> service() async {
    SharedPreferences.setMockInitialValues({});
    final api = testApiClient(
      'http://test',
      MockClient((req) async {
        final after = int.parse(req.url.queryParameters['after_revision']!);
        final (page, stamp) = pages[after]!;
        return http.Response(jsonEncode(page), 200, headers: {
          'content-type': 'application/json',
          'x-server-instance-id': ?stamp,
        });
      }),
    );
    return SyncService(
      db: db,
      api: TracksApi(api: api),
      queueRepository: QueueRepository(db),
      bindingToken: token,
    );
  }

  Future<List<String>> trackUuids() async => [
    for (final r in await db
        .customSelect('SELECT uuid_id FROM tracks ORDER BY uuid_id')
        .get())
      r.read<String>('uuid_id'),
  ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    binding = ServerBindingRepository(db);
    cursors = SyncCursorStore(db);
    token = await seedTestBinding(db, instanceId: _bound);
    pages = {};
  });
  tearDown(() => db.close());

  test('a different instance on page 2 leaves page 1 only', () async {
    pages[0] = (_page([_upsert('u1', 3)], next: 5, latest: 9), _bound);
    pages[5] = (_page([_upsert('u2', 7)], latest: 9), _other);

    await expectLater(
      (await service()).syncChanges(),
      throwsA(isA<ServerInstanceChangedException>()
          .having((e) => e.servedBy, 'servedBy', _other)),
    );

    expect(await trackUuids(), ['u1']);
    expect(await cursors.read(SyncStream.catalog), 5);
    final row = await binding.current();
    expect(row!.catalogReconciled, isFalse,
        reason: 'the final page (which marks reconciled) never committed');
    expect(row.instanceId, _bound);
  });

  test('a different instance on page 1 commits nothing', () async {
    pages[0] = (_page([_upsert('u1', 3)], latest: 3), _other);

    await expectLater((await service()).syncChanges(),
        throwsA(isA<ServerInstanceChangedException>()));

    expect(await trackUuids(), isEmpty);
    expect(await cursors.read(SyncStream.catalog), 0);
  });

  test('another instance with a lower latestRevision is an instance change, '
      'not a restored server', () async {
    await binding.runFenced(token, binding.markCatalogReconciledInTransaction);
    await binding.runFenced(token, () => cursors.write(SyncStream.catalog, 50));
    pages[50] = (_page([], latest: 2), _other);

    await expectLater((await service()).syncChanges(),
        throwsA(isA<ServerInstanceChangedException>()));

    expect((await binding.current())!.catalogReconciled, isTrue,
        reason: 'rule 5 must not clear the flag on another instance\'s word');
    expect(await cursors.read(SyncStream.catalog), 50);
  });

  test('a legacy server (no header) syncs as before', () async {
    pages[0] = (_page([_upsert('u1', 3)], next: 5, latest: 9), null);
    pages[5] = (_page([_upsert('u2', 7)], latest: 9), null);

    await (await service()).syncChanges();

    expect(await trackUuids(), ['u1', 'u2']);
    expect(await cursors.read(SyncStream.catalog), 7);
    expect((await binding.current())!.catalogReconciled, isTrue);
  });

  test('the bound instance (any case) syncs normally', () async {
    pages[0] = (_page([_upsert('u1', 3)], next: 5, latest: 9), _bound);
    pages[5] =
        (_page([_upsert('u2', 7)], latest: 9), _bound.toUpperCase());

    await (await service()).syncChanges();

    expect(await trackUuids(), ['u1', 'u2']);
    expect(await cursors.read(SyncStream.catalog), 7);
  });
}
