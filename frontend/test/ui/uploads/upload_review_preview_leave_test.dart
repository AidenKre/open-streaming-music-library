// Pre-merge R3-L-01 (third live run): music playing, Play preview on the
// upload review page, leave the page while the preview still loads. The
// music stayed paused. The real page, the real review and preview
// controllers, the real PreviewPlayer, AudioFocus and QueuePlayer; fakes only
// below them (the two engines, the review model, the audio session).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/ui/uploads/upload_review_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/fake_audio_focus.dart'
    show FakeAudioSessionPort, FakeTimers;
import '../../helpers/fake_clock.dart';
import '../../helpers/fake_playback_engine.dart';
import '../../helpers/fake_preview_engine.dart' show FakePreviewEngine;
import '../../helpers/fake_uploads_api.dart' show itemJson;
import '../../helpers/library_fixture.dart';
import '../../helpers/no_server_api.dart';
import '../../helpers/playback_submit.dart';
import '../../helpers/server_binding.dart';
import '../../helpers/stub_track_sync.dart';
import '../../helpers/test_offline.dart';
import '../browse_harness.dart';
import '../fake_uploads_controls.dart';

UploadItem _item(String uuid, {int index = 0}) => UploadItem.fromJson({
  ...itemJson(
    uuid,
    filename: '$uuid.flac',
    selectionIndex: index,
    state: 'review_ready',
    expectedBytes: 3,
    receivedBytes: 3,
    reviewVersion: 1,
  ),
  'tag_write_supported': true,
  'result_track_uuid': null,
  'detected_metadata': {
    'v': 1,
    'tags': {'title': 'Title of $uuid', 'artist': null},
  },
});

class _Review implements UploadReview {
  final snap = [_item('u1', index: 0), _item('u2', index: 1)];

  @override
  Future<List<UploadItem>> snapshot(String batchUuid,
          {Set<String> keep = const {}}) async =>
      [...snap];

  @override
  Future<UploadItem> item(String itemUuid) async =>
      snap.firstWhere((i) => i.itemUuid == itemUuid);

  /// When set, the next read of an item's draft waits for it (a slow
  /// local read).
  Completer<void>? draftGate;

  @override
  Future<MetadataEdit> draftOf(String itemUuid) async {
    final gate = draftGate;
    draftGate = null;
    await gate?.future;
    return const MetadataEdit.empty();
  }

  @override
  Future<void> saveDraft(String itemUuid, MetadataEdit edit) async {}

  @override
  Set<DuplicateGroup> chosenDuplicates(UploadItem item) => const {};

  @override
  Future<List<String>> suggestions(String key, String query) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Home extends StatelessWidget {
  const _Home();
  @override
  Widget build(BuildContext context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) =>
                  const UploadReviewPage(batchUuid: 'b-1', startAt: 'u1'))),
          child: const Text('open review'),
        ),
      );
}

/// A library engine whose pause is not reported inside the call: the
/// library's hand-over stays unacknowledged until the test reports it.
class _LateReportEngine extends FakePlaybackEngine {
  @override
  Future<void> pause() async {
    pauseCalls++;
    wantsPlaying = false;
  }
}

class _Bridge extends AudioServiceBridge {}

