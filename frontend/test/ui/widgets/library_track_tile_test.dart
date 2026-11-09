import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/get_info_page.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/library_action_menu.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import '../browse_harness.dart';
import '../fake_library_actions.dart';

/// The page-facing track row: availability, menu, Get info and the
/// controller come from providers; the page supplies only the tap.
void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeLibraryActions actions;
  late Map<String, TrackUI> tracks;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(uuid: 'remote', title: 'Remote', artistId: 1, artist: 'A',
          albumId: 1, album: 'X'),
      SeedTrack(uuid: 'local', title: 'Local', artistId: 1, artist: 'A',
          albumId: 1, album: 'X', trackNumber: 2, downloaded: true),
    ]);
    harness = await BrowseHarness.create(db);
    actions = FakeLibraryActions();
    tracks = {
      for (final t in await BrowseRepository(db).watchTracks().first)
        t.uuidId: t,
    };
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Widget host(Widget child, {bool offline = false}) => harness.wrap(
    Scaffold(body: child),
    offline: offline,
    overrides: [libraryActionsProvider.overrideWithValue(actions)],
  );

  testWidgets('offline, a streaming-only track is dimmed and inert',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(host(
      LibraryTrackTile(track: tracks['remote']!, onTap: () => tapped = true),
      offline: true,
    ));
    await tester.pump();
    final tile = tester.widget<TrackTile>(find.byType(TrackTile));
    expect(tile.isDimmed, isTrue);
    expect(tile.isInteractive, isFalse);
    await tester.tap(find.text('Remote'));
    expect(tapped, isFalse);
    await teardownTree(tester);
  });

  testWidgets('offline, a streaming-only track still offers Get info',
      (tester) async {
    await tester.pumpWidget(host(
      LibraryTrackTile(track: tracks['remote']!, onTap: () {}),
      offline: true,
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Add to Queue')).enabled,
      isFalse,
      reason: 'play/queue stay blocked',
    );
    await tester.tap(find.text('Get Info'));
    await tester.pumpAndSettle();
    expect(find.byType(GetInfoPage), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('offline, a downloaded track plays', (tester) async {
    var tapped = false;
    await tester.pumpWidget(host(
      LibraryTrackTile(track: tracks['local']!, onTap: () => tapped = true),
      offline: true,
    ));
    await tester.pump();
    expect(tester.widget<TrackTile>(find.byType(TrackTile)).isDimmed, isFalse);
    await tester.tap(find.text('Local'));
    expect(tapped, isTrue);
    await teardownTree(tester);
  });

  // Review major 1 (user, 2026-11-09): a codec this device can't decode is
  // shown, and its download doesn't play offline.
  testWidgets('a download in an undecodable codec says so and is inert '
      'offline', (tester) async {
    var tapped = false;
    final track = tracks['local']!.copyWith(downloadedCodec: 'alac');
    await tester.pumpWidget(harness.wrap(
      Scaffold(
          body: LibraryTrackTile(track: track, onTap: () => tapped = true)),
      offline: true,
      overrides: [
        libraryActionsProvider.overrideWithValue(actions),
        codecSupportProvider.overrideWithValue(
            const CodecSupport({AudioCodecFamily.mp3, AudioCodecFamily.aac})),
      ],
    ));
    await tester.pump();
    expect(find.text('Unsupported codec'), findsOneWidget);
    expect(tester.widget<TrackTile>(find.byType(TrackTile)).unsupportedCodec,
        'ALAC');
    expect(tester.widget<TrackTile>(find.byType(TrackTile)).isInteractive,
        isFalse);
    await tester.tap(find.text('Local'));
    expect(tapped, isFalse);
    // Still a download: the user can delete it.
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Delete download')).enabled,
      isTrue,
    );
    await teardownTree(tester);
  });

  testWidgets('a decodable track shows no codec warning', (tester) async {
    await tester.pumpWidget(host(
      LibraryTrackTile(track: tracks['local']!, onTap: () {}),
    ));
    await tester.pump();
    expect(find.text('Unsupported codec'), findsNothing);
    await teardownTree(tester);
  });

  testWidgets('menu actions go to the controller for this track',
      (tester) async {
    await tester.pumpWidget(host(
      LibraryTrackTile(track: tracks['remote']!, onTap: () {}),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Queue'));
    await tester.pumpAndSettle();
    expect(actions.calls, ['addToQueue track(remote)']);
    await teardownTree(tester);
  });

  testWidgets('Get Info opens the inspector', (tester) async {
    await tester.pumpWidget(host(
      LibraryTrackTile(track: tracks['remote']!, onTap: () {}),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get Info'));
    await tester.pumpAndSettle();
    expect(find.byType(GetInfoPage), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('surface-specific rows come last', (tester) async {
    await tester.pumpWidget(host(
      LibraryTrackTile(
        track: tracks['remote']!,
        onTap: () {},
        extraActions: [
          LibraryMenuAction(icon: Icons.transform, label: 'Convert…',
              onSelected: () {}),
        ],
      ),
    ));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    final labels = [
      for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
        (t.title as Text).data,
    ];
    expect(labels.last, 'Convert…');
    await teardownTree(tester);
  });
}
