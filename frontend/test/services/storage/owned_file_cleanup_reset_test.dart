// Phase 8B.2a / SC-15 / 8-C04 (unit half): the owned-file cleanup is a reset
// quiesce participant (after uploads, before submissions). A reset is never
// blocked by pending cleanup rows or by a stalled cleanup task: the fence
// makes the stalled task's write a no-op, the wipe empties the table, and no
// old task writes into the new store.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:frontend/services/storage/owned_file_cleanup_providers.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/server_binding.dart';

Future<int> _pending(AppDatabase db) async => (await db
        .customSelect('SELECT COUNT(*) AS n FROM owned_file_cleanup')
        .getSingle())
    .read<int>('n');

void main() {
  late AppDatabase db;
  late Directory docs;
  late Directory tracks;
  late String token;
  late Future<void> Function(File) deleteFile;
  late ProviderContainer c;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    docs = await Directory.systemTemp.createTemp('owned_cleanup_reset');
    tracks = Directory(p.join(docs.path, 'tracks'))..createSync();
    deleteFile = (f) => f.delete();
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        downloadDirectoryProvider.overrideWithValue(() async => docs),
        ownedFileCleanupProvider.overrideWith(
          (ref) => OwnedFileCleanup(
            db: db,
            documentsDirectory: () async => docs,
            locks: OwnedPathLocks(),
            deleteFile: (f) => deleteFile(f),
          ),
        ),
        localResettablesProvider.overrideWithValue(<LocalResettable>[db]),
        lossReportersProvider.overrideWithValue(const []),
        localResetServiceProvider.overrideWith(
          (ref) => LocalResetService(
            ref,
            quiesceTimeout: const Duration(milliseconds: 50),
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

  test('the cleanup quiesces after uploads and before submissions', () {
    expect([for (final q in c.read(localQuiescablesProvider)) q.quiesceName], [
      'playback',
      'listens',
      'preview',
      'history',
      'uploads',
      'delete-jobs',
      'owned-file-cleanup',
      'submissions',
    ]);
  });

  test('quiescing closes the runner: later requests run no pass', () async {
    final runner = c.read(ownedFileCleanupRunnerProvider);
    await c
        .read(localQuiescablesProvider)
        .singleWhere((q) => q.quiesceName == 'owned-file-cleanup')
        .quiesce();
    final f = File(p.join(tracks.path, 'u1.m4a'))..writeAsBytesSync([1]);
    await db.transaction(
      () => c
          .read(ownedFileCleanupProvider)
          .enqueueInTransaction([f.path], localBindingId: token),
    );
    runner.request('after quiesce');
    await runner.whenIdle();
    expect(f.existsSync(), isTrue);
  });

  test('a reset with pending rows and a stalled cleanup is not blocked; the '
      'wipe empties the table and the stalled write is fenced', () async {
    final entered = Completer<void>();
    final stall = Completer<void>();
    deleteFile = (f) async {
      entered.complete();
      await stall.future;
      await f.delete();
    };
    final stalled = File(p.join(tracks.path, 'u1.m4a'))..writeAsBytesSync([1]);
    final other = File(p.join(tracks.path, 'u2.m4a'))..writeAsBytesSync([2]);
    await db.transaction(
      () => c
          .read(ownedFileCleanupProvider)
          .enqueueInTransaction([stalled.path, other.path],
              localBindingId: token),
    );
    final runner = c.read(ownedFileCleanupRunnerProvider);
    runner.request('test');
    await entered.future;

    await expectLater(
      c.read(localResetServiceProvider).reset(),
      throwsA(
        isA<LocalResetException>().having(
          (e) => {for (final f in e.failures) f.quiesce},
          'only quiesce timeouts',
          {true},
        ),
      ),
    );
    expect(await _pending(db), 0, reason: 'wiped with the database');
    expect(await ServerBindingRepository(db).current(), isNull);

    // The new store binds; the stalled task then finishes.
    await seedTestBinding(db);
    stall.complete();
    await runner.whenIdle();
    expect(await _pending(db), 0, reason: 'its write was fenced');
  });
}
