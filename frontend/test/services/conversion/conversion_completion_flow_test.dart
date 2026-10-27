import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';

/// End-to-end across the conversion -> sync -> stale-download seam: the REAL
/// jobs notifier polls a fake `/jobs`, a Done transition fires the REAL
/// `TrackSyncNotifier.syncFresh` (flush + `/changes` pull into the real
/// in-memory DB), and the real `StaleDownloadsBanner` reacts to the upsert.
/// Only HTTP is faked.
class _FakeServer {
  String jobStatus = 'running';
  int revision = 1;
  String codec = 'flac';
  final List<Map<String, dynamic>> changes = [];
  final List<String> deletes = [];
  int changesGets = 0;

  /// What `DELETE /jobs/{id}` does. Default: a normal confirmed cancel.
  void Function()? onDelete;

  Map<String, dynamic> get job => {
    'job_id': 1,
    'uuid_id': 'u1',
    'target_codec': 'aac',
    'target_container': 'm4a',
    'target_bitrate': 192,
    'status': jobStatus,
    'created_at': 1,
    'updated_at': 1,
  };

  bool get jobActive => jobStatus == 'queued' || jobStatus == 'running';

  /// The worker finishing: job Done, and the track's master swapped to AAC
  /// under a new revision (delivered by the next `/changes` pull).
  void completeConversion() {
    jobStatus = 'done';
    revision += 1;
    codec = 'aac';
    changes.add({
      'type': 'upsert',
      'revision': revision,
      'uuid_id': 'u1',
      'track': {
        'uuid_id': 'u1',
        'created_at': 0,
        'last_updated': 0,
        'revision': revision,
        'metadata': {
          'title': 'Song',
          'artist': 'A',
          'codec': codec,
          'duration': 1.0,
          'bitrate_kbps': 192.0,
          'sample_rate_hz': 44100,
          'channels': 2,
          'has_album_art': false,
        },
      },
    });
  }

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );

  MockClient get client => MockClient((req) async {
    final segs = req.url.pathSegments;
    if (segs.isNotEmpty && segs.first == 'changes') {
      changesGets++;
      final after = int.parse(req.url.queryParameters['after_revision'] ?? '0');
      return _json({
        'changes': [
          for (final c in changes)
            if ((c['revision'] as int) > after) c,
        ],
        'latestRevision': revision,
        'nextCursor': null,
      });
    }
    if (segs.isNotEmpty && segs.first == 'jobs') {
      if (req.method == 'DELETE') {
        deletes.add(req.url.path);
        if (onDelete != null) {
          onDelete!();
          return _json({'cancelled': false});
        }
        final active = jobActive;
        if (active) jobStatus = 'cancelled';
        return _json({'cancelled': active});
      }
      final statuses = req.url.queryParameters['status']?.split(',').toSet();
      final include = statuses == null || statuses.contains(jobStatus);
      return _json({
        'data': [if (include) job],
        'nextCursor': null,
      });
    }
    return http.Response('not found', 404);
  });
}

class _Online extends OfflineModeNotifier {
  @override
  bool build() => false;
}

class _FixedSettings extends SettingsNotifier {
  @override
  Future<AppSettings> build() async => const AppSettings(
    persistedStreamQuality: 'original',
    downloadQuality: 'original',
    notifyStaleDownloads: true,
  );
}

/// Track u1, downloaded as FLAC at its current revision (not stale yet).
Future<void> _insertDownloadedTrack(AppDatabase db) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': 'u1',
    'created_at': 0,
    'last_updated': 0,
    'revision': 1,
    'metadata': {
      'title': 'Song',
      'artist': 'A',
      'codec': 'flac',
      'duration': 1.0,
      'bitrate_kbps': 900.0,
      'sample_rate_hz': 44100,
      'channels': 2,
      'has_album_art': false,
    },
  });
  await db.into(db.tracks).insert(tracksCompanionFromDto(dto));
  await db.into(db.trackmetadata).insert(trackmetadataCompanionFromDto(dto));
  await (db.update(db.tracks)..where((t) => t.uuidId.equals('u1'))).write(
    const TracksCompanion(
      filePath: Value('/local/u1.flac'),
      downloadedAtRevision: Value(1),
      downloadedCodec: Value('flac'),
      downloadedBitrateKbps: Value(900),
      downloadedQuality: Value('original'),
      fileSizeBytes: Value(3 * 1024 * 1024),
    ),
  );
}

