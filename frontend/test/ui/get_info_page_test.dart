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

Future<AppDatabase> _pump(WidgetTester tester, {AppInfo? caps}) async {
  // Tall surface so the whole form + info rows build (the ListView is lazy, so
  // off-screen widgets wouldn't be in the tree on the default 800x600).
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
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

void main() {
  testWidgets('renders editable fields and display-only info rows',
      (tester) async {
    await _pump(tester);

    // Editable tier (labels from capabilities).
    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Artist'), findsOneWidget);
    expect(find.text('Genre'), findsOneWidget);
    // Info tier.
    expect(find.text('Codec'), findsOneWidget);
    expect(find.text('Path'), findsOneWidget);
    expect(find.text('44100 Hz'), findsOneWidget);
    // Intrinsic audio fields never appear as editable inputs.
    expect(find.widgetWithText(TextField, 'Bitrate'), findsNothing);
  });

  testWidgets('Save with no changes shows the no-changes notice',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('No changes to save'), findsOneWidget);
  });

  testWidgets('editing a field then Save enqueues a db_only edit',
      (tester) async {
    final db = await _pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('field_title')), 'New Title');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final rows = await _pending(db);
    expect(rows, hasLength(1));
    expect(rows.single.uuidId, 'u1');
    expect(rows.single.writeMode, 'db_only');
    expect(rows.single.valuesJson, contains('New Title'));
  });

  testWidgets('DB+master Save is gated by the confirmation dialog',
      (tester) async {
    final db = await _pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('field_title')), 'New Title');
    await tester.tap(find.text('Also write tags to the file on disk'));
    await tester.pump();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Also edit the file on disk?'), findsOneWidget);

    await tester.tap(find.text('Edit file'));
    await tester.pumpAndSettle();

    final rows = await _pending(db);
    expect(rows, hasLength(1));
    expect(rows.single.writeMode, 'db_and_master');
  });

  testWidgets('cancelling the confirmation dialog does not enqueue',
      (tester) async {
    final db = await _pump(tester);
    await tester.enterText(
        find.byKey(const ValueKey('field_title')), 'New Title');
    await tester.tap(find.text('Also write tags to the file on disk'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await _pending(db), isEmpty);
  });
}
