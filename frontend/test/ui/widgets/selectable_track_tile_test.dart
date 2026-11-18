import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import '../browse_harness.dart' show teardownTree;

const _track = TrackUI(
  uuidId: 'u1',
  createdAt: 1,
  lastUpdated: 1,
  revision: 3,
  title: 'Some Track',
  artist: 'Some Artist',
  duration: 180,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

/// SC-17 selection row: a checkbox, a tap that toggles, nothing else.
void main() {
  late int toggles;

  setUp(() => toggles = 0);

  Future<void> pump(WidgetTester tester, {required bool selected}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SelectableTrackTile(
              track: _track,
              selected: selected,
              onToggle: () => toggles++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Checkbox checkbox(WidgetTester tester) =>
      tester.widget<Checkbox>(find.byType(Checkbox));

  testWidgets('the checkbox shows the selection state', (tester) async {
    await pump(tester, selected: false);
    expect(checkbox(tester).value, isFalse);
    await pump(tester, selected: true);
    expect(checkbox(tester).value, isTrue);
    await teardownTree(tester);
  });

  testWidgets('a tap on the row toggles', (tester) async {
    await pump(tester, selected: false);
    await tester.tap(find.text('Some Track'));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    await teardownTree(tester);
  });

  testWidgets('a tap on the checkbox toggles once', (tester) async {
    await pump(tester, selected: true);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    await teardownTree(tester);
  });

  testWidgets('no action menu, and the row is neither dimmed nor inert', (
    tester,
  ) async {
    await pump(tester, selected: false);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    final tile = tester.widget<TrackTile>(find.byType(TrackTile));
    expect(tile.menu, isEmpty);
    expect(tile.isDimmed, isFalse);
    expect(tile.isInteractive, isTrue);
    await teardownTree(tester);
  });

  testWidgets('the checkbox leads the row, before the title', (tester) async {
    await pump(tester, selected: false);
    expect(
      tester.getTopLeft(find.byType(Checkbox)).dx,
      lessThan(tester.getTopLeft(find.text('Some Track')).dx),
    );
    await teardownTree(tester);
  });
}