void main() {
  const interval = Duration(seconds: 1);
  final bannerText = find.textContaining('changed on the server since');

  late AppDatabase db;
  late _FakeServer server;

  setUp(() async {
    ConversionJobsNotifier.pollInterval = interval;
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    server = _FakeServer();
    ApiClient.initForTest('http://test:8080', server.client);
    await _insertDownloadedTrack(db);
  });

  tearDown(() async {
    ConversionJobsNotifier.pollInterval = const Duration(seconds: 3);
    await db.close();
  });

  /// Pumps the banner over real providers and has the jobs notifier discover
  /// the running job. Returns the scope's container plus every state the
  /// jobs provider published from then on.
  Future<({ProviderContainer container, List<List<ConversionJob>> history})>
  pumpHarness(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          offlineModeProvider.overrideWith(_Online.new),
          settingsProvider.overrideWith(_FixedSettings.new),
        ],
        child: const MaterialApp(home: Scaffold(body: StaleDownloadsBanner())),
      ),
    );
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StaleDownloadsBanner)),
    );
    final history = <List<ConversionJob>>[];
    container.listen(
      conversionJobsProvider,
      (_, next) => history.add(next),
      fireImmediately: true,
    );
    await container.read(conversionJobsProvider.notifier).refreshAll();
    await tester.pump();
    return (container: container, history: history);
  }

  /// Lets the unawaited post-conversion sync (several DB + HTTP hops) and
  /// the Drift watch re-emission finish, then settles the UI.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets(
      'a running conversion finishing -> poll sees Done -> fresh sync pulls '
      'the new revision -> the stale banner appears', (tester) async {
    final h = await pumpHarness(tester);
    final jobs = h.container.read(conversionJobsProvider);
    expect(jobs.single.isRunning, isTrue);
    expect(bannerText, findsNothing);
    expect(server.changesGets, 0, reason: 'no sync while the job is running');

    // Still running at the next poll: nothing happens.
    await tester.pump(interval);
    await settle(tester);
    expect(server.changesGets, 0);
    expect(bannerText, findsNothing);

    server.completeConversion();
    await tester.pump(interval); // the poll that sees Done
    await settle(tester);

    expect(h.container.read(conversionJobsProvider).single.isDone, isTrue);
    expect(server.changesGets, 1, reason: 'exactly one fresh sync fired');
    final row = await (db.select(db.tracks)
          ..where((t) => t.uuidId.equals('u1')))
        .getSingle();
    expect(row.revision, 2, reason: 'the /changes upsert landed');
    expect(row.downloadedAtRevision, 1);
    expect(bannerText, findsOneWidget);
    expect(find.textContaining('1 downloaded track'), findsOneWidget);

    // Nothing active any more: polling has stopped.
    await tester.pump(interval * 5);
    expect(server.changesGets, 1);
    await unmount(tester);
  });

  testWidgets(
      'a cancel that loses to completion (cancelled: false) settles as Done on '
      'the next poll and syncs; Cancelled is never shown', (tester) async {
    final h = await pumpHarness(tester);
    expect(h.container.read(conversionJobsProvider).single.isRunning, isTrue);

    // The worker finishes just before the DELETE lands.
    server.onDelete = server.completeConversion;
    await h.container.read(conversionJobsProvider.notifier).cancel(1);
    await tester.pump();

    expect(server.deletes, ['/jobs/1']);
    expect(h.container.read(conversionJobsProvider).single.isRunning, isTrue,
        reason: 'cancelled:false leaves the local job for the poll to settle');
    expect(server.changesGets, 0);

    await tester.pump(interval);
    await settle(tester);

    expect(h.container.read(conversionJobsProvider).single.isDone, isTrue);
    expect(server.changesGets, 1, reason: 'the Done transition synced');
    expect(bannerText, findsOneWidget);
    expect(
      h.history.expand((s) => s).where((j) => j.isCancelled),
      isEmpty,
      reason: 'the provider never published a Cancelled job',
    );

    await tester.pump(interval * 5);
    await unmount(tester);
  });
}
