// Phase 9 §5 ("deterministic and entirely local") / 9-R02 ("no external
// recommendation traffic"), unit half by construction: the real Home
// suggestions controller over the real model (snapshot service, pools,
// SC-12 hydration, freshness, hide preference, download watch) on an
// in-memory database never instantiates an HTTP or API client provider.
// The two inputs owned elsewhere are pinned: the current track (a select over
// QueuePlayer state, SC-27) and the Phase 6 Home chip controller.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/home_suggestions_service.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/feed/feed.dart';
import 'package:frontend/ui/home/home_controller.dart';
import 'package:frontend/ui/home/home_suggestions_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../repositories/catalog_seed.dart';
import '../../helpers/fake_home_controls.dart';

void main() {
  test('every suggestion path runs with no HTTP or API client in the graph',
      () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final seed = CatalogSeed(db);
    await seed.artist(1, 'One');
    await seed.track('t1', artistId: 1, title: 'a', downloaded: true);
    await seed.track('t2', artistId: 1, title: 'b');
    await seed.click('track', 't1', at: 1, kind: 'play', eventUuid: 'e1');

    final chip = FakeHomeControls(const HomeRecentsEmpty(filtered: false));
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        homeControlsProvider.overrideWithValue(chip),
        currentTrackProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    final prefs = container.listen(homeLayoutPreferencesProvider, (_, _) {});
    addTearDown(prefs.close);
    await container.read(homeLayoutPreferencesProvider.future);

    final controls = container.read(homeSuggestionsControlsProvider);
    await pumpEventQueue();
    expect(controls.stateOf(SuggestionRail.rediscover), isA<SuggestionRailReady>());

    // New history, a filter change, Home hidden and shown, a scrolled rail,
    // its notice, a download change, a hide.
    await seed.click('track', 't2', at: 2, kind: 'play', eventUuid: 'e2');
    await pumpEventQueue();
    chip.setDownloaded(true);
    await pumpEventQueue();
    controls.setHomeVisible(false);
    controls.setHomeVisible(true);
    controls.setRailEngagement(
      SuggestionRail.moreFromArtists,
      const RailEngagement(atStart: false, pointerDown: false),
    );
    await seed.click('track', 't2', at: 3, kind: 'play', eventUuid: 'e3');
    await pumpEventQueue();
    controls.refreshRail(SuggestionRail.moreFromArtists);
    await seed.track('t3', artistId: 1, title: 'c', downloaded: true);
    await pumpEventQueue();
    await container
        .read(homeLayoutPreferencesProvider.notifier)
        .setHidden('home.rediscover', true);
    await pumpEventQueue();

    expect(container.exists(httpClientProvider), isFalse);
    expect(container.exists(apiClientProvider), isFalse);
    expect(container.exists(publicApiClientProvider), isFalse);
    expect(container.exists(boundApiClientProvider), isFalse);
  });
}
