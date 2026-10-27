import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/cover_art_cache_manager.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/ui/conversions_page.dart';
import 'package:frontend/ui/convert_flow.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/track_tile.dart';

/// Stands in for the real flush + `/changes` pull. [bumpRevisionTo] writes a
/// newer server revision during the "pull", the way a real sync would, so a
/// test can prove the flow reads the revision only after the sync.
class _StubTrackSync extends TrackSyncNotifier {
  _StubTrackSync({
    this.db,
    this.bumpUuid,
    this.bumpRevisionTo,
    this.result = true,
    this.gate,
  });

  final AppDatabase? db;
  final String? bumpUuid;
  final int? bumpRevisionTo;
  final bool result;

  /// When set, [syncFresh] doesn't complete until this does (a slow pull).
  final Completer<void>? gate;
  int syncFreshCalls = 0;

  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {}

  @override
  Future<bool> syncFresh() async {
    syncFreshCalls++;
    if (gate != null) await gate!.future;
    if (db != null && bumpUuid != null && bumpRevisionTo != null) {
      await db!.updateTrackRevision(bumpUuid!, bumpRevisionTo!);
    }
    return result;
  }
}

class _Offline extends OfflineModeNotifier {
  _Offline(this.value);
  final bool value;

  @override
  bool build() => value;
}

class _RecordingConversionJobs extends ConversionJobsNotifier {
  _RecordingConversionJobs({this.error});

  /// Thrown from [enqueue] when set (simulates a rejected POST /jobs).
  final Object? error;
  final List<Map<String, dynamic>> enqueueCalls = [];
  int refreshAllCalls = 0;

  @override
  List<ConversionJob> build() => const [];

  @override
  Future<void> refreshAll() async {
    refreshAllCalls++;
  }

  @override
  Future<ConversionJob> enqueue({
    required String uuidId,
    required String targetCodec,
    required int? targetBitrateKbps,
    required int? baseRevision,
  }) async {
    enqueueCalls.add({
      'uuidId': uuidId,
      'targetCodec': targetCodec,
      'targetBitrateKbps': targetBitrateKbps,
      'baseRevision': baseRevision,
    });
    if (error != null) throw error!;
    return ConversionJob(
      jobId: 1,
      uuidId: uuidId,
      targetCodec: targetCodec,
      targetContainer: 'm4a',
      status: const ConversionQueued(),
    );
  }
}

const _trackEntity = {'track': EntityInfo(actions: ['convert'])};

const _capabilities = AppInfo(
  entities: _trackEntity,
  conversion: ConversionCapabilities(
    targets: [
      ConversionTargetInfo(codec: 'aac', isLossless: false),
      ConversionTargetInfo(codec: 'flac', isLossless: true),
    ],
    bitratePresets: [320, 256, 192, 128],
  ),
);

Future<void> _insertTrack(
  AppDatabase db, {
  required String uuid,
  String codec = 'flac',
  double bitrateKbps = 1000.0,
  int revision = 1,
  String? filePath,
  String title = 'T',
}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 1000,
    'last_updated': 1000,
    'revision': revision,
    'metadata': {
      'title': title,
      'artist': 'A',
      'codec': codec,
      'duration': 1.0,
      'bitrate_kbps': bitrateKbps,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  });
  await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
  await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  if (filePath != null) {
    await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid)))
        .write(TracksCompanion(filePath: Value(filePath)));
  }
}

Future<void> _markPending(AppDatabase db, String uuid) async {
  await db.into(db.pendingEdits).insert(
    PendingEditsCompanion.insert(
      uuidId: uuid,
      writeMode: 'db_only',
      status: const Value('pending'),
      valuesJson: '{}',
      baseRevision: const Value(1),
      updatedAt: 1000,
    ),
  );
}

