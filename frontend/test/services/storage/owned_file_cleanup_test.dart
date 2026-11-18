// Phase 8B.2a / 8-C04 (unit half): the durable owned-file cleanup rules
// (spec §6 para 6). A row deletes a file only with proof that the file is the
// one it was written for: the path lies under the app's downloads root, no
// track row references it, and its recorded identity (size + mtime) still
// matches. Unknown identity never matches. An unlink failure keeps the row; a
// verified absence clears it. Every write is fenced on the binding token.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/single_flight_runner.dart';
import 'package:frontend/services/storage/owned_file_cleanup.dart';
import 'package:path/path.dart' as p;

import '../../helpers/fake_clock.dart';
import '../../helpers/server_binding.dart';
import '../../helpers/owned_file_cleanup_rows.dart';

Future<List<Map<String, Object?>>> _rows(AppDatabase db) =>
    ownedFileCleanupRows(db, const [
      'id', 'path', 'root_kind', 'dev', 'ino', 'size', 'mtime',
      'local_binding_id', 'attempts', 'last_error', 'created_at',
    ]);

void main() {
  late Directory docs;
  late Directory tracks;
  late AppDatabase db;
  late FakeClock clock;
  late String token;
  late List<String> unlinked;
  // Throws while set, simulating an unlink failure (EACCES, EBUSY).
  late Object? unlinkError;

  OwnedFileCleanup newCleanup() => OwnedFileCleanup(
    db: db,
    documentsDirectory: () async => docs,
    locks: OwnedPathLocks(),
    clock: clock,
    deleteFile: (file) async {
      final error = unlinkError;
      if (error != null) throw error;
      unlinked.add(file.path);
      await file.delete();
    },
  );

  late OwnedFileCleanup cleanup;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('owned_cleanup');
    tracks = Directory(p.join(docs.path, 'tracks'))..createSync();
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock();
    token = await seedTestBinding(db);
    unlinked = [];
    unlinkError = null;
    cleanup = newCleanup();
  });

  tearDown(() async {
    await db.close();
    if (docs.existsSync()) await docs.delete(recursive: true);
  });

  File download(String name, {List<int> bytes = const [1, 2, 3]}) =>
      File(p.join(tracks.path, name))..writeAsBytesSync(bytes);

  Future<List<int>> enqueue(List<String> paths, {String? binding}) =>
      db.transaction(
        () => cleanup.enqueueInTransaction(
          paths,
          localBindingId: binding ?? token,
        ),
      );

  Future<Map<int, OwnedCleanupOutcome>> clean(
    List<int> ids, {
    String? binding,
    bool noBinding = false,
  }) => cleanup.cleanRows(ids, bindingToken: noBinding ? null : binding ?? token);

  group('enqueue', () {
    test('records the path, root, identity, binding and time', () async {
      final f = download('u1.m4a');
      final stat = f.statSync();
      final ids = await enqueue([f.path]);
      expect(ids, hasLength(1));
      expect(await _rows(db), [
        {
          'id': ids.single,
          'path': f.path,
          'root_kind': 'downloads',
          'dev': null,
          'ino': null,
          'size': 3,
          'mtime': stat.modified.microsecondsSinceEpoch,
          'local_binding_id': token,
          'attempts': 0,
          'last_error': null,
          'created_at': clock.nowUtcMs(),
        },
      ]);
      expect(f.existsSync(), isTrue, reason: 'enqueue never deletes');
    });

    test('an absent file is recorded with unknown identity', () async {
      final path = p.join(tracks.path, 'gone.m4a');
      await enqueue([path]);
      final row = (await _rows(db)).single;
      expect((row['size'], row['mtime']), (null, null));
    });

    test('a symlink is recorded with unknown identity (never followed)',
        () async {
      final target = File(p.join(docs.path, 'target.m4a'))
        ..writeAsBytesSync([1, 2, 3]);
      final link = Link(p.join(tracks.path, 'link.m4a'))
        ..createSync(target.path);
      await enqueue([link.path]);
      final row = (await _rows(db)).single;
      expect((row['size'], row['mtime']), (null, null));
    });

    test('rolls back with the caller transaction', () async {
      final f = download('u1.m4a');
      await expectLater(
        db.transaction(() async {
          await cleanup.enqueueInTransaction(
            [f.path],
            localBindingId: token,
          );
          throw StateError('caller failed');
        }),
        throwsStateError,
      );
      expect(await _rows(db), isEmpty);
    });
  });

  group('clean', () {
    test('deletes a matching file and clears the row', () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.deleted});
      expect(f.existsSync(), isFalse);
      expect(await _rows(db), isEmpty);
    });

    test('an unlink failure keeps the row; a retry succeeds', () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      unlinkError = const FileSystemException(
        'Cannot delete file',
        '',
        OSError('Operation not permitted', 1),
      );
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.failed});
      expect(f.existsSync(), isTrue);
      final kept = (await _rows(db)).single;
      expect(kept['attempts'], 1);
      expect(kept['last_error'], isA<String>());
      expect(kept['last_error'] as String, contains('Operation not permitted'));

      unlinkError = null;
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.deleted});
      expect(f.existsSync(), isFalse);
      expect(await _rows(db), isEmpty);
    });

    test('a file already gone clears the row without an unlink', () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      f.deleteSync();
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.absent});
      expect(unlinked, isEmpty);
      expect(await _rows(db), isEmpty);
    });

    test('a file absent at enqueue clears the row', () async {
      final ids = await enqueue([p.join(tracks.path, 'never.m4a')]);
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.absent});
      expect(await _rows(db), isEmpty);
    });

    group('never deletes outside the downloads root', () {
      Future<void> expectRetiredAndKept(File f, String rowPath) async {
        final ids = await enqueue([rowPath]);
        // Identity matches: only the root rule can refuse.
        expect(await clean(ids), {ids.single: OwnedCleanupOutcome.retired});
        expect(f.existsSync(), isTrue);
        expect(unlinked, isEmpty);
        expect(await _rows(db), isEmpty);
      }

      test('a file directly in the documents directory', () async {
        final f = File(p.join(docs.path, 'notes.txt'))..writeAsBytesSync([1]);
        await expectRetiredAndKept(f, f.path);
      });

      test('a file in another directory', () async {
        final other = await Directory.systemTemp.createTemp('elsewhere');
        addTearDown(() => other.delete(recursive: true));
        final f = File(p.join(other.path, 'u1.m4a'))..writeAsBytesSync([1]);
        await expectRetiredAndKept(f, f.path);
      });

      test('a path escaping the root with ..', () async {
        final f = File(p.join(docs.path, 'escape.m4a'))..writeAsBytesSync([1]);
        await expectRetiredAndKept(
          f,
          '${tracks.path}${p.separator}..${p.separator}escape.m4a',
        );
      });

      test('a relative path', () async {
        final f = download('u1.m4a');
        await expectRetiredAndKept(f, p.join('tracks', 'u1.m4a'));
      });

      test('a file reached through a symlinked directory', () async {
        final outside = Directory(p.join(docs.path, 'outside'))..createSync();
        final f = File(p.join(outside.path, 'u1.m4a'))..writeAsBytesSync([1]);
        Link(p.join(tracks.path, 'sub')).createSync(outside.path);
        await expectRetiredAndKept(f, p.join(tracks.path, 'sub', 'u1.m4a'));
      });
    });

    test('a symlink in the root is retired; link and target survive',
        () async {
      final target = File(p.join(docs.path, 'target.m4a'))
        ..writeAsBytesSync([1, 2, 3]);
      final link = Link(p.join(tracks.path, 'link.m4a'))
        ..createSync(target.path);
      final ids = await enqueue([link.path]);
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.retired});
      expect(link.existsSync(), isTrue);
      expect(target.existsSync(), isTrue);
      expect(await _rows(db), isEmpty);
    });

    test('a different size at the path is retired and survives', () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      f.writeAsBytesSync([1, 2, 3, 4, 5]);
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.retired});
      expect(f.existsSync(), isTrue);
      expect(await _rows(db), isEmpty);
    });

    test('the same size with a different mtime is retired and survives',
        () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      f.deleteSync();
      download('u1.m4a').setLastModifiedSync(DateTime.utc(2020));
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.retired});
      expect(f.existsSync(), isTrue);
    });

    test('unknown identity never matches: a file that appeared later '
        'survives', () async {
      final path = p.join(tracks.path, 'u1.m4a');
      final ids = await enqueue([path]); // absent: NULL size/mtime
      final f = download('u1.m4a');
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.retired});
      expect(f.existsSync(), isTrue);
    });

    test('a recorded device/inode cannot be verified, so the file survives',
        () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      await db.customStatement(
        'UPDATE owned_file_cleanup SET dev = 1, ino = 2',
      );
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.retired});
      expect(f.existsSync(), isTrue);
    });

    for (final column in ['file_path', 'damaged_file_path']) {
      test('a track row referencing the path ($column) keeps the file',
          () async {
        final f = download('u1.m4a');
        final ids = await enqueue([f.path]);
        await db.customStatement(
          'INSERT INTO tracks (uuid_id, $column, created_at, last_updated) '
          "VALUES ('u1', ?, 1, 1)",
          [f.path],
        );
        expect(await clean(ids), {ids.single: OwnedCleanupOutcome.retired});
        expect(f.existsSync(), isTrue);
        expect(await _rows(db), isEmpty);
      });
    }

    test('a rotated binding fences the attempt: no unlink, row unchanged',
        () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      final before = await _rows(db);
      await ServerBindingRepository(db).rotate();
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.fenced});
      expect(f.existsSync(), isTrue);
      expect(await _rows(db), before);
    });

    test('a deleted binding row (reset) fences the attempt', () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      final before = await _rows(db);
      await db.customStatement('DELETE FROM server_binding');
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.fenced});
      expect(f.existsSync(), isTrue);
      expect(await _rows(db), before);
    });

    test('without a binding row a NULL token works, and a binding created '
        'meanwhile fences it', () async {
      await db.customStatement('DELETE FROM server_binding');
      final f = download('u1.m4a');
      final g = download('u2.m4a');
      final ids = await db.transaction(
        () => cleanup.enqueueInTransaction(
          [f.path, g.path],
          localBindingId: null,
        ),
      );
      expect(await clean([ids.first], noBinding: true), {
        ids.first: OwnedCleanupOutcome.deleted,
      });
      await seedTestBinding(db);
      expect(await clean([ids.last], noBinding: true), {
        ids.last: OwnedCleanupOutcome.fenced,
      });
      expect(g.existsSync(), isTrue);
    });

    // Path table row 19: a caller's immediate attempt and a runner pass
    // share the app-wide path lock; the second finds the row gone.
    test('two attempts on one row at once: one deletes, the other finds the '
        'row gone', () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      final results = await Future.wait([clean(ids), clean(ids)]);
      expect(
        {for (final r in results) r[ids.single]},
        {OwnedCleanupOutcome.deleted, OwnedCleanupOutcome.missing},
      );
      expect(unlinked, [f.path], reason: 'exactly one unlink');
      expect(await _rows(db), isEmpty);
    });

    test('an unknown row id is reported missing', () async {
      expect(await clean([999]), {999: OwnedCleanupOutcome.missing});
    });

    test('a restart after the unlink but before the row clear, then a second '
        'restart, finishes cleanly', () async {
      final f = download('u1.m4a');
      final ids = await enqueue([f.path]);
      f.deleteSync(); // the unlink happened; the process died before the txn
      cleanup = newCleanup(); // restart
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.absent});
      cleanup = newCleanup(); // restart again
      expect(await clean(ids), {ids.single: OwnedCleanupOutcome.missing});
      expect(await _rows(db), isEmpty);
    });
  });

  // Review r1 #4: an unexpected error in an attempt (here: the root can't be
  // resolved) never escapes to the caller, whose transaction has committed;
  // the row stays for the runner.
  test('an attempt that cannot even resolve the root keeps the row and '
      'does not throw', () async {
    final f = download('u1.m4a');
    final ids = await enqueue([f.path]);
    final broken = OwnedFileCleanup(
      db: db,
      documentsDirectory: () async => throw const FileSystemException('no'),
      locks: OwnedPathLocks(),
      clock: clock,
    );
    expect(
      await broken.cleanRows(ids, bindingToken: token),
      {ids.single: OwnedCleanupOutcome.failed},
    );
    expect(f.existsSync(), isTrue);
    expect((await _rows(db)).single['path'], f.path);
  });

  group('runPass', () {
    // Review r1 #3: a pass needs a binding row to fence on; with none (a
    // reset under way, no session) it does nothing and the rows wait.
    test('with no binding row it deletes nothing and keeps the rows',
        () async {
      final a = download('a.m4a');
      await enqueue([a.path]);
      await db.customStatement('DELETE FROM server_binding');
      expect(await cleanup.runPass({'test'}), isA<PassDone>());
      expect(a.existsSync(), isTrue);
      expect(await _rows(db), hasLength(1));
    });

    test('cleans every row with the current binding and reports done',
        () async {
      final a = download('a.m4a');
      final b = download('b.m4a');
      await enqueue([a.path, b.path]);
      expect(await cleanup.runPass({'test'}), isA<PassDone>());
      expect((a.existsSync(), b.existsSync()), (false, false));
      expect(await _rows(db), isEmpty);
    });

    test('rows written under an earlier binding are still cleaned', () async {
      final a = download('a.m4a');
      await enqueue([a.path]);
      await ServerBindingRepository(db).rotate(); // sign-out keeps the rows
      expect(await cleanup.runPass({'test'}), isA<PassDone>());
      expect(a.existsSync(), isFalse);
    });

    test('a failure keeps its row and asks for a retry', () async {
      final a = download('a.m4a');
      await enqueue([a.path]);
      unlinkError = const FileSystemException('Cannot delete file');
      expect(await cleanup.runPass({'test'}), isA<PassFailed>());
      expect(a.existsSync(), isTrue);
      expect((await _rows(db)).single['attempts'], 1);
      unlinkError = null;
      expect(await cleanup.runPass({'retry'}), isA<PassDone>());
      expect(a.existsSync(), isFalse);
      expect(await _rows(db), isEmpty);
    });

    // Pre-merge review D3-01: a database of another schema version stays
    // refused until a reset replaces it (and rebuilds the scope), so a retry
    // cannot help: the runner parks instead of re-reading it every 30 s
    // while the refusal screen shows.
    test('a database of another version parks the runner', () async {
      final refused = AppDatabase(NativeDatabase.memory(
        setup: (raw) => raw.execute('PRAGMA user_version = 8'),
      ));
      addTearDown(refused.close);
      final pass = OwnedFileCleanup(
        db: refused,
        documentsDirectory: () async => docs,
        locks: OwnedPathLocks(),
        clock: clock,
      ).runPass;
      expect(await pass({'coldStart'}), isA<PassParked>());
    });

    test('any other database failure still asks for a retry', () async {
      final broken = AppDatabase(NativeDatabase.memory());
      await broken.customSelect('SELECT 1').get();
      await broken.close(); // a closed database refuses every query
      final pass = OwnedFileCleanup(
        db: broken,
        documentsDirectory: () async => docs,
        locks: OwnedPathLocks(),
        clock: clock,
      ).runPass;
      await expectLater(pass({'coldStart'}), throwsA(anything),
          reason: 'the runner turns a thrown pass into a retry');
    });
  });
}