void main() {
  late AppDatabase db;
  late BrowseHarness harness;
  late FakeAudioSessionPort sessionPort;
  late AudioFocus focus;
  late FakePlaybackEngine library;
  late List<FakePreviewEngine> previews;
  late _Review review;
  late StreamController<List<UploadIntentRecord>> intents;
  late StreamController<int> downloads;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db);
    harness = await BrowseHarness.create(db);
    sessionPort = FakeAudioSessionPort();
    focus = AudioFocus(sessionPort, timer: FakeTimers().create);
    library = FakePlaybackEngine();
    previews = [];
    review = _Review();
    intents = StreamController<List<UploadIntentRecord>>.broadcast();
    downloads = StreamController<int>.broadcast();
  });

  tearDown(() async {
    container.dispose();
    focus.dispose();
    await sessionPort.controller.close();
    await intents.close();
    await downloads.close();
    await harness.dispose();
    await db.close();
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
  }

  /// Music plays from the library (it holds the output), and the review
  /// page is open on its first item.
  Future<void> musicPlayingOnReviewPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      apiClientProvider.overrideWithValue(noServerApi()),
      coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
      localCoverArtStoreProvider.overrideWithValue(harness.coverStore),
      downloadManagerProvider.overrideWithValue(harness.manager),
      offlineModeProvider.overrideWith(() => TestOffline(false)),
      trackSyncProvider.overrideWith(StubTrackSync.new),
      appInfoProvider.overrideWith((ref) async => defaultAppInfo()),
      conversionJobsProvider.overrideWith(EmptyConversionJobs.new),
      sessionReadinessProvider
          .overrideWithValue(SessionReadiness()..markReady()),
      clockProvider.overrideWithValue(FakeClock()),
      playbackEngineProvider.overrideWithValue(library),
      audioFocusProvider.overrideWithValue(focus),
      audioSessionPortProvider.overrideWithValue(sessionPort),
      audioServiceProvider.overrideWithValue(_Bridge()),
      downloadStatusVersionProvider.overrideWith((ref) => downloads.stream),
      uploadReviewProvider.overrideWithValue(review),
      uploadIntentsProvider.overrideWith((ref) => intents.stream),
      uploadsOverviewProvider
          .overrideWith((ref) => fakeUploadsOverview(const [])),
      uploadedTrackProvider
          .overrideWith((ref, uuid) => const Stream<TrackUI?>.empty()),
      previewSourceUrisProvider.overrideWithValue(PreviewSourceUris(
        baseUrl: 'http://srv:1',
        mediaToken: 'mt',
        mayAttachToken: () async => true,
        isOffline: () => false,
      )),
      previewEngineFactoryProvider.overrideWithValue(() {
        final e = FakePreviewEngine();
        previews.add(e);
        return e;
      }),
    ]);
    // The library player is built and started outside the test's fake time,
    // so its start-up work completes.
    await tester.runAsync(() => Future(() async {
          container.listen(queuePlayerProvider, (_, _) {});
          await pumpEventQueue();
          final fixture = LibraryFixture(db);
          await fixture.insertSingles(['a', 'b']);
          await playFromTrackList(container, const ['a', 'b'],
              await fixture.track('a'), sourceType: 'test');
          expect(await focus.beforePlay(AudioOutput.queue), isTrue);
          library.emitPlayerState(
              const EngineTransportState(true, EngineProcessingState.ready));
          await pumpEventQueue();
        }).timeout(const Duration(seconds: 10)));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: _Home()),
    ));
    await tester.pump();
    await tester.tap(find.text('open review'));
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.byType(UploadReviewPage), findsOneWidget);
    expect(container.read(audioPlayWhenReadyProvider), isTrue,
        reason: 'precondition: music plays');
    expect(focus.holder, AudioOutput.queue);
  }

  /// The route is popped (Back); while the page animates out, [meanwhile]
  /// happens (in the app the hand-over and the preview's load complete
  /// within that time); then the page is gone. Only fake time passes while
  /// the page animates.
  Future<void> leaveThePage(WidgetTester tester,
      {Future<void> Function()? meanwhile}) async {
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(UploadReviewPage), findsOneWidget,
        reason: 'precondition: the page is still animating out');
    if (meanwhile != null) {
      await meanwhile();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.byType(UploadReviewPage), findsNothing);
    expect(tester.takeException(), isNull);
  }

  void expectMusicPlaysOn({required int playsBefore}) {
    expect(library.wantsPlaying, isTrue, reason: 'the music plays again');
    expect(library.playCalls, playsBefore + 1);
    expect(container.read(audioPlayWhenReadyProvider), isTrue);
    expect(container.read(currentTrackProvider)?.uuidId, 'a');
    expect(library.seekedItems, isEmpty, reason: 'same track, same position');
    expect(focus.holder, AudioOutput.queue);
    expect(previews.fold<int>(0, (n, e) => n + e.plays), 0,
        reason: 'the preview never sounded');
    expect(container.read(previewPlayerProvider).status, PreviewStatus.idle);
  }

  testWidgets('leaving while the preview loads, the hand-over granted: the '
      'music plays on, and the load that completes while the page animates '
      'out never sounds', (tester) async {
    await musicPlayingOnReviewPage(tester);
    final plays = library.playCalls;
    await tester.tap(find.text('Play preview'));
    await settle(tester);
    expect(focus.holder, AudioOutput.preview, reason: 'precondition: granted');
    expect(library.wantsPlaying, isFalse, reason: 'the hand-over paused it');
    expect(container.read(previewPlayerProvider).status, PreviewStatus.loading);

    await leaveThePage(tester, meanwhile: () async {
      if (!previews.single.disposed) {
        previews.single.finishLoad(const Duration(seconds: 30));
      }
    });
    expectMusicPlaysOn(playsBefore: plays);
    await teardownTree(tester);
  });

  testWidgets('leaving while the hand-over is asked and not yet granted: the '
      'music plays on, and neither the late acknowledgement nor a load ever '
      'makes the preview sound', (tester) async {
    library = _LateReportEngine();
    await musicPlayingOnReviewPage(tester);
    final plays = library.playCalls;
    await tester.tap(find.text('Play preview'));
    await settle(tester);
    expect(library.pauseCalls, 1, reason: 'the library paused for it');
    expect(focus.holder, AudioOutput.queue,
        reason: 'precondition: not yet acknowledged');
    expect(container.read(previewPlayerProvider).status, PreviewStatus.loading);

    await leaveThePage(tester, meanwhile: () async {
      // The pause's report arrives now, and then the preview's load
      // completes; before the fix the first granted the hand-over and the
      // second made the preview sound while the page slid away.
      if (!library.wantsPlaying) {
        library.emitPlayerState(
            const EngineTransportState(false, EngineProcessingState.ready));
      }
      await tester.pump(const Duration(milliseconds: 20));
      for (final e in previews) {
        if (!e.disposed && e.loads.isNotEmpty) e.finishLoad(null);
      }
    });
    expectMusicPlaysOn(playsBefore: plays);
    await teardownTree(tester);
  });

  testWidgets('going to the next item while the preview loads: the music '
      'plays on', (tester) async {
    await musicPlayingOnReviewPage(tester);
    final plays = library.playCalls;
    await tester.tap(find.text('Play preview'));
    await settle(tester);
    expect(focus.holder, AudioOutput.preview, reason: 'precondition: granted');
    await tester.tap(find.text('Next'));
    await settle(tester);
    await tester.pumpAndSettle();
    await settle(tester);
    expectMusicPlaysOn(playsBefore: plays);
    await teardownTree(tester);
  });

  // A preview that sounds while the next item is being read would leave the
  // music paused for good: once it has sounded, closing it hands nothing
  // back. So the preview is closed when the person asks to move on, before
  // the next item's draft is read.
  testWidgets('going to the next item while the preview loads, and its load '
      'completes while the next item is still being read: the preview never '
      'sounds and the music plays on', (tester) async {
    await musicPlayingOnReviewPage(tester);
    final plays = library.playCalls;
    await tester.tap(find.text('Play preview'));
    await settle(tester);
    expect(focus.holder, AudioOutput.preview, reason: 'precondition: granted');
    final draft = review.draftGate = Completer<void>();
    await tester.tap(find.text('Next'));
    await settle(tester);
    expect(review.draftGate, isNull,
        reason: 'precondition: the next item\'s draft is being read');
    previews.single.finishLoad(const Duration(seconds: 30));
    await settle(tester);
    draft.complete();
    await settle(tester);
    await tester.pumpAndSettle();
    await settle(tester);
    expect(find.text('2/2'), findsOneWidget,
        reason: 'precondition: the review moved to the next item');
    expectMusicPlaysOn(playsBefore: plays);
    await teardownTree(tester);
  });

  testWidgets('the preview cannot load after the music was paused for it: '
      'the music plays on while the page stays open, and the page says the '
      'preview could not play', (tester) async {
    await musicPlayingOnReviewPage(tester);
    final plays = library.playCalls;
    await tester.tap(find.text('Play preview'));
    await settle(tester);
    expect(focus.holder, AudioOutput.preview, reason: 'precondition: granted');
    expect(library.wantsPlaying, isFalse, reason: 'the hand-over paused it');
    previews.single.failLoad();
    await settle(tester);
    expect(find.byType(UploadReviewPage), findsOneWidget);
    expect(find.text("Preview couldn't play"), findsOneWidget);
    expect(library.wantsPlaying, isTrue, reason: 'the music plays again');
    expect(library.playCalls, plays + 1);
    expect(container.read(audioPlayWhenReadyProvider), isTrue);
    expect(container.read(currentTrackProvider)?.uuidId, 'a');
    expect(library.seekedItems, isEmpty, reason: 'same track, same position');
    expect(focus.holder, AudioOutput.queue);
    expect(previews.single.plays, 0);
    await teardownTree(tester);
  });

  testWidgets('leaving after the preview sounded: the music stays paused '
      '(unchanged), and the preview stops at once, not when the page is gone',
      (tester) async {
    await musicPlayingOnReviewPage(tester);
    final plays = library.playCalls;
    await tester.tap(find.text('Play preview'));
    await settle(tester);
    previews.single.finishLoad(const Duration(seconds: 30));
    await settle(tester);
    expect(container.read(previewPlayerProvider).status, PreviewStatus.playing);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(UploadReviewPage), findsOneWidget,
        reason: 'precondition: the page is still animating out');
    expect(previews.single.disposed, isTrue,
        reason: 'stopped when the person left');
    await tester.pumpAndSettle();
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(library.playCalls, plays);
    expect(container.read(audioPlayWhenReadyProvider), isFalse);
    await teardownTree(tester);
  });

  testWidgets('leaving after headphones were unplugged while it loaded: the '
      'music does not start', (tester) async {
    await musicPlayingOnReviewPage(tester);
    final plays = library.playCalls;
    await tester.tap(find.text('Play preview'));
    await settle(tester);
    expect(focus.holder, AudioOutput.preview, reason: 'precondition: granted');
    sessionPort.emit(const AudioBecameNoisy());
    await settle(tester);
    await leaveThePage(tester);
    expect(library.playCalls, plays);
    expect(container.read(audioPlayWhenReadyProvider), isFalse);
    await teardownTree(tester);
  });
}
