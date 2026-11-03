import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/get_info_page.dart';
import 'package:frontend/ui/navigation/library_routes.dart';
import 'package:frontend/ui/tracks_page.dart';

import '../browse_harness.dart';

void main() {
  late AppDatabase db;
  late BrowseHarness harness;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedLibrary(db, const [
      SeedTrack(uuid: 'u1', title: 'Song', artistId: 4, artist: 'Ann',
          albumId: 9, album: 'Ann - Singles', albumIsSingles: true),
    ]);
    harness = await BrowseHarness.create(db);
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext hostContext;
    await tester.pumpWidget(harness.wrap(Builder(builder: (context) {
      hostContext = context;
      return const Scaffold(body: Text('host'));
    })));
    return hostContext;
  }

  testWidgets('album detail carries album id and artist id; Singles title',
      (tester) async {
    final context = await pumpHost(tester);
    openAlbumDetail(
      context,
      const AlbumUI(id: 9, artistId: 4, artist: 'Ann', isSingleGrouping: true),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Ann - Singles'), findsOneWidget);
    final page = tester.widget<TracksPage>(find.byType(TracksPage));
    expect((page.artistId, page.albumId, page.browseAll), (4, 9, false));
    await teardownTree(tester);
  });

  testWidgets('a named album uses its name', (tester) async {
    final context = await pumpHost(tester);
    openAlbumDetail(context, const AlbumUI(id: 9, artistId: 4, name: 'Blue'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Blue'), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('artist detail opens that artist\'s albums', (tester) async {
    final context = await pumpHost(tester);
    openArtistDetail(context, const ArtistUI(id: 4, name: 'Ann'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Ann'), findsOneWidget);
    expect(tester.widget<AlbumsPage>(find.byType(AlbumsPage)).artistId, 4);
    await teardownTree(tester);
  });

  testWidgets('Get info opens the track inspector', (tester) async {
    final context = await pumpHost(tester);
    final track = await tester.runAsync(
      () => BrowseRepository(harness.db).getTrack('u1'),
    );
    expect(context.mounted, isTrue);
    // ignore: use_build_context_synchronously
    openTrackInfo(context, track!);
    await tester.pumpAndSettle();
    expect(tester.widget<GetInfoPage>(find.byType(GetInfoPage)).track.uuidId,
        'u1');
    await teardownTree(tester);
  });
}
