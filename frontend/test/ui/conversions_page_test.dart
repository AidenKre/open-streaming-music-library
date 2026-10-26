import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/audio/audio_providers.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/ui/conversions_page.dart';

class _FixedConversionJobs extends ConversionJobsNotifier {
  _FixedConversionJobs(this._jobs, {this.enqueueError});
  final List<ConversionJob> _jobs;
  final Object? enqueueError;
  int cancelCalls = 0;
  final List<Map<String, dynamic>> enqueueCalls = [];

  @override
  List<ConversionJob> build() => _jobs;

  void setJobs(List<ConversionJob> jobs) => state = jobs;

  @override
  Future<void> cancel(int jobId) async {
    cancelCalls++;
  }

  @override
  Future<void> refreshAll() async {}

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
    if (enqueueError != null) throw enqueueError!;
    return ConversionJob(
      jobId: 99,
      uuidId: uuidId,
      targetCodec: targetCodec,
      targetContainer: 'm4a',
      status: const ConversionQueued(),
    );
  }
}

/// Fresh-sync stub; [gate] (when set) holds the sync open so a test can
/// observe the in-flight state.
class _StubSync extends TrackSyncNotifier {
  Completer<void>? gate;
  int calls = 0;

  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {}

  @override
  Future<bool> syncFresh() async {
    calls++;
    await gate?.future;
    return true;
  }
}

class _Online extends OfflineModeNotifier {
  @override
  bool build() => false;
}

const _capabilities = AppInfo(
  entities: {'track': EntityInfo(actions: ['convert'])},
  conversion: ConversionCapabilities(
    targets: [
      ConversionTargetInfo(codec: 'aac', isLossless: false),
      ConversionTargetInfo(codec: 'mp3', isLossless: false),
      ConversionTargetInfo(codec: 'flac', isLossless: true),
    ],
    bitratePresets: [320, 256, 192, 128],
  ),
);

ConversionJob _job({
  int jobId = 1,
  String uuidId = 'abc',
  String targetCodec = 'aac',
  int? targetBitrate = 192,
  String status = 'queued',
  String? errorText,
}) => ConversionJob.fromJson({
  'job_id': jobId,
  'uuid_id': uuidId,
  'target_codec': targetCodec,
  'target_container': 'm4a',
  'target_bitrate': targetBitrate,
  'status': status,
  'error_text': errorText,
  'created_at': 1000,
  'updated_at': 1000,
});