TrackUI _loadedTrack(String uuid) => TrackUI(
  uuidId: uuid,
  createdAt: 0,
  lastUpdated: 0,
  codec: 'flac',
  duration: 60,
  bitrateKbps: 900,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

ApiException _apiError(int status, Object detail) =>
    ApiException(status, jsonEncode({'detail': detail}));

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Widget harness({
    required String uuidId,
    AppInfo capabilities = _capabilities,
    required _RecordingConversionJobs jobsNotifier,
    _StubTrackSync? sync,
    bool offline = false,
    String? presetCodec,
    int? presetBitrateKbps,
    TrackUI? playing,
  }) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentTrackProvider.overrideWithValue(playing),
        trackSyncProvider.overrideWith(() => sync ?? _StubTrackSync()),
        appInfoProvider.overrideWith((ref) async => capabilities),
        conversionJobsProvider.overrideWith(() => jobsNotifier),
        offlineModeProvider.overrideWith(() => _Offline(offline)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => startConversion(
                context,
                ref,
                uuidId,
                presetCodec: presetCodec,
                presetBitrateKbps: presetBitrateKbps,
              ),
              child: const Text('Start'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pickAac192AndConfirm(WidgetTester tester) async {
    await tester.tap(find.text('AAC'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('192 kbps'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
    await tester.pumpAndSettle();
  }

  group('startConversion', () {
    testWidgets('awaits a fresh sync and enqueues the post-sync revision',
        (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 7);
      final jobs = _RecordingConversionJobs();
      final sync = _StubTrackSync(db: db, bumpUuid: 'abc', bumpRevisionTo: 8);

      await tester.pumpWidget(
        harness(uuidId: 'abc', jobsNotifier: jobs, sync: sync),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await pickAac192AndConfirm(tester);

      expect(sync.syncFreshCalls, 1);
      expect(jobs.enqueueCalls, [
        {
          'uuidId': 'abc',
          'targetCodec': 'aac',
          'targetBitrateKbps': 192,
          'baseRevision': 8,
        },
      ]);
    });

    testWidgets('a pending edit blocks the flow with a snackbar',
        (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 1);
      await _markPending(db, 'abc');
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(
        find.text("Finish syncing this track's pending edit before converting."),
        findsOneWidget,
      );
      expect(find.text('Convert to'), findsNothing);
      expect(jobs.enqueueCalls, isEmpty);
    });

    testWidgets('a failed sync aborts with a snackbar before any sheet',
        (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(
        uuidId: 'abc',
        jobsNotifier: jobs,
        sync: _StubTrackSync(result: false),
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't sync with the server. Try again."),
          findsOneWidget);
      expect(find.text('Convert to'), findsNothing);
      expect(jobs.enqueueCalls, isEmpty);
    });

    testWidgets('offline aborts without syncing', (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs();
      final sync = _StubTrackSync();

      await tester.pumpWidget(harness(
        uuidId: 'abc',
        jobsNotifier: jobs,
        sync: sync,
        offline: true,
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(sync.syncFreshCalls, 0);
      expect(jobs.enqueueCalls, isEmpty);
    });

    // Temporary guard (see _isLoadedInPlayer): the track loaded in the
    // player can't be converted.
    testWidgets('the track loaded in the player is refused before any sync',
        (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs();
      final sync = _StubTrackSync();

      await tester.pumpWidget(harness(
        uuidId: 'abc',
        jobsNotifier: jobs,
        sync: sync,
        playing: _loadedTrack('abc'),
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text(convertWhilePlayingMessage), findsOneWidget);
      expect(sync.syncFreshCalls, 0);
      expect(jobs.enqueueCalls, isEmpty);
    });

    testWidgets('a different track loaded in the player does not block',
        (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(
        uuidId: 'abc',
        jobsNotifier: jobs,
        playing: _loadedTrack('other'),
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text(convertWhilePlayingMessage), findsNothing);
      expect(find.text('Convert to'), findsOneWidget);
    });

    testWidgets('a server without the convert action aborts', (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(
        uuidId: 'abc',
        jobsNotifier: jobs,
        capabilities: AppInfo(conversion: _capabilities.conversion),
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text("This server doesn't support conversion."),
          findsOneWidget);
      expect(find.text('Convert to'), findsNothing);
    });

    testWidgets('dismissing the target sheet does not enqueue', (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 1);
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('Convert to'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Convert to'), findsNothing);
      expect(jobs.enqueueCalls, isEmpty);
    });

    testWidgets('declining the confirm sheet does not enqueue', (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 1);
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('AAC'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('192 kbps'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(jobs.enqueueCalls, isEmpty);
    });

    testWidgets(
      'the lossless source codec itself is excluded from the target list',
      (tester) async {
        await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 1);
        final jobs = _RecordingConversionJobs();

        await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
        await tester.tap(find.text('Start'));
        await tester.pumpAndSettle();

        expect(find.text('FLAC'), findsNothing);
        expect(find.text('AAC'), findsOneWidget);
      },
    );

    testWidgets('a lossless target skips the bitrate sheet and sends null',
        (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'mp3', bitrateKbps: 320, revision: 3);
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('FLAC'));
      await tester.pumpAndSettle();
      expect(find.text('Bitrate'), findsNothing);
      expect(find.text('Convert to FLAC?'), findsOneWidget);
      expect(find.text('No quality is gained'), findsOneWidget);

      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
      await tester.pumpAndSettle();

      expect(jobs.enqueueCalls.single['targetCodec'], 'flac');
      expect(jobs.enqueueCalls.single['targetBitrateKbps'], isNull);
      expect(jobs.enqueueCalls.single['baseRevision'], 3);
    });

    testWidgets('a preset target skips the target sheet (Retry path)',
        (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 2);
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(
        uuidId: 'abc',
        jobsNotifier: jobs,
        presetCodec: 'aac',
        presetBitrateKbps: 256,
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text('Convert to'), findsNothing);
      expect(find.text('Convert to AAC at 256kbps?'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
      await tester.pumpAndSettle();

      expect(jobs.enqueueCalls.single['targetBitrateKbps'], 256);
    });

    testWidgets('a preset that is no longer allowed falls back to the sheet',
        (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac');
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(
        uuidId: 'abc',
        jobsNotifier: jobs,
        presetCodec: 'flac', // now the source codec -> hard no-op
      ));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text('Convert to'), findsOneWidget);
    });

    testWidgets('409 job_active shows a readable snackbar and refreshes jobs',
        (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs(
        error: _apiError(409, {'error': 'job_active', 'job_id': 4}),
      );

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await pickAac192AndConfirm(tester);

      expect(find.text('A conversion for this track is already in progress.'),
          findsOneWidget);
      expect(find.textContaining('ApiException'), findsNothing);
      expect(jobs.refreshAllCalls, 1);
    });

    testWidgets('409 revision_conflict shows a readable snackbar',
        (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs(
        error: _apiError(
          409,
          {'error': 'revision_conflict', 'current_revision': 9},
        ),
      );

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await pickAac192AndConfirm(tester);

      expect(find.text('This track changed on the server. Try again.'),
          findsOneWidget);
      expect(find.textContaining('ApiException'), findsNothing);
    });

    testWidgets('409 pending_recovery shows the server-recovery message',
        (tester) async {
      await _insertTrack(db, uuid: 'abc');
      final jobs = _RecordingConversionJobs(
        error: _apiError(409, {'error': 'pending_recovery'}),
      );

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await pickAac192AndConfirm(tester);

      expect(
        find.text('The server is still finishing a previous change to this '
            'track. Try again later.'),
        findsOneWidget,
      );
      expect(jobs.refreshAllCalls, 0);
    });

    testWidgets(
        'a second start for the same track while one is running is ignored '
        '(double-tap guard)', (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 5);
      final jobs = _RecordingConversionJobs();
      final gate = Completer<void>();
      final sync = _StubTrackSync(gate: gate);

      await tester.pumpWidget(
        harness(uuidId: 'abc', jobsNotifier: jobs, sync: sync),
      );
      await tester.tap(find.text('Start'));
      await tester.pump();
      await tester.tap(find.text('Start')); // double-tap while syncing
      await tester.pump();
      expect(sync.syncFreshCalls, 1, reason: 'the second call returned early');

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Convert to'), findsOneWidget,
          reason: 'exactly one target sheet');
      await pickAac192AndConfirm(tester);
      expect(jobs.enqueueCalls, hasLength(1));

      // The guard is released once the flow finishes: a later start runs.
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(sync.syncFreshCalls, 2);
      expect(find.text('Convert to'), findsOneWidget);
    });

    testWidgets('a track that no longer exists is a safe no-op',
        (tester) async {
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(
        harness(uuidId: 'does-not-exist', jobsNotifier: jobs),
      );
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();

      expect(find.text('Convert to'), findsNothing);
      expect(jobs.enqueueCalls, isEmpty);
    });
  });

  group('conversionErrorMessage', () {
    test('maps each backend error to readable text', () {
      expect(
        conversionErrorMessage(_apiError(409, {'error': 'target_exists'})),
        "A file already exists at the converted file's location.",
      );
      expect(
        conversionErrorMessage(_apiError(409, {'error': 'pending_recovery'})),
        'The server is still finishing a previous change to this track. '
        'Try again later.',
      );
      expect(conversionErrorMessage(_apiError(404, 'Track not found')),
          'Track or its file was not found on the server.');
      expect(conversionErrorMessage(_apiError(507, 'disk')),
          'Not enough disk space on the server.');
      expect(conversionErrorMessage(_apiError(422, 'bitrate must be one of 320, 256')),
          "Can't convert: bitrate must be one of 320, 256");
      expect(
        conversionErrorMessage(_apiError(422, [
          {'loc': ['body'], 'msg': 'Field required', 'type': 'missing'},
        ])),
        "Can't convert: Field required",
      );
      expect(conversionErrorMessage(ApiException(500, 'Internal Server Error')),
          'Could not start the conversion.');
      expect(
        conversionErrorMessage(NetworkException('down', attemptsMade: 1)),
        "Couldn't reach the server. Try again.",
      );
    });
  });

  group('canConvertTrack', () {
    test('requires online, the convert action, and an allowed target', () {
      expect(
        canConvertTrack(isOffline: false, appInfo: _capabilities, codec: 'flac'),
        isTrue,
      );
      expect(
        canConvertTrack(isOffline: true, appInfo: _capabilities, codec: 'flac'),
        isFalse,
      );
      expect(
        canConvertTrack(
          isOffline: false,
          appInfo: AppInfo(conversion: _capabilities.conversion),
          codec: 'flac',
        ),
        isFalse,
      );
      expect(
        canConvertTrack(isOffline: false, appInfo: null, codec: 'flac'),
        isFalse,
      );
    });
  });

  group('TracksPage Convert… entry', () {
    late Directory tempDir;
    late LocalCoverArtStore coverStore;

    setUpAll(() {
      initCoverArtCache(CoverArtCacheManager.noop());
    });

    setUp(() async {
      ApiClient.init('http://localhost:8000');
      tempDir = await Directory.systemTemp.createTemp('convert-entry-test');
      coverStore = await LocalCoverArtStore.create(
        directoryProvider: () async => tempDir,
      );
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    Future<void> pumpPage(
      WidgetTester tester, {
      AppInfo capabilities = _capabilities,
      bool offline = false,
    }) async {
      // Downloaded, so the row stays interactive while offline.
      await _insertTrack(db, uuid: 'abc', codec: 'flac', filePath: '/x/abc.flac');
      final manager = DownloadManager(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          currentTrackProvider.overrideWithValue(null),
          downloadManagerProvider.overrideWithValue(manager),
          trackSyncProvider.overrideWith(() => _StubTrackSync()),
          appInfoProvider.overrideWith((ref) async => capabilities),
          conversionJobsProvider.overrideWith(_RecordingConversionJobs.new),
          offlineModeProvider.overrideWith(() => _Offline(offline)),
        ],
        child: const MaterialApp(home: Scaffold(body: TracksPage())),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
    }

    // Unmounting TracksPage cancels a drift stream subscription, which
    // schedules a zero-duration timer; flush it inside the test body so the
    // binding's pending-timer invariant passes.
    Future<void> teardownTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets('is shown when online, advertised, and a target is allowed',
        (tester) async {
      await pumpPage(tester);
      expect(find.text('Convert…'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('is hidden when offline', (tester) async {
      await pumpPage(tester, offline: true);
      expect(find.text('Play Next'), findsOneWidget, reason: 'menu is open');
      expect(find.text('Convert…'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('is hidden when the convert action is not advertised',
        (tester) async {
      await pumpPage(
        tester,
        capabilities: AppInfo(conversion: _capabilities.conversion),
      );
      expect(find.text('Play Next'), findsOneWidget, reason: 'menu is open');
      expect(find.text('Convert…'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets(
        'tapping a row\'s Convert… completes the flow through to POST /jobs, '
        'even when the row is scrolled away (unmounted) during the sync',
        (tester) async {
      final posts = <Map<String, dynamic>>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'POST' && req.url.path == '/jobs') {
            posts.add(jsonDecode(req.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'job_id': 1,
                'uuid_id': 'aaa',
                'target_codec': 'aac',
                'target_container': 'm4a',
                'target_bitrate': 192,
                'status': 'queued',
                'created_at': 1,
                'updated_at': 1,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode({'data': [], 'nextCursor': null}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      // 'aaa' sorts first (equal artist/album/disc/track; uuid tiebreak).
      await _insertTrack(db, uuid: 'aaa', title: 'Target', revision: 4);
      for (var i = 0; i < 40; i++) {
        await _insertTrack(
          db,
          uuid: 'u${i.toString().padLeft(2, '0')}',
          title: 'Other $i',
        );
      }
      final manager = DownloadManager(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
      );
      final gate = Completer<void>();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          currentTrackProvider.overrideWithValue(null),
          downloadManagerProvider.overrideWithValue(manager),
          trackSyncProvider.overrideWith(() => _StubTrackSync(gate: gate)),
          appInfoProvider.overrideWith((ref) async => _capabilities),
          // The REAL jobs notifier, so the flow ends in an actual POST.
          offlineModeProvider.overrideWith(() => _Offline(false)),
        ],
        child: const MaterialApp(home: Scaffold(body: TracksPage())),
      ));
      await tester.pumpAndSettle();

      final targetRow = find.ancestor(
        of: find.text('Target'),
        matching: find.byType(TrackTile),
      );
      await tester.tap(
        find.descendant(of: targetRow, matching: find.byIcon(Icons.more_vert)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Convert…'));
      await tester.pump(); // flow starts; syncFresh is held on the gate

      // Scroll the row far away so ListView.builder disposes it.
      await tester.drag(find.byType(ListView), const Offset(0, -2800));
      await tester.pumpAndSettle();
      expect(find.text('Target', skipOffstage: false), findsNothing,
          reason: 'the row that started the flow is unmounted');

      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('Convert to'), findsOneWidget,
          reason: 'the flow survived its row unmounting');
      await pickAac192AndConfirm(tester);

      expect(posts, [
        {
          'type': 'conversion',
          'uuid_id': 'aaa',
          'params': {'target_codec': 'aac', 'target_bitrate_kbps': 192},
          'base_revision': 4,
        },
      ]);
      await teardownTree(tester);
    });

    /// TracksPage over the REAL jobs notifier and a fake `/jobs` backend
    /// holding one running job for track 'abc'. [deleteStatus] is the
    /// DELETE's HTTP status (200 confirms the cancel).
    Future<({List<String> deletes, ProviderContainer container})>
        pumpWithRunningJob(WidgetTester tester, {int deleteStatus = 200}) async {
      var status = 'running';
      final deletes = <String>[];
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((req) async {
          if (req.method == 'DELETE') {
            deletes.add(req.url.path);
            if (deleteStatus != 200) return http.Response('boom', deleteStatus);
            status = 'cancelled';
            return http.Response(jsonEncode({'cancelled': true}), 200);
          }
          final wantsActive =
              req.url.queryParameters['status'] == activeJobStatuses;
          final job = {
            'job_id': 7,
            'uuid_id': 'abc',
            'target_codec': 'aac',
            'target_container': 'm4a',
            'target_bitrate': 192,
            'status': status,
            'created_at': 1,
            'updated_at': 1,
          };
          final isActive = status == 'queued' || status == 'running';
          return http.Response(
            jsonEncode({
              'data': [if (!wantsActive || isActive) job],
              'nextCursor': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      await _insertTrack(db, uuid: 'abc', codec: 'flac', title: 'Song');
      final manager = DownloadManager(
        db: db,
        coverArtStore: coverStore,
        directoryProvider: () async => tempDir,
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          currentTrackProvider.overrideWithValue(null),
          downloadManagerProvider.overrideWithValue(manager),
          trackSyncProvider.overrideWith(() => _StubTrackSync()),
          appInfoProvider.overrideWith((ref) async => _capabilities),
          // The REAL jobs notifier, so the menu goes through DELETE /jobs.
          offlineModeProvider.overrideWith(() => _Offline(false)),
        ],
        child: const MaterialApp(home: Scaffold(body: TracksPage())),
      ));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(TracksPage)));
      await container.read(conversionJobsProvider.notifier).refreshAll();
      await tester.pump();
      return (deletes: deletes, container: container);
    }

    Finder rowBadge() => find.descendant(
      of: find.byType(TrackTile),
      matching: find.byIcon(Icons.sync),
    );

    Future<void> tapCancelInMenu(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Convert…'), findsNothing,
          reason: 'an active job swaps Convert… for Cancel conversion');
      await tester.tap(find.text('Cancel conversion'));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'the row menu\'s Cancel conversion sends DELETE /jobs/{id} and clears '
        'the row badge', (tester) async {
      final h = await pumpWithRunningJob(tester);
      expect(rowBadge(), findsOneWidget, reason: 'running job badge');

      await tapCancelInMenu(tester);

      expect(h.deletes, ['/jobs/7']);
      expect(
        h.container.read(conversionJobsProvider).single.isCancelled,
        isTrue,
      );
      expect(rowBadge(), findsNothing);
      expect(find.text("Couldn't cancel the conversion. Try again."),
          findsNothing);

      // The poll scheduled by refreshAll fires once, finds nothing active,
      // and stops.
      await tester.pump(ConversionJobsNotifier.pollInterval);
      await teardownTree(tester);
    });

    testWidgets(
        'a failed DELETE from the row menu shows a snackbar and keeps the '
        'badge', (tester) async {
      final h = await pumpWithRunningJob(tester, deleteStatus: 404);
      expect(rowBadge(), findsOneWidget);

      await tapCancelInMenu(tester);

      expect(h.deletes, ['/jobs/7']);
      expect(find.text("Couldn't cancel the conversion. Try again."),
          findsOneWidget);
      expect(h.container.read(conversionJobsProvider).single.isRunning, isTrue);
      expect(rowBadge(), findsOneWidget);
      await teardownTree(tester); // disposing the scope stops polling
    });

    testWidgets('is hidden when no target is allowed for the codec',
        (tester) async {
      await pumpPage(
        tester,
        capabilities: const AppInfo(
          entities: _trackEntity,
          conversion: ConversionCapabilities(
            targets: [ConversionTargetInfo(codec: 'flac', isLossless: true)],
          ),
        ),
      );
      expect(find.text('Play Next'), findsOneWidget, reason: 'menu is open');
      expect(find.text('Convert…'), findsNothing);
      await teardownTree(tester);
    });
  });

  testWidgets(
    'the top bar Conversions icon navigates to ConversionsPage',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            currentTrackProvider.overrideWithValue(null),
            conversionJobsProvider.overrideWith(_RecordingConversionJobs.new),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Consumer(
                builder: (context, ref, _) => Scaffold(
                  appBar: AppBar(actions: buildTopBarActions(context, ref)),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(ConversionsPage), findsNothing);

      await tester.tap(find.byTooltip('Conversions'));
      await tester.pumpAndSettle();

      expect(find.byType(ConversionsPage), findsOneWidget);
    },
  );
}
