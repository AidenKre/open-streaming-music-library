import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/ui/tracks_page.dart';

class _StubTrackSync extends TrackSyncNotifier {
  int syncCalls = 0;

  @override
  Future<TrackSyncState> build() async => const TrackSyncState();

  @override
  Future<void> sync() async {
    syncCalls++;
  }
}

class _RecordingConversionJobs extends ConversionJobsNotifier {
  final List<Map<String, dynamic>> enqueueCalls = [];

  @override
  List<ConversionJob> build() => const [];

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
    return ConversionJob(
      jobId: 1,
      uuidId: uuidId,
      targetCodec: targetCodec,
      targetContainer: 'm4a',
      status: const ConversionQueued(),
    );
  }
}

const _capabilities = AppInfo(
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
  int revision = 1,
}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 1000,
    'last_updated': 1000,
    'revision': revision,
    'metadata': {
      'title': 'T',
      'artist': 'A',
      'codec': codec,
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
  }) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        trackSyncProvider.overrideWith(_StubTrackSync.new),
        appInfoProvider.overrideWith((ref) async => capabilities),
        conversionJobsProvider.overrideWith(() => jobsNotifier),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => ElevatedButton(
              onPressed: () => startConversion(context, ref, uuidId),
              child: const Text('Convert'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'picking a codec and confirming enqueues with the fresh revision',
    (tester) async {
      await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 7);
      final jobs = _RecordingConversionJobs();

      await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
      await tester.tap(find.text('Convert'));
      await tester.pumpAndSettle();

      // Target sheet: pick AAC (lossy) -> bitrate sheet appears.
      await tester.tap(find.text('AAC'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('192 kbps'));
      await tester.pumpAndSettle();

      // Confirm sheet: check the box, then confirm.
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Convert'));
      await tester.pumpAndSettle();

      expect(jobs.enqueueCalls, [
        {
          'uuidId': 'abc',
          'targetCodec': 'aac',
          'targetBitrateKbps': 192,
          'baseRevision': 7,
        },
      ]);
    },
  );

  testWidgets('a pending edit blocks the flow before any sheet opens',
      (tester) async {
    await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 1);
    await _markPending(db, 'abc');
    final jobs = _RecordingConversionJobs();

    await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();

    expect(find.text('Convert to'), findsNothing);
    expect(jobs.enqueueCalls, isEmpty);
  });

  testWidgets('dismissing the target sheet does not enqueue', (tester) async {
    await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 1);
    final jobs = _RecordingConversionJobs();

    await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(jobs.enqueueCalls, isEmpty);
  });

  testWidgets('declining the confirm sheet does not enqueue', (tester) async {
    await _insertTrack(db, uuid: 'abc', codec: 'flac', revision: 1);
    final jobs = _RecordingConversionJobs();

    await tester.pumpWidget(harness(uuidId: 'abc', jobsNotifier: jobs));
    await tester.tap(find.text('Convert'));
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
      await tester.tap(find.text('Convert'));
      await tester.pumpAndSettle();

      expect(find.text('FLAC'), findsNothing);
      expect(find.text('AAC'), findsOneWidget);
    },
  );

  testWidgets('a track that no longer exists is a safe no-op', (tester) async {
    final jobs = _RecordingConversionJobs();

    await tester.pumpWidget(harness(uuidId: 'does-not-exist', jobsNotifier: jobs));
    await tester.tap(find.text('Convert'));
    await tester.pumpAndSettle();

    expect(jobs.enqueueCalls, isEmpty);
  });
}
