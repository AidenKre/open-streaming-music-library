// Shared set-up of the 9A.2b top-list widget tests: the statistics page over
// a fake controller inside the browse harness (real Drift, real Phase 4
// cards, the shared SC-06 menu and availability), with a seeded catalog
// whose ids match the hand-written cards.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/services/history/history_diagnostics.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/listening_stats/listening_stats_controller.dart';
import 'package:frontend/ui/listening_stats/stats_ranked_card.dart';
import 'package:frontend/ui/listening_stats_page.dart';

import '../browse_harness.dart';
import '../fake_listening_stats_controls.dart';
import 'stats_page_harness.dart' show sevenDays;

/// Catalog: artist 1 "Ann" (album 10 "One": t-a "Same", remote), artist 2
/// "Bea" (album 20 "Two": t-b "Same", downloaded). Same titles, other uuids.
const catalog = [
  SeedTrack(uuid: 't-a', title: 'Same', artistId: 1, artist: 'Ann',
      albumId: 10, album: 'One'),
  SeedTrack(uuid: 't-b', title: 'Same', artistId: 2, artist: 'Bea',
      albumId: 20, album: 'Two', downloaded: true),
];

TrackUI trackOf(String uuid, {bool downloaded = false}) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: 'Same',
  artist: uuid == 't-a' ? 'Ann' : 'Bea',
  artistId: uuid == 't-a' ? 1 : 2,
  albumId: uuid == 't-a' ? 10 : 20,
  duration: 180,
  bitrateKbps: null,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
  filePath: downloaded ? '/local/$uuid.flac' : null,
);

const ann = ArtistUI(id: 1, name: 'Ann');
const bea = ArtistUI(id: 2, name: 'Bea');
const one = AlbumUI(id: 10, artistId: 1, name: 'One', artist: 'Ann');
const two = AlbumUI(id: 20, artistId: 2, name: 'Two', artist: 'Bea');

StatsRankedCard card(
  Object entity,
  int rank,
  double seconds,
  int plays, {
  bool unavailable = false,
}) => StatsRankedCard(
  entity: feedEntityOf(entity)!,
  rank: rank,
  listeningSeconds: seconds,
  qualifiedPlays: plays,
  unavailable: unavailable,
);

/// t-b (downloaded) first with 1 h 1 min 59.9 s and 4 plays, t-a (remote)
/// second with 59.9 s and 1 play; the same order for artists and albums.
StatsTopLists lists({bool tAUnavailable = false}) => StatsTopLists(
  tracks: [
    card(trackOf('t-b', downloaded: true), 1, 3719.9, 4),
    card(trackOf('t-a'), 2, 59.9, 1, unavailable: tAUnavailable),
  ],
  artists: [card(bea, 1, 3719.9, 4), card(ann, 2, 59.9, 1)],
  albums: [card(two, 1, 3719.9, 4), card(one, 2, 59.9, 1)],
);

const emptyLists = StatsTopLists(tracks: [], artists: [], albums: []);

class TopListsHarness {
  late AppDatabase db;
  late BrowseHarness browse;
  final fake = FakeListeningStatsControls();

  Future<void> setUp() async {
    db = AppDatabase(NativeDatabase.memory());
    browse = await BrowseHarness.create(db);
    await seedLibrary(db, catalog);
  }

  Future<void> tearDown() async {
    await browse.dispose();
    await db.close();
  }

  /// Opens the statistics page showing a ready snapshot with [topLists].
  Future<void> open(
    WidgetTester tester,
    StatsTopLists? topLists, {
    bool offline = false,
    ListeningStatsState? state,
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fake.lists = topLists;
    fake.show(state ??
        StatsReady(sevenDays(seconds: 3779.8, plays: 5, tracks: 2, days: 1),
            hasHistory: true, pendingListens: 0));
    await tester.pumpWidget(browse.wrap(
      const ListeningStatsPage(),
      offline: offline,
      overrides: [
        listeningStatsControllerFactoryProvider.overrideWithValue(() => fake),
        historyDiagnosticsProvider.overrideWith(
          (ref) => const Stream<HistoryDiagnostics>.empty(),
        ),
        ...overrides,
      ],
    ));
    // A loading page has an endless spinner: pump, never settle here.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// The top-list section [id] (`tracks`, `artists`, `albums`).
Finder section(String id) => find.byKey(ValueKey('stats-top-$id'));

/// The card of [entityKey] (`track:t-a`, `album:10`, …).
Finder cardOf(String entityKey) => find.byKey(ValueKey(entityKey));

/// [text] inside the card of [entityKey].
Finder inCard(String entityKey, String text) =>
    find.descendant(of: cardOf(entityKey), matching: find.text(text));

/// The opacity of the card of [entityKey] (1 = not dimmed).
double opacityOf(WidgetTester tester, String entityKey) => tester
    .widget<Opacity>(
      find
          .descendant(of: cardOf(entityKey), matching: find.byType(Opacity))
          .first,
    )
    .opacity;
