import 'dart:convert';
import 'dart:io';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/tracks_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/repositories/sync_cursor_store.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:frontend/services/sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'server_binding.dart';

/// A server tombstone of [uuids], applied by the product's own sync path: a
/// `/changes` page of delete entries that [SyncService] applies, so a test
/// that deletes tracks "as a sync does" follows that path (its transaction,
/// the queue edit, the clean-up queue, the refusal of unsent edits) when it
/// changes, instead of a copy of it. The sync state the app would publish is
/// up to the caller, from the returned [SyncResult].
///
/// Everything a real tombstone page does happens: the catalog cursor
/// advances, the catalog is marked reconciled, orphan artists and albums are
/// pruned, the search index is updated and unsent edits of the tracks are
/// refused. Seeds a binding row when the database has none (sync writes are
/// fenced). No file is deleted or written: the clean-up root is a folder
/// that does not exist and the file delete does nothing (the clean-up may
/// still look up a deleted track's recorded path).
Future<SyncResult> applySyncTombstone(
  AppDatabase db,
  List<String> uuids, {
  QueueRepository? queueRepository,
}) async {
  final token = (await ServerBindingRepository(db).current())?.localBindingId ??
      await seedTestBinding(db);
  final revision = await SyncCursorStore(db).read(SyncStream.catalog) + 1;
  final page = {
    'changes': [
      for (final u in uuids)
        {'type': 'delete', 'revision': revision, 'uuid_id': u, 'track': null},
    ],
    'nextCursor': null,
    'latestRevision': revision,
  };
  final api = testApiClient(
    'http://test',
    MockClient((request) async {
      if (request.url.path == '/changes') {
        return http.Response(jsonEncode(page), 200,
            headers: {'content-type': 'application/json'});
      }
      throw StateError('Unexpected tombstone request: ${request.url}');
    }),
  );
  return SyncService(
    db: db,
    api: TracksApi(api: api),
    queueRepository: queueRepository ?? QueueRepository(db),
    bindingToken: token,
    ownedFileCleanup: OwnedFileCleanup(
      db: db,
      documentsDirectory: () async => Directory('/osml-test-no-downloads'),
      locks: OwnedPathLocks(),
      deleteFile: (_) async {},
    ),
  ).syncChanges();
}