Future<void> _insertTrack(
  AppDatabase db,
  String uuid, {
  String title = 'T',
  int revision = 1,
}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 1000,
    'last_updated': 1000,
    'revision': revision,
    'metadata': {
      'title': title,
      'artist': 'A',
      'codec': 'flac',
      'duration': 1.0,
      'bitrate_kbps': 1000.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  });
  await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
  await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
}

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  // Job rows watch their track through a drift stream; unmounting the tree
  // schedules drift's stream-close timer, so every test flushes it before
  // the binding's pending-timer check.
  void testPage(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      await body(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    });
  }

  Widget wrap(
    List<ConversionJob> jobs, {
    _FixedConversionJobs? notifier,
    _StubSync? sync,
  }) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        currentTrackProvider.overrideWithValue(null),
        conversionJobsProvider.overrideWith(
          () => notifier ?? _FixedConversionJobs(jobs),
        ),
        trackSyncProvider.overrideWith(() => sync ?? _StubSync()),
        appInfoProvider.overrideWith((ref) async => _capabilities),
        offlineModeProvider.overrideWith(_Online.new),
      ],
      child: const MaterialApp(home: ConversionsPage()),
    );
  }

  testPage('shows an empty state with no jobs', (tester) async {
    await tester.pumpWidget(wrap(const []));
    await tester.pumpAndSettle();

    expect(find.text('No conversions yet.'), findsOneWidget);
  });

  testPage('shows Active and Finished sections', (tester) async {
    await _insertTrack(db, 'abc');
    await _insertTrack(db, 'def');
    await tester.pumpWidget(wrap([
      _job(jobId: 1, uuidId: 'abc', status: 'running'),
      _job(jobId: 2, uuidId: 'def', status: 'done'),
    ]));
    // Not pumpAndSettle: a running job's indeterminate progress indicator
    // animates forever, so settling never completes.
    await tester.pump();
    await tester.pump();

    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
  });

  testPage('queued job shows a cancel button that calls cancel', (tester) async {
    await _insertTrack(db, 'abc');
    final notifier = _FixedConversionJobs([_job(status: 'queued')]);
    await tester.pumpWidget(wrap([], notifier: notifier));
    await tester.pumpAndSettle();

    final cancelButton = find.byTooltip('Cancel');
    expect(cancelButton, findsOneWidget);
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(notifier.cancelCalls, 1);
  });

  testPage('running job shows an indeterminate progress indicator', (tester) async {
    await _insertTrack(db, 'abc');
    await tester.pumpWidget(wrap([_job(status: 'running')]));
    await tester.pump();
    await tester.pump();

    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, isNull);
  });

  testPage('running job also shows a cancel button', (tester) async {
    await _insertTrack(db, 'abc');
    final notifier = _FixedConversionJobs([_job(status: 'running')]);
    await tester.pumpWidget(wrap([], notifier: notifier));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    expect(notifier.cancelCalls, 1);
  });

  testPage('done job shows a check icon, no cancel button', (tester) async {
    await _insertTrack(db, 'abc');
    await tester.pumpWidget(wrap([_job(status: 'done')]));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsNothing);
  });

  testPage('failed job shows its error text and an error-icon Retry',
      (tester) async {
    await _insertTrack(db, 'abc');
    await tester.pumpWidget(wrap([
      _job(status: 'failed', errorText: 'track changed since the conversion '
          'was requested'),
    ]));
    await tester.pumpAndSettle();

    expect(
      find.text('Failed: track changed since the conversion was requested'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byTooltip('Retry'), findsOneWidget);
  });

  testPage('Retry opens the confirm sheet preselected, then posts the '
      'same target at the fresh revision', (tester) async {
    await _insertTrack(db, 'abc', revision: 5);
    final notifier = _FixedConversionJobs([
      _job(status: 'failed', targetCodec: 'mp3', targetBitrate: 256,
          errorText: 'boom'),
    ]);
    await tester.pumpWidget(wrap([], notifier: notifier));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();

    // No target picker: straight to the irreversible confirm.
    expect(find.text('Convert to'), findsNothing);
    expect(find.text('Convert to MP3 at 256kbps?'), findsOneWidget);
    expect(notifier.enqueueCalls, isEmpty, reason: 'nothing before confirm');

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
    await tester.pumpAndSettle();

    expect(notifier.enqueueCalls, [
      {
        'uuidId': 'abc',
        'targetCodec': 'mp3',
        'targetBitrateKbps': 256,
        'baseRevision': 5,
      },
    ]);
  });

  testPage('Retry surfaces an enqueue error as a readable snackbar',
      (tester) async {
    await _insertTrack(db, 'abc');
    final notifier = _FixedConversionJobs(
      [_job(status: 'failed', errorText: 'boom')],
      enqueueError: ApiException(507, jsonEncode({'detail': 'disk full'})),
    );
    await tester.pumpWidget(wrap([], notifier: notifier));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
    await tester.pumpAndSettle();

    expect(notifier.enqueueCalls, hasLength(1));
    expect(find.text('Not enough disk space on the server.'), findsOneWidget);
    expect(find.textContaining('ApiException'), findsNothing);
    // Re-enabled once the flow finished.
    final retry = tester.widget<IconButton>(
      find.ancestor(of: find.byIcon(Icons.error_outline), matching: find.byType(IconButton)),
    );
    expect(retry.onPressed, isNotNull);
  });

  testPage('Retry is disabled while its flow is in flight (no double submit)',
      (tester) async {
    await _insertTrack(db, 'abc');
    final notifier = _FixedConversionJobs([
      _job(status: 'failed', errorText: 'boom'),
    ]);
    final sync = _StubSync()..gate = Completer<void>();
    await tester.pumpWidget(wrap([], notifier: notifier, sync: sync));
    await tester.pumpAndSettle();

    IconButton retryButton() => tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.error_outline),
        matching: find.byType(IconButton),
      ),
    );

    await tester.tap(find.byTooltip('Retry'));
    await tester.pump();
    expect(retryButton().onPressed, isNull);
    await tester.tap(find.byTooltip('Retry'), warnIfMissed: false);
    await tester.pump();
    expect(sync.calls, 1, reason: 'second tap did not start a second flow');

    sync.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Convert to AAC at 192kbps?'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
    await tester.pumpAndSettle();

    expect(notifier.enqueueCalls, hasLength(1));
  });

  testPage('cancelled job shows a cancelled icon, no action', (tester) async {
    await _insertTrack(db, 'abc');
    await tester.pumpWidget(wrap([_job(status: 'cancelled')]));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
  });

  testPage('shows the track title resolved from the local database',
      (tester) async {
    await _insertTrack(db, 'abc', title: 'My Favorite Song');
    await tester.pumpWidget(wrap([_job(uuidId: 'abc', status: 'done')]));
    await tester.pumpAndSettle();

    expect(find.text('My Favorite Song'), findsOneWidget);
  });

  testPage('a not-yet-synced track\'s title appears once a pull lands it',
      (tester) async {
    await tester.pumpWidget(wrap([_job(uuidId: 'later', status: 'done')]));
    await tester.pumpAndSettle();
    expect(find.text('later'), findsOneWidget, reason: 'uuid until synced');

    await _insertTrack(db, 'later', title: 'Arrived Later');
    await tester.pumpAndSettle();
    expect(find.text('Arrived Later'), findsOneWidget);
    expect(find.text('later'), findsNothing);

    // A later rename (another /changes upsert) is reflected too.
    await (db.update(db.trackmetadata)
          ..where((t) => t.uuidId.equals('later')))
        .write(const TrackmetadataCompanion(title: Value('Renamed')));
    await tester.pumpAndSettle();
    expect(find.text('Renamed'), findsOneWidget);
  });

  testPage(
      'Retry keeps its flow when its row is scrolled away (unmounted) during '
      'the sync', (tester) async {
    await _insertTrack(db, 'abc', revision: 3);
    final notifier = _FixedConversionJobs([
      _job(jobId: 1, status: 'failed', errorText: 'boom'),
      for (var i = 2; i < 40; i++)
        _job(jobId: i, uuidId: 'other$i', status: 'done'),
    ]);
    final sync = _StubSync()..gate = Completer<void>();
    await tester.pumpWidget(wrap([], notifier: notifier, sync: sync));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Retry'));
    await tester.pump();
    expect(sync.calls, 1);

    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Retry', skipOffstage: false), findsNothing,
        reason: 'the failed row (and its state) is disposed');

    sync.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Convert to AAC at 192kbps?'), findsOneWidget,
        reason: 'the flow continued on the page context');
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
    await tester.pumpAndSettle();

    expect(notifier.enqueueCalls, [
      {
        'uuidId': 'abc',
        'targetCodec': 'aac',
        'targetBitrateKbps': 192,
        'baseRevision': 3,
      },
    ]);
  });

  testPage(
      'a row\'s in-flight Retry state stays with its job when the list '
      'reorders', (tester) async {
    await _insertTrack(db, 'abc');
    await _insertTrack(db, 'def');
    final jobA = _job(jobId: 1, uuidId: 'abc', status: 'failed', errorText: 'a');
    final notifier = _FixedConversionJobs([jobA]);
    final sync = _StubSync()..gate = Completer<void>();
    await tester.pumpWidget(wrap([], notifier: notifier, sync: sync));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Retry'));
    await tester.pump();

    // A newer failed job for another track lands ABOVE job A.
    final jobB = _job(jobId: 2, uuidId: 'def', status: 'failed', errorText: 'b');
    notifier.setJobs([jobB, jobA]);
    await tester.pump();

    IconButton retryFor(String error) => tester.widget<IconButton>(
      find.descendant(
        of: find.ancestor(
          of: find.text('Failed: $error'),
          matching: find.byType(ListTile),
        ),
        matching: find.byType(IconButton),
      ),
    );
    expect(retryFor('a').onPressed, isNull, reason: 'A is still retrying');
    expect(retryFor('b').onPressed, isNotNull,
        reason: "B must not inherit A's in-flight flag");

    sync.gate!.complete();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(retryFor('a').onPressed, isNotNull);
  });
}
