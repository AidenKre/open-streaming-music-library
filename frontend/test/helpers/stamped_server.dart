import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The instance the test session is bound to, and another one (SC-01).
const boundInstance = '3f1c2a9e-7b4d-4e2a-9c1f-0a1b2c3d4e5f';
const otherInstance = '9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a';

/// A scripted server whose every answer carries the instance stamp the test
/// picks (null: a pre-Phase-7 server without the header). Records every
/// request it receives, in order, as `METHOD /path`.
class StampedServer {
  StampedServer({this.baseUrl = 'http://s'});

  final String baseUrl;

  /// The stamp of the next answers.
  String? stamp = boundInstance;

  /// Every request received, as `METHOD /path`.
  final requests = <String>[];

  /// PATCH /tracks/{uuid} (an edit). Default: 200 with revision 6.
  (int, Object?) Function(String uuid, Map<String, dynamic> body) onPatchTrack =
      (uuid, _) => (200, {'uuid_id': uuid, 'revision': 6, 'master_written': false});

  /// GET /tracks/{uuid} (single-track refetch). Default: 404.
  (int, Object?) Function(String uuid) onGetTrack = (_) => (404, {'detail': 'gone'});

  /// POST /history (a listen batch; the answer is its acknowledgement).
  /// Default: every event acknowledged.
  (int, Object?) Function(List<String> eventUuids) onPostHistory =
      (uuids) => (200, {'acknowledged': uuids});

  List<String> requestsMatching(String prefix) =>
      [for (final r in requests) if (r.startsWith(prefix)) r];

  http.Response _answer(int status, Object? body) => http.Response(
    jsonEncode(body),
    status,
    headers: {
      'content-type': 'application/json',
      'x-server-instance-id': ?stamp,
    },
  );

  late final ApiClient client = testApiClient(
    baseUrl,
    MockClient((req) async {
      final segs = req.url.pathSegments;
      requests.add('${req.method} /${segs.join('/')}');
      if (req.method == 'PATCH' && segs.length == 2 && segs[0] == 'tracks') {
        final (status, body) = onPatchTrack(
          segs[1],
          (jsonDecode(req.body) as Map).cast<String, dynamic>(),
        );
        return _answer(status, body);
      }
      if (req.method == 'GET' && segs.length == 2 && segs[0] == 'tracks') {
        final (status, body) = onGetTrack(segs[1]);
        return _answer(status, body);
      }
      if (req.method == 'GET' && segs.length == 1 && segs[0] == 'changes') {
        return _answer(200, {'changes': [], 'latestRevision': 0, 'nextCursor': null});
      }
      if (req.method == 'POST' && segs.length == 1 && segs[0] == 'history') {
        final events = (jsonDecode(req.body) as Map)['events'] as List;
        final (status, body) = onPostHistory([
          for (final e in events) (e as Map)['event_uuid'] as String,
        ]);
        return _answer(status, body);
      }
      if (req.method == 'GET' &&
          segs.length == 2 &&
          segs[0] == 'history' &&
          segs[1] == 'changes') {
        return _answer(200, {'events': [], 'nextCursor': null, 'latestRevision': 0});
      }
      return _answer(404, {'detail': 'not scripted'});
    }),
  );
}

/// A single-track GET payload (the `ClientTrack` shape).
Map<String, Object?> trackJson(String uuid, {String title = 'Server', int revision = 9}) => {
  'uuid_id': uuid,
  'created_at': 0,
  'last_updated': 0,
  'revision': revision,
  'metadata': {
    'title': title,
    'artist': 'ServerA',
    'album': 'ServerAlb',
    'duration': 1,
    'bitrate_kbps': 1,
    'sample_rate_hz': 1,
    'channels': 2,
    'has_album_art': false,
  },
};

/// A local catalog track (tracks + trackmetadata + its FTS row).
Future<void> seedTrackRow(
  AppDatabase db,
  String uuid, {
  String title = 'Old',
  int revision = 5,
}) async {
  await db.customStatement(
    'INSERT INTO tracks (uuid_id, created_at, last_updated, revision) '
    'VALUES (?, 0, 0, ?)',
    [uuid, revision],
  );
  await db.customStatement(
    'INSERT INTO trackmetadata (uuid_id, title, artist, album, duration, '
    'bitrate_kbps, sample_rate_hz, channels, has_album_art) '
    "VALUES (?, ?, 'OldA', 'OldAlb', 1, 1, 1, 2, 0)",
    [uuid, title],
  );
  final rowid = (await db
          .customSelect('SELECT rowid AS r FROM trackmetadata WHERE uuid_id = ?',
              variables: [Variable.withString(uuid)])
          .getSingle())
      .read<int>('r');
  await db.customStatement(
    'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
    "VALUES (?, ?, 'OldA', 'OldAlb')",
    [rowid, title],
  );
}

/// Every row of the local catalog and the edit outbox, for "exactly as
/// before" comparisons.
Future<List<Object>> catalogAndOutboxSnapshot(AppDatabase db) async => [
  ...await db.select(db.tracks).get(),
  ...await db.select(db.trackmetadata).get(),
  ...await db.select(db.pendingEdits).get(),
];
