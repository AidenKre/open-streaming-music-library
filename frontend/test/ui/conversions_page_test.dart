import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/ui/conversions_page.dart';

class _FixedConversionJobs extends ConversionJobsNotifier {
  _FixedConversionJobs(this._jobs);
  final List<ConversionJob> _jobs;
  int cancelCalls = 0;
  int enqueueCalls = 0;

  @override
  List<ConversionJob> build() => _jobs;

  @override
  Future<void> cancel(int jobId) async {
    cancelCalls++;
  }

  @override
  Future<ConversionJob> enqueue({
    required String uuidId,
    required String targetCodec,
    required int? targetBitrateKbps,
    required int? baseRevision,
  }) async {
    enqueueCalls++;
    return ConversionJob(
      jobId: 99,
      uuidId: uuidId,
      targetCodec: targetCodec,
      targetContainer: 'm4a',
      status: const ConversionQueued(),
    );
  }
}

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

Future<void> _insertTrack(AppDatabase db, String uuid, {String title = 'T'}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 1000,
    'last_updated': 1000,
    'revision': 1,
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

  Widget wrap(List<ConversionJob> jobs, {_FixedConversionJobs? notifier}) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        conversionJobsProvider.overrideWith(
          () => notifier ?? _FixedConversionJobs(jobs),
        ),
      ],
      child: const MaterialApp(home: ConversionsPage()),
    );
  }

  testWidgets('shows an empty state with no jobs', (tester) async {
    await tester.pumpWidget(wrap(const []));
    await tester.pumpAndSettle();

    expect(find.text('No conversions yet.'), findsOneWidget);
  });

  testWidgets('shows Active and Finished sections', (tester) async {
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

  testWidgets('queued job shows a cancel button that calls cancel', (tester) async {
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

  testWidgets('running job shows an indeterminate progress indicator', (tester) async {
    await _insertTrack(db, 'abc');
    await tester.pumpWidget(wrap([_job(status: 'running')]));
    await tester.pump();
    await tester.pump();

    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, isNull);
  });

  testWidgets('running job also shows a cancel button', (tester) async {
    await _insertTrack(db, 'abc');
    final notifier = _FixedConversionJobs([_job(status: 'running')]);
    await tester.pumpWidget(wrap([], notifier: notifier));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    expect(notifier.cancelCalls, 1);
  });

  testWidgets('done job shows a check icon, no cancel button', (tester) async {
    await _insertTrack(db, 'abc');
    await tester.pumpWidget(wrap([_job(status: 'done')]));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsNothing);
  });

  testWidgets('failed job shows an error icon and a retry button that re-enqueues',
      (tester) async {
    await _insertTrack(db, 'abc');
    final notifier = _FixedConversionJobs([
      _job(status: 'failed', errorText: 'boom'),
    ]);
    await tester.pumpWidget(wrap([], notifier: notifier));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    final retryButton = find.byTooltip('Retry');
    expect(retryButton, findsOneWidget);

    await tester.tap(retryButton);
    await tester.pumpAndSettle();

    expect(notifier.enqueueCalls, 1);
  });

  testWidgets('cancelled job shows a cancelled icon, no action', (tester) async {
    await _insertTrack(db, 'abc');
    await tester.pumpWidget(wrap([_job(status: 'cancelled')]));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
  });

  testWidgets('shows the track title resolved from the local database',
      (tester) async {
    await _insertTrack(db, 'abc', title: 'My Favorite Song');
    await tester.pumpWidget(wrap([_job(uuidId: 'abc', status: 'done')]));
    await tester.pumpAndSettle();

    expect(find.text('My Favorite Song'), findsOneWidget);
  });
}
