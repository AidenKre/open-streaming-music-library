import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/ui/widgets/pending_edits_banner.dart';

void main() {
  testWidgets('rejected edit is visible with its reason and dismissible',
      (tester) async {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('', 404)),
    );
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
      'rejection_reason, updated_at) VALUES '
      '(\'u1\', \'{"title":"My Song"}\', \'db_only\', \'rejected\', '
      '\'Rejected by the server\', 0)',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
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

    expect(find.textContaining('1 edit(s) pending'), findsOneWidget);
    expect(find.text('Review'), findsNothing);

    // Flush drift's stream-close timers (see above).
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}
