import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/downloaded_tracks_page.dart';

import 'browse_harness.dart';

/// The Downloaded page's header: how many tracks are on the device and
/// their size (other-issues row 34, U24-FE-DL-A-10: one track reads
/// "1 track", never "1 tracks").
void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<void> pumpWith(
    WidgetTester tester, {
    required int count,
    required int totalBytes,
  }) async {
    await tester.pumpWidget(
      harness.wrap(
        const DownloadedTracksPage(),
        overrides: [
          downloadedStatsProvider.overrideWith(
            (ref) => Stream.value((count: count, totalBytes: totalBytes)),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
  }

  // 4.2 MB: 4.2 * 1024 * 1024 bytes, rounded.
  const fourPointTwoMb = 4404019;

  for (final (count, bytes, expected) in [
    (1, fourPointTwoMb, '1 track • 4.2 MB'),
    (1, 0, '1 track'),
    (3, fourPointTwoMb, '3 tracks • 4.2 MB'),
    (3, 0, '3 tracks'),
  ]) {
    testWidgets('$count downloaded, $bytes bytes: "$expected"', (
      tester,
    ) async {
      await pumpWith(tester, count: count, totalBytes: bytes);
      expect(find.text(expected), findsOneWidget);
      await teardownTree(tester);
    });
  }

  testWidgets('nothing downloaded: no header', (tester) async {
    await pumpWith(tester, count: 0, totalBytes: 0);
    expect(find.textContaining(RegExp(r'^\d+ tracks?\b')), findsNothing);
    await teardownTree(tester);
  });
}
