// 7B.1d S13: uploads' "Sync & storage" diagnostics row (spec §7 para 3:
// "Pending/quarantined transfer counts also contribute a Settings
// diagnostics row (SC-21)"). The model counts this binding's files still to
// send (pending) and those held back until the user acts (quarantined:
// reselect, changed source, refused allocation), plus rows left by an
// earlier sign-in, which will never be sent; the view only observes it.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/uploads/upload_diagnostics.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';
import 'package:frontend/ui/settings/upload_diagnostics_view.dart';

import '../../helpers/server_binding.dart';
import '../../ui/browse_harness.dart';

Future<void> _insert(AppDatabase db, String item, String state,
        {required String token}) =>
    db.customStatement(
      "INSERT INTO upload_intents (item_uuid, batch_uuid, selection_index, "
      "display_name, last_state, local_binding_id, created_at, updated_at) "
      "VALUES ('$item', 'b', 0, '$item.flac', '$state', '$token', 1, 1)",
    );

void main() {
  group('counts', () {
    late AppDatabase db;
    late ProviderContainer c;
    late String token;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      token = await seedTestBinding(db, reconciled: true);
      c = ProviderContainer(overrides: [databaseProvider.overrideWithValue(db)]);
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('pending, quarantined and earlier-sign-in counts', () async {
      for (final (i, s) in [
        ('p1', 'allocating'),
        ('p2', 'allocated'),
        ('p3', 'transferring'),
        ('p4', 'cancelling'),
        ('q1', 'needs_reselect'),
        ('q2', 'source_changed'),
        ('q3', 'rejected'),
        ('d1', 'validating'),
        ('d2', 'review_ready'),
        ('d3', 'imported'),
        ('d4', 'cancelled'),
        ('d5', 'failed'),
      ]) {
        await _insert(db, i, s, token: token);
      }
      await _insert(db, 'old', 'allocated', token: 'earlier-token');

      final seen = <UploadDiagnostics>[];
      final sub = c.listen(
        uploadDiagnosticsProvider,
        (_, next) {
          if (next.value != null) seen.add(next.value!);
        },
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await pumpEventQueue();

      final d = seen.last;
      expect(d.pending, 4);
      expect(d.quarantined, 3);
      expect(d.earlierSignIn, 1);
    });

    test('follows writes', () async {
      final seen = <int>[];
      final sub = c.listen(
        uploadDiagnosticsProvider,
        (_, next) {
          if (next.value != null) seen.add(next.value!.pending);
        },
        fireImmediately: true,
      );
      addTearDown(sub.close);
      await pumpEventQueue();
      // A Drift write through the database API notifies the stream.
      await db.into(db.uploadIntents).insert(
        UploadIntentsCompanion.insert(
          itemUuid: 'n',
          batchUuid: 'b',
          selectionIndex: 0,
          displayName: 'n.flac',
          lastState: 'allocated',
          localBindingId: token,
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await pumpEventQueue();
      expect(seen.first, 0);
      expect(seen.last, 1);
    });
  });

  group('row', () {
    Future<void> pump(
      WidgetTester tester,
      WidgetBuilder build,
      UploadDiagnostics d,
    ) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          uploadDiagnosticsProvider.overrideWith((ref) => Stream.value(d)),
        ],
        child: MaterialApp(home: Scaffold(body: Builder(builder: build))),
      ),
    );

    test('the row is contributed to Sync & storage', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(diagnosticsRowsProvider).map((r) => r.id),
        contains(uploadDiagnosticsRow.id),
      );
    });

    testWidgets('summary: held-back files first, then files to send',
        (tester) async {
      await pump(tester, uploadDiagnosticsRow.buildSummary,
          const UploadDiagnostics(pending: 2, quarantined: 1, earlierSignIn: 0));
      await tester.pump();
      expect(find.text('Uploads'), findsOneWidget);
      expect(find.text('1 upload needs your attention'), findsOneWidget);
      await teardownTree(tester);

      await pump(tester, uploadDiagnosticsRow.buildSummary,
          const UploadDiagnostics(pending: 2, quarantined: 0, earlierSignIn: 0));
      await tester.pump();
      expect(find.text('2 uploads waiting to send'), findsOneWidget);
      await teardownTree(tester);

      await pump(tester, uploadDiagnosticsRow.buildSummary,
          const UploadDiagnostics(pending: 0, quarantined: 0, earlierSignIn: 0));
      await tester.pump();
      expect(find.text('Nothing waiting'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('detail shows every count, including an earlier sign-in',
        (tester) async {
      await pump(tester, uploadDiagnosticsRow.buildDetail,
          const UploadDiagnostics(pending: 3, quarantined: 2, earlierSignIn: 1));
      await tester.pump();
      expect(find.textContaining('Waiting to send: 3'), findsOneWidget);
      expect(find.textContaining('Need your attention: 2'), findsOneWidget);
      expect(find.textContaining('From an earlier sign-in: 1'), findsOneWidget);
      await teardownTree(tester);
    });
  });
}
