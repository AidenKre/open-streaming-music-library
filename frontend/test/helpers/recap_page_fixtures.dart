// The Year in music page's fixtures: a fixed now, its token, recaps built
// through listeningStatsOf, and the fake page controller (moved here from
// annual_recap_page_test.dart, APP-TEST stage 2).
import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:frontend/models/annual_recap.dart';
import 'package:frontend/models/listening_stats.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/repositories/history_snapshot.dart';
import 'package:frontend/ui/annual_recap_controller.dart';

import 'listening_stats_builder.dart';

final now = utc(2026, 3, 15, 12);

HistorySnapshotToken tokenAt(int nowMs) => HistorySnapshotToken(
  boundaryLocalId: 19,
  historyContentVersion: 0,
  capturedNowUtcMs: nowMs,
  filterKey: 'k',
);

TrackUI track(String uuid, String? title) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  title: title,
  duration: 200,
  bitrateKbps: null,
  sampleRateHz: null,
  channels: null,
  hasAlbumArt: false,
);

AnnualRecap recapOf(
  int year, {
  double seconds = 0,
  int qualified = 0,
  int unique = 0,
  int days = 0,
  double unavailable = 0,
  List<double> monthly = const [],
  List<RankedEntry<TrackUI>> tracks = const [],
  List<RankedEntry<ArtistUI>> artists = const [],
  List<RankedEntry<AlbumUI>> albums = const [],
}) {
  final range = StatsRange.year(year);
  return AnnualRecap.fromStats(
    listeningStatsOf(
      range: range,
      window: range.resolve(now),
      boundaryLocalId: 19,
      seconds: seconds,
      qualifiedPlays: qualified,
      uniqueTracks: unique,
      activeDays: days,
      unavailableSeconds: unavailable,
      buckets: [
        for (var i = 0; i < monthly.length; i++)
          ListeningBucket(
            startUtcMs: utc(year, i + 1),
            endUtcMs: utc(year, i + 2),
            listeningSeconds: monthly[i],
          ),
      ],
      topTracks: tracks,
      topArtists: artists,
      topAlbums: albums,
    ),
    tokenAt(now),
  );
}

/// 2025 as in the recap fixture, with 2 h added in March.
AnnualRecap prior() => recapOf(
  2025,
  seconds: 9220.5,
  qualified: 9,
  unique: 7,
  days: 11,
  unavailable: 100,
  monthly: [120.5, 0, 7800, 0, 250, 0, 600, 0, 300, 0, 100, 50],
  tracks: [
    for (final (u, t, s) in [
      ('t-a', 'Alpha', 420.5),
      ('t-c', 'Gamma', 400.0),
      ('t-b', 'Beta', 300.0),
      ('t-d', null, 280.0),
      ('t-e', 'Epsilon', 250.0),
    ])
      RankedEntry(entity: track(u, t), listeningSeconds: s, qualifiedPlays: 1),
  ],
  artists: const [
    RankedEntry(
      entity: ArtistUI(id: 1, name: 'Aria'),
      listeningSeconds: 720.5,
      qualifiedPlays: 3,
    ),
  ],
  albums: const [
    RankedEntry(
      entity: AlbumUI(id: 10, artistId: 1, name: 'First Light', artist: 'Aria'),
      listeningSeconds: 720.5,
      qualifiedPlays: 3,
    ),
  ],
);

class FakeRecapControls extends ChangeNotifier implements AnnualRecapControls {
  FakeRecapControls({this.year, this.recap, this.years = const []});

  @override
  int? year;
  @override
  List<int> years;
  @override
  AnnualRecap? recap;
  @override
  bool loading = false;
  @override
  bool failed = false;

  final calls = <String>[];
  bool disposed = false;

  void set({AnnualRecap? recap, bool loading = false, bool failed = false}) {
    this.recap = recap;
    this.loading = loading;
    this.failed = failed;
    notifyListeners();
  }

  @override
  void selectYear(int year) => calls.add('selectYear($year)');

  @override
  void refresh() => calls.add('refresh');

  @override
  void retry() => calls.add('retry');

  @override
  bool canSave = true;
  @override
  bool canShare = true;
  @override
  bool exporting = false;

  /// What each export intent answers.
  String? exportAnswer;

  /// Completed when the next export intent arrives.
  Completer<void>? nextExport;

  void _exported() {
    final c = nextExport;
    nextExport = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  void setExporting(bool value) {
    exporting = value;
    notifyListeners();
  }

  /// The PNG bytes each image intent received.
  final pngs = <Uint8List>[];

  @override
  Future<String?> savePng(Uint8List png) async {
    calls.add('savePng');
    pngs.add(png);
    _exported();
    return exportAnswer;
  }

  @override
  Future<String?> saveJson() async {
    calls.add('saveJson');
    _exported();
    return exportAnswer;
  }

  @override
  Future<String?> sharePng(Uint8List png, {Rect? origin}) async {
    calls.add('sharePng');
    pngs.add(png);
    shareOrigins.add(origin);
    _exported();
    return exportAnswer;
  }

  final shareOrigins = <Rect?>[];

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}
