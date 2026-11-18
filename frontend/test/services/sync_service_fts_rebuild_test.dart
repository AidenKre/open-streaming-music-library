// U15-FE-DB-B-03: after a catalog sync the search indexes are rebuilt from
// the tables. The rebuild empties fts_tracks and fills it again; run as
// separate statements, a search issued in between found nothing. It runs in
// one transaction now, so a reader sees the old index or the new one, never
// an empty one.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _upsert(String uuid, int revision) => {
  'type': 'upsert',
  'revision': revision,
  'uuid_id': uuid,
  'track': {
    'uuid_id': uuid,
    'created_at': 1,
    'last_updated': 1,
    'revision': revision,
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

/// The real database; right after the rebuild empties fts_tracks it starts a
/// search from outside any transaction (the root zone), like a search page
/// would, and keeps its result.
class _ProbingDb extends AppDatabase {
  _ProbingDb() : super(NativeDatabase.memory());

  bool probing = false;
  Future<int>? searchDuringRebuild;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (probing &&
        searchDuringRebuild == null &&
        statement.contains("fts_tracks(fts_tracks) VALUES('delete-all')")) {
      searchDuringRebuild = Zone.root.run(
        () => customSelect(
          "SELECT count(*) AS n FROM fts_tracks WHERE fts_tracks MATCH 'u1'",
        ).getSingle().then((r) => r.read<int>('n')),
      );
    }
  }
}

void main() {
  late _ProbingDb db;
  late String token;
  late Map<int, Map<String, Object?>> pages;

  setUp(() async {
    db = _ProbingDb();
    token = (await ServerBindingRepository(db)
            .ensureProvisional('http://test:8080'))
        .localBindingId;
    pages = {};
  });

  tearDown(() => db.close());

  Future<SyncService> service() async {
    SharedPreferences.setMockInitialValues({});
    final api = testApiClient(
      'http://test:8080',
      MockClient((req) async {
        final after = int.parse(req.url.queryParameters['after_revision']!);
        final page = pages[after];
        if (page == null) return http.Response('no page for $after', 500);
        return http.Response(jsonEncode(page), 200,
            headers: {'content-type': 'application/json'});
      }),
    );
    return SyncService(
      db: db,
      api: TracksApi(api: api),
      queueRepository: QueueRepository(db),
      prefs: await SharedPreferences.getInstance(),
      bindingToken: token,
    );
  }

  test('a search during the index rebuild still finds an indexed track',
      () async {
    pages[0] = {
      'changes': [_upsert('u1', 1)],
      'nextCursor': null,
      'latestRevision': 1,
    };
    await (await service()).syncChanges();

    pages[1] = {
      'changes': [_upsert('u2', 2)],
      'nextCursor': null,
      'latestRevision': 2,
    };
    db.probing = true;
    await (await service()).syncChanges();

    expect(db.searchDuringRebuild, isNotNull,
        reason: 'the rebuild ran and the probe searched');
    expect(await db.searchDuringRebuild, 1,
        reason: 'a search saw the emptied index mid-rebuild');
  });

  // Phase 8 adds a rebuild after a failed page (pages that committed changed
  // the tables): it runs in one transaction too.
  test('a search during the rebuild after a failed page still finds a track',
      () async {
    pages[0] = {
      'changes': [_upsert('u1', 1)],
      'nextCursor': null,
      'latestRevision': 1,
    };
    await (await service()).syncChanges();

    // One page commits, the next request fails.
    pages[1] = {
      'changes': [_upsert('u2', 2)],
      'nextCursor': 2,
      'latestRevision': 3,
    };
    db.probing = true;
    await expectLater((await service()).syncChanges(), throwsA(anything));

    expect(db.searchDuringRebuild, isNotNull,
        reason: 'the rebuild after the failed page ran and the probe searched');
    expect(await db.searchDuringRebuild, 1,
        reason: 'a search saw the emptied index mid-rebuild');
  });
}
