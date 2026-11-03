import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/utils/library_search_controller.dart';

import '../browse_harness.dart';

/// SC-26: pages get their search controller from the factory provider; no
/// view constructs one with a repository.
void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late List<String> requests;

  setUpAll(() {
    ApiClient.init('http://localhost:8000');
    initCoverArtCache(CoverArtCacheManager.noop());
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    harness = await BrowseHarness.create(db);
    requests = [];
  });

  tearDown(() async {
    await harness.dispose();
    await db.close();
  });

  String describe(Set<SearchType> types, int limit) =>
      '${(types.map((t) => t.name).toList()..sort()).join('+')}@$limit';

  for (final (name, page, expected) in [
    ('Artists root', const ArtistsPage(isRoot: true), 'artists@100'),
    ('Tracks root', const TracksPage(isRoot: true), 'tracks@100'),
    ('global Search', const SearchPage(), 'albums+artists+tracks@5'),
  ]) {
    testWidgets('$name asks the factory for its controller', (tester) async {
      await tester.pumpWidget(harness.wrap(
        page,
        overrides: [
          librarySearchControllerFactoryProvider.overrideWith(
            (ref) =>
                ({required types, required limitPerType, required downloadedOnly}) {
                  requests.add(describe(types, limitPerType));
                  return LibrarySearchController(
                    repository: BrowseRepository(ref.read(databaseProvider)),
                    types: types,
                    limitPerType: limitPerType,
                    downloadedOnly: downloadedOnly,
                  );
                },
          ),
        ],
      ));
      await tester.pumpAndSettle();
      expect(requests, [expected]);
      await teardownTree(tester);
    });
  }

  test('the default factory builds a controller over the repository',
      () async {
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final search = container.read(librarySearchControllerFactoryProvider)(
      types: {SearchType.tracks},
      limitPerType: 100,
      downloadedOnly: () => false,
    );
    addTearDown(search.dispose);
    expect(search.isActive, isFalse);
    expect(search.results.tracks, isEmpty);
  });
}
