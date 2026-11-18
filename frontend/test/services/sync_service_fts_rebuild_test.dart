// U15-FE-DB-B-03: a search issued while a sync updates fts_tracks must see
// the old entries or the new ones, never neither. The sync used to rebuild
// the whole index after every sync (empty it, fill it again); it now updates
// each page's entries (delete the old ones, index the current ones) in the
// transaction that saves the page (PM-APP-SEARCH). Either way the step that
// writes the current entries comes after the old ones are gone: a search
// started just before it, from outside the transaction, must still find the
// track.
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

/// The real database; just before the statement that writes the current
/// entries into fts_tracks, it starts a search from outside any transaction
/// (the root zone), like a search page would, and keeps its result.
class _ProbingDb extends AppDatabase {
  _ProbingDb() : super(NativeDatabase.memory());

  bool probing = false;
  Future<int>? searchDuringRebuild;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    if (probing &&
        searchDuringRebuild == null &&
        statement.startsWith('INSERT INTO fts_tracks(rowid')) {
      searchDuringRebuild = Zone.root.run(
        () => customSelect(
          "SELECT count(*) AS n FROM fts_tracks WHERE fts_tracks MATCH 'u1'",
        ).getSingle().then((r) => r.read<int>('n')),
      );
    }
    await super.customStatement(statement, args);
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
      bindingToken: token,
    );
  }

  test('a search during the index update still finds an indexed track',
      () async {
    pages[0] = {
      'changes': [_upsert('u1', 1)],
      'nextCursor': null,
      'latestRevision': 1,
    };
    await (await service()).syncChanges();

    // u1 comes again: its old entry is deleted before the new one is written.
    pages[1] = {
      'changes': [_upsert('u1', 2), _upsert('u2', 3)],
      'nextCursor': null,
      'latestRevision': 3,
    };
    db.probing = true;
    await (await service()).syncChanges();

    expect(db.searchDuringRebuild, isNotNull,
        reason: 'the index update ran and the probe searched');
    expect(await db.searchDuringRebuild, 1,
        reason: 'a search saw the index without u1 mid-update');
  });

  // A sync that fails after a committed page: that page's index update ran
  // in the page's transaction too.
  test('a search during the index update of a sync that then fails still '
      'finds a track', () async {
    pages[0] = {
      'changes': [_upsert('u1', 1)],
      'nextCursor': null,
      'latestRevision': 1,
    };
    await (await service()).syncChanges();

    // One page commits, the next request fails.
    pages[1] = {
      'changes': [_upsert('u1', 2), _upsert('u2', 3)],
      'nextCursor': 3,
      'latestRevision': 4,
    };
    db.probing = true;
    await expectLater((await service()).syncChanges(), throwsA(anything));

    expect(db.searchDuringRebuild, isNotNull,
        reason: 'the committed page updated the index and the probe searched');
    expect(await db.searchDuringRebuild, 1,
        reason: 'a search saw the index without u1 mid-update');
  });
}
