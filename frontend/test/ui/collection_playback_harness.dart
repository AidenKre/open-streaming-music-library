// Shared by the Phase 6A.2 collection tests that drive real pages through
// the real LibraryActions, PlaybackRequests and ClickRecorder over in-memory
// Drift, with only the audio player faked.
import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/history_intent.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/playback_requests.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/playback/playback_target_resolver.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/history/click_recorder.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';

import '../helpers/fake_clock.dart';
import '../helpers/no_server_api.dart';
import 'browse_harness.dart';
import '../helpers/stub_track_sync.dart';
import '../helpers/test_offline.dart';

/// The audio player, faked: an optional current queue that accepts
/// enqueues, and an activation that always succeeds.
class CollectionPlayer extends QueuePlayer {
  CollectionPlayer(this.sessionId);
  final int? sessionId;
  final enqueued = <List<String>>[];
  final activated = <int>[];

  @override
  AudioState build() => AudioState(queue: QueueSlice(sessionId: sessionId));

  @override
  Future<EnqueueResult> enqueue(List<String> uuids, EnqueuePosition position,
      {required int expectedSessionId,
      MonotonicStopwatch? sinceSubmitted}) async {
    enqueued.add(uuids);
    return EnqueueResult.applied;
  }

  @override
  Future<ActivationResult> activatePreparedSession(
    int sessionId,
    PlaybackTarget target, {
    required bool autoPlay,
    required int requestRevision,
  }) async {
    activated.add(sessionId);
    return ActivationResult.accepted;
  }

  @override
  Future<void> reportIssues(Iterable<Object?> issues,
      {bool publish = true}) async {}
}

/// A page in a scope with the real collection playback path; [overrides]
/// come last (e.g. codecs or the resolver's file check).
Widget collectionPlaybackScope({
  required AppDatabase db,
  required LocalCoverArtStore covers,
  required Directory dir,
  required CollectionPlayer player,
  required Widget child,
  bool offline = false,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      coverArtCacheProvider.overrideWithValue(CoverArtCacheManager.noop()),
      localCoverArtStoreProvider.overrideWithValue(covers),
      downloadManagerProvider.overrideWithValue(DownloadManager(
        db: db,
        coverArtStore: covers,
        directoryProvider: () async => dir,
        apiClient: noServerApi(),
      )),
      offlineModeProvider.overrideWith(() => TestOffline(offline)),
      trackSyncProvider.overrideWith(StubTrackSync.new),
      appInfoProvider.overrideWith((ref) async => const AppInfo()),
      conversionJobsProvider.overrideWith(EmptyConversionJobs.new),
      queuePlayerProvider.overrideWith(() => player),
      clockProvider.overrideWithValue(FakeClock()),
      clickRecorderProvider.overrideWith(SpyClickRecorder.new),
      ...overrides,
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

/// The clicked history rows, oldest first, as (entity type, entity ref).
Future<List<(String, String)>> recordedClicks(
    WidgetTester tester, AppDatabase db) async {
  final rows = await tester.runAsync(() async {
    await pumpEventQueue();
    return (db.select(db.historyEvents)
          ..where((e) => e.kind.equals('clicked'))
          ..orderBy([(e) => OrderingTerm(expression: e.localId)]))
        .get();
  });
  return [for (final r in rows!) (r.entityType, r.entityRef)];
}

/// Whether a click row has been written. Reads the database directly, so it
/// runs in real async (inside `runAsyncUntil`'s condition).
Future<bool> clickRecorded(AppDatabase db) async =>
    (await (db.select(db.historyEvents)
              ..where((e) => e.kind.equals('clicked')))
            .get())
        .isNotEmpty;

/// The app's click recorder, also counting each click at the moment it is
/// submitted. The write itself is not awaited by playback, so a check that
/// no click was recorded reads [submitted], which is exact once the request
/// has an outcome, instead of racing the database write.
class SpyClickRecorder extends ClickRecorder {
  SpyClickRecorder(Ref ref)
      : super(
          history: ref.read(historyRepositoryProvider),
          binding: ref.read(serverBindingRepositoryProvider),
          clock: ref.read(clockProvider),
        );

  final submitted = <HistoryIntent>[];

  @override
  Future<void> record(HistoryIntent intent) {
    submitted.add(intent);
    return super.record(intent);
  }
}

/// The scope's [SpyClickRecorder].
SpyClickRecorder clickSpy(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(clickRecorderProvider) as SpyClickRecorder;
