// Phase 8B.2a / SC-21: pending owned-file cleanup contributes a "Sync &
// storage" diagnostics row: "Storage cleanup pending (N)" while rows wait for
// a retry, "Nothing pending" otherwise. The count is model state (a stream
// over `owned_file_cleanup`); the row only observes it.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/storage/owned_file_cleanup_providers.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';
import 'package:frontend/ui/settings/storage_cleanup_diagnostics_view.dart';

import 'browse_harness.dart';

void main() {
  test('the row is contributed to Sync & storage', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(diagnosticsRowsProvider).map((r) => r.id),
      contains(storageCleanupDiagnosticsRow.id),
    );
  });

  test('the pending count follows the cleanup table', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final seen = <int>[];
    final sub = container.listen<AsyncValue<int>>(
      ownedFileCleanupPendingCountProvider,
      (_, next) {
        final v = next.value;
        if (v != null && (seen.isEmpty || seen.last != v)) seen.add(v);
      },
      fireImmediately: true,
    );
    addTearDown(sub.close);
    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    await settle();
    // Through drift's API, as the cleanup's own writes are (a raw
    // customStatement notifies no stream).
    await db.transaction(() async {
      for (final path in ['/d/tracks/a', '/d/tracks/b']) {
        await db.into(db.ownedFileCleanupEntries).insert(
          OwnedFileCleanupEntriesCompanion.insert(
            path: path,
            rootKind: 'downloads',
            createdAt: 1,
          ),
        );
      }
    });
    await settle();
    await (db.delete(db.ownedFileCleanupEntries)
          ..where((r) => r.path.equals('/d/tracks/a')))
        .go();
    await settle();
    expect(seen, [0, 2, 1]);
  });

  Future<void> pump(WidgetTester tester, WidgetBuilder build, int pending) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [
            ownedFileCleanupPendingCountProvider.overrideWith(
              (ref) => Stream.value(pending),
            ),
          ],
          child: MaterialApp(home: Scaffold(body: Builder(builder: build))),
        ),
      );

  testWidgets('summary names the pending count', (tester) async {
    await pump(tester, storageCleanupDiagnosticsRow.buildSummary, 3);
    await tester.pump();
    expect(find.text('Storage cleanup'), findsOneWidget);
    expect(find.text('Storage cleanup pending (3)'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('summary with nothing pending', (tester) async {
    await pump(tester, storageCleanupDiagnosticsRow.buildSummary, 0);
    await tester.pump();
    expect(find.text('Nothing pending'), findsOneWidget);
    expect(find.textContaining('pending ('), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('detail names the count and says it is retried', (tester) async {
    await pump(tester, storageCleanupDiagnosticsRow.buildDetail, 2);
    await tester.pump();
    expect(find.text('Storage cleanup pending (2)'), findsOneWidget);
    expect(find.textContaining('retried'), findsOneWidget);
    await teardownTree(tester);
  });
}
