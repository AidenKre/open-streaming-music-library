// 8B.3 S8: how Possible duplicates is reached, and what Play and leaving the
// page do with the real preview stack.
//  * Spec §6: "Possible duplicates is its own Library tools destination
//    (SessionDestination.duplicates, SC-08), opened from a row contributed
//    to Library tools through the SC-21 registry and available when
//    library_tools.duplicate_review is true."
//  * Spec §6 Play: "through the shared preview/audition player ... It uses
//    the normal stream URL, never AudioCoordinator, so the user's queue is
//    untouched and no history click or play is recorded." Exit proof: Play
//    never touches PlaybackRequests, the queue or the history recorder
//    (spies).
//  * Brief (Phase 7 live gate 7-L-10): leaving a page whose dispose closed
//    the preview raised "Tried to modify a provider while the widget tree was
//    building": test leaving with the REAL preview controller over fakes
//    below it.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/services/duplicates/duplicates_review.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/history/click_recorder.dart';
import 'package:frontend/services/history/listen_recorder.dart';
import 'package:frontend/ui/duplicates/duplicates_controller.dart';
import 'package:frontend/ui/duplicates/duplicates_page.dart';
import 'package:frontend/ui/session/session_host.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/settings/settings_registry.dart';

import '../../helpers/duplicate_fixtures.dart';
import '../../helpers/fake_library_tools_api.dart';
import '../../helpers/fake_audio_focus.dart' show RelinquishingOwner, FakeTimers;
import '../../helpers/fake_preview_engine.dart' show FakePreviewEngine;
import '../browse_harness.dart';
import '../fake_session_controls.dart';
import 'fake_duplicates_controls.dart';

SettingsRowContribution _row(ProviderContainer c) =>
    c.read(settingsRowsProvider).singleWhere(
      (r) =>
          r.sectionId == 'library_tools' &&
          r.isAvailable == duplicateReviewAdvertisedProvider,
    );

class _NoSession implements AudioSessionPort {
  @override
  Stream<AudioSessionEvent> get events => const Stream.empty();
}

