// 6-R1-04 (amends DEV-6-02): a menu Play next / Add to queue that nothing
// can play offline is not a silent no-op. The card menus (browse grids,
// Search, Home and See all all use these cards) show the same message the
// collection detail header shows, from one message source.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/models/ui/album_ui.dart';
import 'package:frontend/models/ui/artist_ui.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/ui/collection_detail_controller.dart';
import 'package:frontend/ui/library_actions.dart';
import 'package:frontend/ui/widgets/album_card.dart';
import 'package:frontend/ui/widgets/artist_card.dart';
import 'package:frontend/ui/widgets/track_card.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

import '../browse_harness.dart';
import '../fake_library_actions.dart';

class _StubOffline extends OfflineModeNotifier {
  _StubOffline(this._value);
  final bool _value;
  @override
  bool build() {
    super.build();
    return _value;
  }
}

/// Answers every queue action with [outcome].
class _OutcomeActions extends FakeLibraryActions {
  _OutcomeActions(this.outcome);
  PlaybackOutcome outcome;

  @override
  Future<PlaybackOutcome> playNext(LibraryScope scope) async {
    await super.playNext(scope);
    return outcome;
  }

  @override
  Future<PlaybackOutcome> addToQueue(LibraryScope scope) async {
    await super.addToQueue(scope);
    return outcome;
  }
}

/// A membership read that throws (no database behind it).
class _ThrowingBrowse extends BrowseRepository {
  _ThrowingBrowse() : super(AppDatabase(NativeDatabase.memory()));
  @override
  Future<List<TrackUI>> getTracksForScope(LibraryScope scope,
          {required bool offline}) =>
      Future.error(StateError('membership read failed'));
}

const _album = AlbumUI(
    id: 7, name: 'Test Album', artist: 'Test Artist', artistId: 3);
const _artist = ArtistUI(id: 3, name: 'Test Artist');

/// Offline, partly downloaded: the menu's queue rows are enabled (DEV-6-02),
/// but on this device nothing turns out to play.
Widget _build(Widget card, FakeLibraryActions? actions,
    {List<Override> overrides = const []}) {
  const counts = (downloaded: 1, total: 2);
  return ProviderScope(
    overrides: [
      coverArtCacheProvider.overrideWithValue(
        CoverArtCacheManager.noop(
          api: testApiClient(
            'http://localhost:8000',
            MockClient((_) async => http.Response('', 404)),
          ),
        ),
      ),
      albumIsDownloadingProvider.overrideWith((ref, id) => false),
      albumDownloadCountsProvider
          .overrideWith((ref, id) => const AsyncData(counts)),
      artistIsDownloadingProvider.overrideWith((ref, id) => false),
      artistDownloadCountsProvider
          .overrideWith((ref, id) => const AsyncData(counts)),
      offlineModeProvider.overrideWith(() => _StubOffline(true)),
      playbackAvailabilityProvider.overrideWith(
        (ref, scope) => PlaybackAvailability.of(
            offline: true,
            downloaded: counts.downloaded,
            total: counts.total),
      ),
      if (actions != null) libraryActionsProvider.overrideWithValue(actions),
      ...overrides,
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 200, height: 280, child: card),
      ),
    ),
  );
}

