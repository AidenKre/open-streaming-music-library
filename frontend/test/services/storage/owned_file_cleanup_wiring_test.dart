// Phase 8B.2a / SC-13 / D29: the owned-file cleanup runs on a
// SingleFlightRunner. Recovery requests it on cold start and resume (a
// local-only member: it needs no binding verification), a sync requests it,
// and a Delete download whose immediate attempt failed requests it. A request
// runs a pass that retries the kept rows.
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:frontend/services/storage/owned_file_cleanup_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import '../../helpers/server_binding.dart';
import '../../helpers/owned_file_cleanup_rows.dart';

Future<int> _pending(AppDatabase db) => pendingOwnedFileCleanups(db);

void main() {
  late AppDatabase db;
  late Directory docs;
  late Directory tracks;
  late int failuresLeft;
  late ProviderContainer c;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db);
    docs = await Directory.systemTemp.createTemp('owned_cleanup_wiring');
    tracks = Directory(p.join(docs.path, 'tracks'))..createSync();
    failuresLeft = 0;
    final api = testApiClient(
      'http://test:8080',
      MockClient((_) async => http.Response('', 404)),
    );
    final coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => docs,
      apiClient: api,
    );
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(api),
        localCoverArtStoreProvider.overrideWithValue(coverStore),
        downloadDirectoryProvider.overrideWithValue(() async => docs),
        ownedFileCleanupProvider.overrideWith(
          (ref) => OwnedFileCleanup(
            db: db,
            documentsDirectory: () async => docs,
            locks: OwnedPathLocks(),
            deleteFile: (file) async {
              if (failuresLeft > 0) {
                failuresLeft--;
                throw const FileSystemException('Cannot delete file');
              }
              await file.delete();
            },
          ),
        ),
      ],
    );
  });

  tearDown(() async {
    c.dispose();
    await db.close();
    if (docs.existsSync()) await docs.delete(recursive: true);
  });

  File download(String name) =>
      File(p.join(tracks.path, name))..writeAsBytesSync([1, 2, 3]);

  /// A row left by an attempt that failed earlier (e.g. before a restart).
  Future<void> pendingRow(File f) => db.transaction(
    () => c
        .read(ownedFileCleanupProvider)
        .enqueueInTransaction([f.path], localBindingId: null),
  );

  RecoverableService member() => c
      .read(recoverablesProvider)
      .singleWhere(
        (r) => r.recoveryPriority == RecoveryPriority.ownedFileCleanup,
      );

  test('the recovery member is local-only and fires on cold start and resume',
      () {
    final m = member();
    expect(m.requiresBinding, isFalse);
    expect(m.triggers, {RecoveryTrigger.coldStart, RecoveryTrigger.appResume});
  });

  for (final trigger in [RecoveryTrigger.coldStart, RecoveryTrigger.appResume]) {
    test('${trigger.name} retries the kept rows through the runner', () async {
      final f = download('u1.m4a');
      await pendingRow(f);
      await member().recover(trigger);
      await c.read(ownedFileCleanupRunnerProvider).whenIdle();
      expect(f.existsSync(), isFalse);
      expect(await _pending(db), 0);
    });
  }

  test('a failed Delete download attempt requests a pass that retries it',
      () async {
    final f = download('u1.m4a');
    await db.into(db.tracks).insert(
      TracksCompanion.insert(
        uuidId: 'u1',
        createdAt: 0,
        lastUpdated: 0,
        filePath: Value(f.path),
      ),
    );
    failuresLeft = 1; // the immediate attempt fails, the runner's pass works
    await c.read(downloadManagerProvider).deleteDownload('u1');
    expect(c.read(ownedFileCleanupRunnerProvider).isRunning, isTrue,
        reason: 'the kept row requested a pass');
    await c.read(ownedFileCleanupRunnerProvider).whenIdle();
    expect(f.existsSync(), isFalse);
    expect(await _pending(db), 0);
  });

  test('the runner is quiesced with the scope', () async {
    final runner = c.read(ownedFileCleanupRunnerProvider);
    final cleanup = c.read(ownedFileCleanupProvider);
    c.dispose();
    final f = download('u1.m4a');
    await db.transaction(
      () => cleanup.enqueueInTransaction([f.path], localBindingId: null),
    );
    runner.request('after dispose');
    await runner.whenIdle();
    expect(f.existsSync(), isTrue);
    c = ProviderContainer(); // tearDown disposes a fresh one
  });
}