void main() {
  late AppDatabase db;
  late BrowseHarness h;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
  });
  tearDown(() async {
    await h.dispose();
    await db.close();
  });

  group('the Library tools row', () {
    test('is contributed to Library tools and is available exactly when the '
        'server offers duplicate_review', () {
      for (final offered in [true, false]) {
        final c = ProviderContainer(
          overrides: [
            duplicateReviewAdvertisedProvider.overrideWithValue(offered),
          ],
        );
        expect(c.read(_row(c).isAvailable!), offered);
        c.dispose();
      }
    });

    testWidgets('opens SessionDestination.duplicates', (tester) async {
      final fake = FakeDuplicatesControls();
      final c = ProviderContainer();
      final row = _row(c);
      c.dispose();
      await tester.pumpWidget(
        h.wrap(
          SessionHost(root: Scaffold(body: Builder(builder: row.build))),
          overrides: [
            sessionControlsProvider.overrideWithValue(FakeSessionControls()),
            duplicatesControllerFactoryProvider.overrideWithValue(() => fake),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Possible duplicates'));
      await tester.pumpAndSettle();
      expect(find.byType(DuplicatesPage), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(DuplicatesPage)))!.settings.name,
        'session/duplicates',
      );
      await teardownTree(tester);
    });
  });

  test('the destination builds the Possible duplicates page', () {
    expect(
      sessionDestinationPage(SessionDestination.duplicates),
      isA<DuplicatesPage>(),
    );
  });

  group('Play and leaving, with the real preview stack', () {
    late FakeTimers timers;
    late AudioFocus focus;
    late List<FakePreviewEngine> engines;
    late FakeLibraryToolsApi api;
    late List<String> touched;

    setUp(() {
      timers = FakeTimers();
      focus = AudioFocus(_NoSession(), timer: timers.create);
      engines = [];
      touched = [];
      api = FakeLibraryToolsApi();
      api.onDuplicateSummary = () async => dupSummary(open: 1);
      api.onListDuplicates = (status, after, limit) async =>
          dupPage([dupPair('a1', 'b1')]);
    });
    tearDown(() => focus.dispose());

    Future<ProviderContainer> openPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        h.wrap(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const DuplicatesPage()),
                ),
                child: const Text('open duplicates'),
              ),
            ),
          ),
          overrides: [
            libraryToolsApiProvider.overrideWithValue(api),
            libraryToolsFeatureProvider.overrideWith(
              (ref) async => const AdvertisedFeature(
                LibraryToolsFeature(
                  version: 1,
                  serverDelete: false,
                  duplicateReview: true,
                ),
                fromCache: false,
              ),
            ),
            audioFocusProvider.overrideWithValue(focus),
            previewSourceUrisProvider.overrideWithValue(
              PreviewSourceUris(
                baseUrl: 'http://srv:1',
                mediaToken: 'mt',
                mayAttachToken: () async => true,
                isOffline: () => false,
              ),
            ),
            previewEngineFactoryProvider.overrideWithValue(() {
              final e = FakePreviewEngine();
              engines.add(e);
              return e;
            }),
            // Spies: building either history recorder is a failure.
            clickRecorderProvider.overrideWith((ref) {
              touched.add('click recorder');
              throw StateError('the click recorder was reached');
            }),
            listenRecorderProvider.overrideWith((ref) {
              touched.add('listen recorder');
              throw StateError('the listen recorder was reached');
            }),
          ],
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open duplicates'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pair-a1|b1')), findsOne);
      return ProviderScope.containerOf(
        tester.element(find.text('open duplicates', skipOffstage: false)),
      );
    }

    testWidgets('Play auditions the copy and never reaches playback requests, '
        'the queue or the history recorders', (tester) async {
      final container = await openPage(tester);
      await tester.tap(find.byKey(const Key('play-b1')));
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(engines, hasLength(1));
      engines.single.finishLoad(const Duration(seconds: 30));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      final state = container.read(previewPlayerProvider);
      expect(state.source, const LibraryTrackPreview('b1'));
      expect(state.status, PreviewStatus.playing);
      expect(engines.single.loads.single.path, contains('b1'));
      expect(focus.holder, AudioOutput.preview);
      // PlaybackRequests.submit and the queue player record every call here.
      expect(h.audio.calls, isEmpty);
      expect(h.audio.intents, isEmpty);
      expect(touched, isEmpty);
      await teardownTree(tester);
    });

    // Pre-merge R3-L-01: this page closes the preview at the pop (the upload
    // review page did not). Pinned here for the audition that still loads.
    testWidgets('leaving the page while an audition still loads gives the '
        'output back at the pop, before the page is gone', (tester) async {
      final library = RelinquishingOwner('queue');
      focus.bind(AudioOutput.queue, library);
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
      await openPage(tester);
      await tester.tap(find.byKey(const Key('play-a1')));
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(library.relinquishes, 1);
      library.acknowledge();
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(focus.holder, AudioOutput.preview);
      expect(engines.single.loads, hasLength(1));

      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(DuplicatesPage), findsOneWidget,
          reason: 'precondition: the page is still animating out');
      expect(focus.holder, AudioOutput.queue);
      expect(library.returns, 1);
      expect(engines.single.disposed, isTrue);
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      expect(tester.takeException(), isNull);
      expect(engines.single.plays, 0);
      expect(library.returns, 1);
      await teardownTree(tester);
    });

    testWidgets('leaving the page while a preview plays closes it without '
        'touching provider state during dispose', (tester) async {
      final container = await openPage(tester);
      await tester.tap(find.byKey(const Key('play-a1')));
      await tester.pump();
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      engines.single.finishLoad(const Duration(seconds: 30));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump();
      expect(container.read(previewPlayerProvider).status, PreviewStatus.playing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());

      expect(tester.takeException(), isNull);
      expect(find.byType(DuplicatesPage), findsNothing);
      expect(container.read(previewPlayerProvider).status, PreviewStatus.idle);
      expect(engines.single.disposed, isTrue);
      expect(focus.holder, isNot(AudioOutput.preview));
      expect(h.audio.calls, isEmpty);
      expect(touched, isEmpty);
      await teardownTree(tester);
    });
  });
}
