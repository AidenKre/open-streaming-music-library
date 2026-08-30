import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/ui/get_info_page.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._v);
  final bool _v;
  @override
  bool build() => _v;
}

const _track = TrackUI(
  uuidId: 'u1',
  createdAt: 0,
  lastUpdated: 0,
  title: 'Old Title',
  artist: 'Old Artist',
  album: 'Old Album',
  codec: 'flac',
  duration: 200,
  bitrateKbps: 1000,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

Future<AppDatabase> _pump(
  WidgetTester tester, {
  AppInfo? caps,
  Future<void> Function(AppDatabase db)? seed,
}) async {
  // Tall surface so the whole form + info rows build (the ListView is lazy, so
  // off-screen widgets wouldn't be in the tree on the default 800x600).
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  if (seed != null) await seed(db);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appInfoProvider.overrideWith((ref) async => caps ?? defaultAppInfo()),
        // Offline so Save just enqueues (no flush / network) in these tests.
        offlineModeProvider.overrideWith(() => _StubOffline(true)),
      ],
      child: const MaterialApp(home: GetInfoPage(track: _track)),
    ),
  );
  await tester.pumpAndSettle();
  return db;
}

Future<List<PendingEdit>> _pending(AppDatabase db) =>
    db.select(db.pendingEdits).get();

Future<void> _enterEditMode(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, 'Edit'));
  await tester.pumpAndSettle();
}

Finder _dialogText(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  testWidgets('opens in view-only mode with metadata and info rows', (
    tester,
  ) async {
    await _pump(tester);

    // Metadata tier (labels from capabilities, values from the track).
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Genre'), findsOneWidget);
    expect(find.text('Old Title'), findsOneWidget);
    expect(find.text('Old Artist'), findsOneWidget);
    // Info tier.
    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('Path'), findsOneWidget);
    expect(find.text('44100 Hz'), findsOneWidget);
    // Opens view-only: no editable fields or save controls yet.
    expect(find.byType(TextField), findsNothing);
    expect(find.widgetWithText(TextButton, 'Edit'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Save'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsNothing);
  });

  testWidgets('Edit enables fields and Save with no changes shows a notice', (
    tester,
  ) async {
    await _pump(tester);
    await _enterEditMode(tester);

    expect(find.byType(TextField), findsWidgets);
    expect(find.widgetWithText(TextButton, 'Edit'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Save'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pump();
    expect(find.text('No changes to save'), findsOneWidget);
  });

  testWidgets('Cancel exits edit mode and discards pending field edits', (
    tester,
  ) async {
    final db = await _pump(tester);
    await _enterEditMode(tester);
    await tester.enterText(
      find.byKey(const ValueKey('field_title')),
      'New Title',
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('New Title'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Edit'), findsOneWidget);

    await _enterEditMode(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pump();
    expect(find.text('No changes to save'), findsOneWidget);
    expect(await _pending(db), isEmpty);
  });

  testWidgets('editing a field then Save enqueues a db_only edit', (
    tester,
  ) async {
    final db = await _pump(tester);
    await _enterEditMode(tester);
    await tester.enterText(
      find.byKey(const ValueKey('field_title')),
      'New Title',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final rows = await _pending(db);
    expect(rows, hasLength(1));
    expect(rows.single.uuidId, 'u1');
    expect(rows.single.writeMode, 'db_only');
    expect(rows.single.valuesJson, contains('New Title'));
  });

  testWidgets('DB+master Save is gated by the confirmation dialog', (
    tester,
  ) async {
    final db = await _pump(tester);
    await _enterEditMode(tester);
    await tester.enterText(
      find.byKey(const ValueKey('field_title')),
      'New Title',
    );
    await tester.tap(find.text('Update master file on server'));
    await tester.pump();
    expect(
      find.text(
        'Rewrites tags on the backend server’s disk; may move the file.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Update the master file on the server?'), findsOneWidget);
    expect(
      find.text(
        'This permanently rewrites the master audio file’s tags on the backend '
        'server’s disk. If the artist or album changed, the server may move '
        'the file. The app cannot undo this.',
      ),
      findsOneWidget,
    );

    await tester.tap(_dialogText('Edit file'));
    await tester.pumpAndSettle();

    final rows = await _pending(db);
    expect(rows, hasLength(1));
    expect(rows.single.writeMode, 'db_and_master');
  });

  testWidgets('cancelling the confirmation dialog does not enqueue', (
    tester,
  ) async {
    final db = await _pump(tester);
    await _enterEditMode(tester);
    await tester.enterText(
      find.byKey(const ValueKey('field_title')),
      'New Title',
    );
    await tester.tap(find.text('Update master file on server'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    await tester.tap(_dialogText('Cancel'));
    await tester.pumpAndSettle();
    expect(await _pending(db), isEmpty);
  });

  testWidgets(
      'toggling the switch off does not skip the confirm dialog '
      'when db_and_master is already queued for this track', (tester) async {
    final db = await _pump(
      tester,
      seed: (db) => db.customStatement(
        "INSERT INTO pending_edits (uuid_id, values_json, write_mode, "
        "base_revision, status, server_revision, original_values_json, updated_at) "
        "VALUES ('u1', '{\"title\":\"Queued\"}', 'db_and_master', 5, 'pending', "
        "NULL, '{\"title\":\"Old Title\"}', 0)",
      ),
    );
    await _enterEditMode(tester);
    await tester.tap(find.text('Update master file on server')); // toggled OFF
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('field_artist')),
      'New Artist',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Update the master file on the server?'), findsOneWidget);
    final rows = await _pending(db);
    expect(rows.single.writeMode, 'db_and_master');
  });

  testWidgets(
      'saving with no field changes on a conflicted row must not '
      'silently resolve the conflict', (tester) async {
    final db = await _pump(
      tester,
      seed: (db) => db.customStatement(
        "INSERT INTO pending_edits (uuid_id, values_json, write_mode, "
        "base_revision, status, server_revision, original_values_json, updated_at) "
        "VALUES ('u1', '{\"title\":\"Mine\"}', 'db_and_master', 5, 'conflicted', 9, "
        "'{\"title\":\"Old Title\"}', 0)",
      ),
    );
    await _enterEditMode(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    if (find.text('Update the master file on the server?').evaluate().isNotEmpty) {
      await tester.tap(_dialogText('Edit file'));
      await tester.pumpAndSettle();
    }
    final row = await (db.select(db.pendingEdits)
          ..where((t) => t.uuidId.equals('u1')))
        .getSingle();
    expect(row.status, 'conflicted');
    expect(row.baseRevision, 5);
  });
}