void main() {
  final cards = <(String, Widget Function())>[
    ('album card', () => AlbumCard(album: _album, onTap: () {})),
    ('artist card', () => ArtistCard(artist: _artist, onTap: () {})),
  ];

  for (final (name, card) in cards) {
    for (final row in ['Play Next', 'Add to Queue']) {
      testWidgets('$name, $row with nothing playable offline shows "Nothing '
          'here plays offline."', (tester) async {
        final actions = _OutcomeActions(const RejectedUnplayableOffline());
        await tester.pumpWidget(_build(card(), actions));
        await tester.pumpAndSettle();
        await tester.longPress(find.byWidgetPredicate(
            (w) => w is AlbumCard || w is ArtistCard));
        await tester.pumpAndSettle();
        await tester.tap(find.text(row));
        await tester.pumpAndSettle();

        expect(actions.calls, hasLength(1));
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('Nothing here plays offline.'), findsOneWidget);
        await teardownTree(tester);
      });
    }

    testWidgets('$name, an accepted Play Next shows no message',
        (tester) async {
      final actions = _OutcomeActions(const Accepted(1));
      await tester.pumpWidget(_build(card(), actions));
      await tester.pumpAndSettle();
      await tester.longPress(
          find.byWidgetPredicate((w) => w is AlbumCard || w is ArtistCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play Next'));
      await tester.pumpAndSettle();

      expect(actions.calls, hasLength(1));
      expect(find.byType(SnackBar), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('$name, a superseded Play Next shows no message',
        (tester) async {
      final actions = _OutcomeActions(const Superseded());
      await tester.pumpWidget(_build(card(), actions));
      await tester.pumpAndSettle();
      await tester.longPress(
          find.byWidgetPredicate((w) => w is AlbumCard || w is ArtistCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play Next'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      await teardownTree(tester);
    });
  }

  // 6-R2-08: every outcome text reaches the user through a menu.
  for (final (outcome, text) in <(PlaybackOutcome, String)>[
    (Failed(StateError('queue write failed')), "Couldn't start playback."),
    (const RejectedEmpty(), 'Nothing to play here right now.'),
  ]) {
    testWidgets('album card, Add to Queue ending $outcome shows "$text"',
        (tester) async {
      final actions = _OutcomeActions(outcome);
      await tester.pumpWidget(_build(
          AlbumCard(album: _album, onTap: () {}), actions));
      await tester.pumpAndSettle();
      await tester.longPress(find.byType(AlbumCard));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to Queue'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(text), findsOneWidget);
      await teardownTree(tester);
    });
  }

  // 6-R2-07: over the real LibraryActions, a membership read that throws
  // is the Failed text, not an uncaught error and no silence.
  testWidgets('album card, Add to Queue whose membership read throws shows '
      '"Couldn\'t start playback."', (tester) async {
    await tester.pumpWidget(_build(
      AlbumCard(album: _album, onTap: () {}),
      null,
      overrides: [
        browseRepositoryProvider.overrideWith((ref) => _ThrowingBrowse()),
      ],
    ));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(AlbumCard));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to Queue'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text("Couldn't start playback."), findsOneWidget);
    await teardownTree(tester);
  });

  // 6-R2-08: track menus (cards in rails, rows in lists) show it too.
  group('track menus', () {
    late AppDatabase db;
    late BrowseHarness harness;
    late TrackUI track;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await seedLibrary(db, const [
        SeedTrack(uuid: 'd', title: 'Local Song', artistId: 1, artist: 'Ann',
            albumId: 1, album: 'X', downloaded: true),
      ]);
      harness = await BrowseHarness.create(db);
      track = (await BrowseRepository(db).watchTracks().first).single;
    });

    tearDown(() async {
      await harness.dispose();
      await db.close();
    });

    final surfaces = <(String, Widget Function(TrackUI), Finder)>[
      (
        'track card',
        (t) => Center(
            child: SizedBox(
                width: 160,
                height: 260,
                child: TrackCard(track: t, onTap: () {}))),
        find.byType(TrackCard),
      ),
      (
        'track row',
        (t) => LibraryTrackTile(track: t, onTap: () {}),
        find.byIcon(Icons.more_vert),
      ),
    ];

    for (final (name, build, opener) in surfaces) {
      for (final row in ['Play Next', 'Add to Queue']) {
        testWidgets('$name, $row with nothing playable offline shows '
            '"Nothing here plays offline."', (tester) async {
          final actions = _OutcomeActions(const RejectedUnplayableOffline());
          await tester.pumpWidget(harness.wrap(
            Scaffold(body: build(track)),
            offline: true,
            overrides: [libraryActionsProvider.overrideWithValue(actions)],
          ));
          await tester.pumpAndSettle();
          if (name == 'track card') {
            await tester.longPress(opener);
          } else {
            await tester.tap(opener);
          }
          await tester.pumpAndSettle();
          await tester.tap(find.text(row));
          await tester.pumpAndSettle();
          expect(actions.calls, hasLength(1));
          expect(find.byType(SnackBar), findsOneWidget);
          expect(find.text('Nothing here plays offline.'), findsOneWidget);
          await teardownTree(tester);
        });
      }
    }
  });

  test('one message source: the detail controller and the menus map an '
      'outcome to the same text', () {
    for (final outcome in const <PlaybackOutcome>[
      Accepted(1),
      Superseded(),
      RejectedEmpty(),
      RejectedUnplayableOffline(),
    ]) {
      expect(CollectionDetailController.messageFor(outcome),
          playbackOutcomeMessage(outcome),
          reason: '$outcome');
    }
    expect(playbackOutcomeMessage(const RejectedUnplayableOffline()),
        'Nothing here plays offline.');
  });
}
