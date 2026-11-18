import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/widgets/pending_edits_banner.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/ui/edit_controller.dart';
import '../../helpers/server_binding.dart';
import '../../helpers/stamped_server.dart' show seedTrackRow;

void main() {
  testWidgets('rejected edit is visible with its reason and dismissible',
      (tester) async {
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async => http.Response('', 404)),
    );
    final db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    addTearDown(db.close);
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
      'rejection_reason, updated_at) VALUES '
      '(\'u1\', \'{"title":"My Song"}\', \'db_only\', \'rejected\', '
      '\'Rejected by the server\', 0)',
    );
    // D4: the name comes from the track on this device, else the edit's
    // original values (a rejected edit's new title was refused).
    await db.customStatement(
      'UPDATE pending_edits SET original_values_json = '
      '\'{"title":"My Song"}\' WHERE uuid_id = \'u1\'',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          databaseProvider.overrideWithValue(db),
        ],
        child: const MaterialApp(home: Scaffold(body: PendingEditsBanner())),
      ),
    );
    await tester.pump(); // first stream emission

    // A rejection is not silent: the banner surfaces it and invites review.
    expect(find.textContaining('1 rejected'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);

    await tester.tap(find.byType(InkWell));
    await tester.pump(); // start the sheet route
    await tester.pump(const Duration(seconds: 1)); // finish its animation
    expect(find.text('My Song'), findsOneWidget);
    expect(find.text('Rejected by the server'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump(const Duration(seconds: 1));
    expect(await db.select(db.pendingEdits).get(), isEmpty);

    // Unmount the tree, then flush drift's stream-close timers (scheduled
    // during ProviderScope disposal) so the pending-timer invariant passes.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('pending-only state shows a passive banner', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    addTearDown(db.close);
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
      'updated_at) VALUES (\'u1\', \'{"title":"T"}\', \'db_only\', '
      '\'pending\', 0)',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(home: Scaffold(body: PendingEditsBanner())),
      ),
    );
    await tester.pump();

    expect(find.text('1 edit pending'), findsOneWidget);
    expect(find.text('Review'), findsNothing);

    // Flush drift's stream-close timers (see above).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('Dismiss goes through EditControls (SC-26)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
    addTearDown(db.close);
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
      'rejection_reason, updated_at) VALUES '
      '(\'u1\', \'{"title":"My Song"}\', \'db_only\', \'rejected\', '
      '\'Rejected by the server\', 0)',
    );
    final calls = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          editControlsProvider.overrideWithValue(_RecordingEdits(calls)),
        ],
        child: const MaterialApp(home: Scaffold(body: PendingEditsBanner())),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(calls, ['dismiss u1']);
    // Unmount inside the test so drift's stream-close timer is flushed.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  // D4 (owner, 2026-11-17): counts in words; a track is named for a person
  // (Title — Artist, else the edit's original values, else Unknown track),
  // never by its internal ID.
  group('D4', () {
    const id = '3f2c9a00-0000-4000-8000-000000000001';

    Future<AppDatabase> openDb() async {
      final db = AppDatabase(NativeDatabase.memory());
      await seedTestBinding(db); // SC-01: queue/outbox writes are fenced
      addTearDown(db.close);
      return db;
    }

    Future<void> insertEdit(
      AppDatabase db,
      String uuid, {
      required String status,
      String values = '{"genre":"Jazz"}',
      String? original,
    }) =>
        db.customStatement(
          'INSERT INTO pending_edits (uuid_id, values_json, write_mode, '
          'status, server_revision, original_values_json, updated_at) '
          "VALUES (?, ?, 'db_only', ?, 9, ?, 0)",
          [uuid, values, status, original],
        );

    Future<void> pumpBanner(WidgetTester tester, AppDatabase db,
        {EditControls? edits, bool trackLookupFails = false}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(testApiClient(
              'http://localhost:8000',
              MockClient((_) async => http.Response('', 404)),
            )),
            databaseProvider.overrideWithValue(db),
            if (edits != null) editControlsProvider.overrideWithValue(edits),
            if (trackLookupFails)
              browseRepositoryProvider
                  .overrideWithValue(_FailingTrackLookup(db)),
          ],
          child:
              const MaterialApp(home: Scaffold(body: PendingEditsBanner())),
        ),
      );
      await tester.pump();
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
    }

    Future<void> unmount(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets('the banner counts in words, singular and plural',
        (tester) async {
      final db = await openDb();
      await insertEdit(db, 'p1', status: 'pending');
      await insertEdit(db, 'p2', status: 'pending');
      await insertEdit(db, 'c1', status: 'conflicted');
      await pumpBanner(tester, db);
      expect(find.text('2 edits pending • 1 conflict'), findsOneWidget);

      await insertEdit(db, 'c2', status: 'conflicted');
      // customStatement does not notify drift's streams; a real write does.
      db.markTablesUpdated({db.pendingEdits});
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(find.text('2 edits pending • 2 conflicts'), findsOneWidget);
      await unmount(tester);
    });

    for (final (button, expected) in [
      ('Keep mine', ['keep $id']),
      ('Take server', ['take $id']),
      ('Decide later', <String>[]),
    ]) {
      testWidgets(
          'a conflict reads "Title — Artist" from this device; $button',
          (tester) async {
        final db = await openDb();
        await seedTrackRow(db, id, title: 'Song'); // artist 'OldA'
        await insertEdit(db, id, status: 'conflicted');
        final calls = <String>[];
        await pumpBanner(tester, db, edits: _RecordingEdits(calls));
        await openSheet(tester);

        expect(find.text('Song — OldA'), findsOneWidget);
        expect(find.textContaining(id), findsNothing);

        await tester.tap(find.text('Song — OldA'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('“Song — OldA” changed on the server since '
              'you edited it.'),
          findsOneWidget,
        );
        expect(find.textContaining(id), findsNothing);

        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(calls, expected);
        await unmount(tester);
      });
    }

    testWidgets(
        'without the track on this device, the edit\'s original values '
        'name it', (tester) async {
      final db = await openDb();
      await insertEdit(db, id,
          status: 'conflicted',
          original: '{"title":"Before","artist":"Band"}');
      await pumpBanner(tester, db);
      await openSheet(tester);
      expect(find.text('Before — Band'), findsOneWidget);
      expect(find.textContaining(id), findsNothing);
      await unmount(tester);
    });

    // Coordinator round 2 (R1): a failed track lookup must never empty the
    // sheet; the row keeps a name (the edit's original values, else
    // "Unknown track") and every button still works.
    for (final (button, expected) in [
      ('Keep mine', ['keep $id']),
      ('Take server', ['take $id']),
      ('Decide later', <String>[]),
    ]) {
      testWidgets('a failed track lookup still lists the conflict; $button',
          (tester) async {
        final db = await openDb();
        await seedTrackRow(db, id, title: 'Song');
        await insertEdit(db, id,
            status: 'conflicted',
            original: '{"title":"Before","artist":"Band"}');
        final calls = <String>[];
        await pumpBanner(tester, db,
            edits: _RecordingEdits(calls), trackLookupFails: true);
        await openSheet(tester);

        expect(find.text('Nothing to review'), findsNothing);
        expect(find.text('Before — Band'), findsOneWidget);
        expect(find.textContaining(id), findsNothing);

        await tester.tap(find.text('Before — Band'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
        expect(calls, expected);
        await unmount(tester);
      });
    }

    testWidgets(
        'a failed track lookup with no original values reads "Unknown '
        'track"', (tester) async {
      final db = await openDb();
      await insertEdit(db, id, status: 'rejected', values: '{"genre":"Rock"}');
      await pumpBanner(tester, db, trackLookupFails: true);
      await openSheet(tester);
      expect(find.text('Unknown track'), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('with neither, "Unknown track", never the ID',
        (tester) async {
      final db = await openDb();
      await insertEdit(db, id, status: 'rejected', values: '{"genre":"Rock"}');
      await pumpBanner(tester, db);
      await openSheet(tester);
      expect(find.text('Unknown track'), findsOneWidget);
      expect(find.textContaining(id), findsNothing);
      await unmount(tester);
    });
  });
}

class _RecordingEdits implements EditControls {
  _RecordingEdits(this.calls);
  final List<String> calls;
  @override
  Future<bool> hasPendingMasterWrite(String uuidId) async => false;
  @override
  Future<List<String>> suggestions(String fieldKey, String query) async =>
      const [];
  @override
  Future<EditSavePlan> planSave(TrackUI t, MetadataEdit e, EditWriteMode m) async =>
      EditSavePlan.ready;
  @override
  Future<EditSubmitted> submit(TrackUI t, MetadataEdit e, EditWriteMode m) async =>
      EditSubmitted.online;
  @override
  Future<void> resolveKeepMine(String uuidId) async => calls.add('keep $uuidId');
  @override
  Future<void> resolveTakeServer(String uuidId) async => calls.add('take $uuidId');
  @override
  Future<void> dismissRejected(String uuidId) async => calls.add('dismiss $uuidId');
}

/// The local track read fails (a database error).
class _FailingTrackLookup extends BrowseRepository {
  _FailingTrackLookup(super.db);

  @override
  Future<List<TrackUI>> getTracksByUuids(List<String> uuids) async =>
      throw StateError('track read failed');
}
