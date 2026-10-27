import 'dart:io';

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
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_cover_art_store.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/widgets/stale_downloads_banner.dart';

Future<void> _insertTrack(
  AppDatabase db, {
  required String uuid,
  required int revision,
  int? downloadedAtRevision,
  String codec = 'aac',
  String? downloadedCodec,
  double bitrateKbps = 192.0,
  int? downloadedBitrateKbps,
  String title = 'My Track',
  String downloadedQuality = '192',
  String? filePath,
  int? fileSizeBytes,
}) async {
  final dto = ClientTrackDto.fromJson({
    'uuid_id': uuid,
    'created_at': 0,
    'last_updated': 0,
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
  await (db.update(db.tracks)..where((t) => t.uuidId.equals(uuid))).write(
    TracksCompanion(
      filePath: Value(filePath ?? '/local/$uuid.audio'),
      downloadedAtRevision: Value(downloadedAtRevision),
      downloadedCodec: Value(downloadedCodec),
      downloadedBitrateKbps: Value(downloadedBitrateKbps),
      downloadedQuality: Value(downloadedQuality),
      fileSizeBytes: Value(fileSizeBytes),
    ),
  );
}

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late LocalCoverArtStore coverStore;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('stale-banner-test');
    ApiClient.initForTest(
      'http://test:8080',
      MockClient((_) async => http.Response.bytes([1], 200)),
    );
    coverStore = await LocalCoverArtStore.create(
      directoryProvider: () async => tempDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  late DownloadManager manager;

  Widget wrap({
    bool notify = true,
    String downloadQuality = '320',
    Set<String> failingQualities = const {},
  }) {
    manager = _FlakyDownloadManager(
      failingQualities,
      db: db,
      coverArtStore: coverStore,
      directoryProvider: () async => tempDir,
      // Offline: enqueued jobs stay queued, so a test can observe the queue
      // (and the "Re-downloading..." state) without real downloads running.
      isOfflineFn: () => true,
    );
    addTearDown(manager.dispose);
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        downloadManagerProvider.overrideWithValue(manager),
        settingsProvider.overrideWith(
          () => _FixedSettings(notify, downloadQuality),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: StaleDownloadsBanner())),
    );
  }

  // Unmounts the tree, then flushes drift's stream-close timers (scheduled
  // during ProviderScope disposal) so flutter_test's pending-timer invariant
  // passes -- same pattern used by pending_edits_banner_test.dart for the
  // same reason (both watch a Drift-backed StreamProvider).
  Future<void> flushDispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('Review'));
    await tester.pump(); // start the sheet route
    await tester.pump(const Duration(seconds: 1)); // finish its animation
  }

  /// Lets an action that awaits real file I/O (the re-download path checks
  /// whether the stale file exists) finish, then settles the UI.
  Future<void> settleRealIo(WidgetTester tester) async {
    // Each real I/O hop needs a real event-loop turn, then a pump to flush
    // the fake-zone microtasks it scheduled; the path has a few such hops.
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }

  final bannerText = find.textContaining('changed on the server since');

  /// A real on-disk "stale" file, so the re-download goes down the two-phase
  /// replacement path (which only triggers when the file exists) and `force`
  /// actually matters (an existing file at the same quality is otherwise
  /// skipped).
  String realFile(String uuid) {
    final f = File('${tempDir.path}/$uuid-stale.audio')
      ..writeAsBytesSync([1, 2, 3]);
    return f.path;
  }

  testWidgets('hidden when there are no stale downloads', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pump(); // first stream emission

    expect(find.byType(StaleDownloadsBanner), findsOneWidget);
    expect(bannerText, findsNothing);

    await flushDispose(tester);
  });

  testWidgets('shows an honest count when a download is stale',
      (tester) async {
    await _insertTrack(db, uuid: 'abc', revision: 6, downloadedAtRevision: 5);

    await tester.pumpWidget(wrap());
    await tester.pump();

    expect(
      find.text(
        '1 downloaded track changed on the server since you downloaded it '
        '(audio, tags, or artwork).',
      ),
      findsOneWidget,
    );

    await flushDispose(tester);
  });

  testWidgets(
    'hidden when notifyStaleDownloads is false, even with stale downloads',
    (tester) async {
      await _insertTrack(db, uuid: 'abc', revision: 6, downloadedAtRevision: 5);

      await tester.pumpWidget(wrap(notify: false));
      await tester.pump();

      expect(bannerText, findsNothing);

      await flushDispose(tester);
    },
  );

  testWidgets('turning the pref off while the banner is visible hides it',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _insertTrack(db, uuid: 'abc', revision: 6, downloadedAtRevision: 5);

    await tester.pumpWidget(wrap());
    await tester.pump();
    expect(bannerText, findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(StaleDownloadsBanner)),
    );
    await container
        .read(settingsProvider.notifier)
        .setNotifyStaleDownloads(false);
    await tester.pump();

    expect(bannerText, findsNothing);

    await flushDispose(tester);
  });

  testWidgets('the sheet shows the exact diff, rounding the master bitrate',
      (tester) async {
    await _insertTrack(
      db,
      uuid: 'abc',
      revision: 6,
      downloadedAtRevision: 5,
      codec: 'aac',
      downloadedCodec: 'flac',
      bitrateKbps: 191.6,
      downloadedBitrateKbps: 1000,
      fileSizeBytes: 5 * 1024 * 1024,
      title: 'My Favorite Song',
    );

    await tester.pumpWidget(wrap());
    await tester.pump();
    await openSheet(tester);

    expect(find.text('My Favorite Song'), findsOneWidget);
    expect(
      find.text(
        'Your download: flac, 1000 kbps, 5.0 MB  →  Server: aac, 192 kbps',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Re-download'), findsOneWidget);
    expect(find.byTooltip('Dismiss'), findsOneWidget);

    await flushDispose(tester);
  });

  testWidgets(
    'same codec + the server\'s truncated bitrate header reads as '
    '"Audio unchanged"',
    (tester) async {
      // The server sends X-Audio-Bitrate-Kbps as int(bitrate) -- truncated --
      // so a 899.7 kbps master downloads as 899 (while 899.7 rounds to 900).
      await _insertTrack(
        db,
        uuid: 'abc',
        revision: 6,
        downloadedAtRevision: 5,
        codec: 'flac',
        downloadedCodec: 'flac',
        bitrateKbps: 899.7,
        downloadedBitrateKbps: 899,
        fileSizeBytes: 30 * 1024 * 1024,
      );

      await tester.pumpWidget(wrap());
      await tester.pump();
      await openSheet(tester);

      expect(
        find.text('Audio unchanged — tags or artwork updated'),
        findsOneWidget,
      );
      expect(find.textContaining('kbps'), findsNothing);
      expect(find.textContaining('MB'), findsNothing,
          reason: 'the short-circuit wins even with a known file size');

      await flushDispose(tester);
    },
  );

  testWidgets('the diff omits the size when the download has no file size',
      (tester) async {
    await _insertTrack(
      db,
      uuid: 'abc',
      revision: 6,
      downloadedAtRevision: 5,
      codec: 'aac',
      downloadedCodec: 'flac',
      bitrateKbps: 192.0,
      downloadedBitrateKbps: 1000,
    );

    await tester.pumpWidget(wrap());
    await tester.pump();
    await openSheet(tester);

    expect(
      find.text('Your download: flac, 1000 kbps  →  Server: aac, 192 kbps'),
      findsOneWidget,
    );

    await flushDispose(tester);
  });

  group('staleDownloadDiffLabel', () {
    TrackUI track({
      String? downloadedCodec,
      int? downloadedBitrateKbps,
      int? fileSizeBytes,
      String codec = 'aac',
      double? bitrateKbps = 192,
    }) => TrackUI(
      uuidId: 'x',
      createdAt: 0,
      lastUpdated: 0,
      codec: codec,
      duration: 1,
      bitrateKbps: bitrateKbps,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
      downloadedCodec: downloadedCodec,
      downloadedBitrateKbps: downloadedBitrateKbps,
      fileSizeBytes: fileSizeBytes,
    );

    test('includes each known downloaded field, skipping unknown ones', () {
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'flac',
          downloadedBitrateKbps: 1000,
          fileSizeBytes: 1536 * 1024,
        )),
        'Your download: flac, 1000 kbps, 1.5 MB  →  Server: aac, 192 kbps',
      );
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'flac',
          fileSizeBytes: 512 * 1024,
        )),
        'Your download: flac, 512.0 KB  →  Server: aac, 192 kbps',
      );
      expect(
        staleDownloadDiffLabel(track()),
        'Your download: ?  →  Server: aac, 192 kbps',
      );
    });

    test('an unknown (null) bitrate is omitted; a real 0 is shown', () {
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'mp3',
          downloadedBitrateKbps: 320,
          codec: 'flac',
          bitrateKbps: null,
        )),
        'Your download: mp3, 320 kbps  →  Server: flac',
      );
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'flac',
          downloadedBitrateKbps: 0,
          fileSizeBytes: 1536 * 1024,
        )),
        'Your download: flac, 0 kbps, 1.5 MB  →  Server: aac, 192 kbps',
      );
    });

    test('same lossless codec is "audio unchanged" even with unknown bitrates',
        () {
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'flac',
          codec: 'flac',
          bitrateKbps: null,
        )),
        'Audio unchanged — tags or artwork updated',
      );
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'flac',
          codec: 'flac',
          bitrateKbps: 912.4,
        )),
        'Audio unchanged — tags or artwork updated',
      );
    });

    test('same lossy codec needs matching bitrates to be "audio unchanged"', () {
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'aac',
          downloadedBitrateKbps: 191,
          bitrateKbps: 191.8,
        )),
        'Audio unchanged — tags or artwork updated',
      );
      expect(
        staleDownloadDiffLabel(track(
          downloadedCodec: 'aac',
          downloadedBitrateKbps: 256,
        )),
        'Your download: aac, 256 kbps  →  Server: aac, 192 kbps',
      );
      // Unknown lossy bitrate: can't claim the audio is unchanged.
      expect(
        staleDownloadDiffLabel(track(downloadedCodec: 'aac')),
        'Your download: aac  →  Server: aac, 192 kbps',
      );
    });
  });

  testWidgets('dismissing the last stale track removes its row and the banner',
      (tester) async {
    await _insertTrack(
      db,
      uuid: 'abc',
      revision: 6,
      downloadedAtRevision: 5,
      title: 'Only One',
    );

    await tester.pumpWidget(wrap());
    await tester.pump();
    await openSheet(tester);
    expect(find.text('Only One'), findsOneWidget);

    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump(const Duration(seconds: 1));

    final row = await (db.select(
      db.tracks,
    )..where((t) => t.uuidId.equals('abc'))).getSingle();
    expect(row.staleDismissedAtRevision, 6);
    expect(find.text('Only One'), findsNothing);
    expect(find.text('Nothing to review'), findsOneWidget);
    expect(bannerText, findsNothing);

    await flushDispose(tester);
  });

  testWidgets(
    'Re-download queues a forced replacement at the stored quality and then '
    'shows Re-downloading...',
    (tester) async {
      final stalePath = realFile('abc');
      await _insertTrack(
        db,
        uuid: 'abc',
        revision: 6,
        downloadedAtRevision: 5,
        filePath: stalePath,
      );

      await tester.pumpWidget(wrap(downloadQuality: 'original'));
      await tester.pump();
      await openSheet(tester);

      await tester.tap(find.byTooltip('Re-download'));
      await settleRealIo(tester);

      final job = manager.snapshot().single;
      expect(job.uuidId, 'abc');
      expect(job.quality, '192', reason: 'the stored downloadedQuality');
      expect(job.isQueued, isTrue);
      expect(job.replacesFilePath, stalePath,
          reason: 'forced two-phase replacement of the existing same-quality '
              'file (without force it would be skipped as already downloaded)');
      expect(find.text('Re-download queued'), findsOneWidget);
      expect(find.text('Re-downloading…'), findsOneWidget);
      expect(find.byTooltip('Re-download'), findsNothing,
          reason: 'no second Re-download while one is pending');

      await flushDispose(tester);
    },
  );

  testWidgets(
    'Re-download falls back to the current download-quality setting when '
    'the stored quality is no longer a valid preset',
    (tester) async {
      await _insertTrack(
        db,
        uuid: 'abc',
        revision: 6,
        downloadedAtRevision: 5,
        downloadedQuality: 'not-a-preset',
      );

      await tester.pumpWidget(wrap(downloadQuality: '320'));
      await tester.pump();
      await openSheet(tester);

      await tester.tap(find.byTooltip('Re-download'));
      await settleRealIo(tester);

      expect(manager.snapshot().single.quality, '320');
      expect(find.text('Re-download queued'), findsOneWidget);

      await flushDispose(tester);
    },
  );

  testWidgets('many stale rows render without overflow and scroll',
      (tester) async {
    for (var i = 0; i < 15; i++) {
      await _insertTrack(
        db,
        uuid: 'u${i.toString().padLeft(2, '0')}',
        revision: 6,
        downloadedAtRevision: 5,
        title: 'Track ${i.toString().padLeft(2, '0')}',
      );
    }

    await tester.pumpWidget(wrap());
    await tester.pump();
    await openSheet(tester);

    expect(tester.takeException(), isNull);
    final lastRow = find.text('Track 14');
    await tester.scrollUntilVisible(
      lastRow,
      200,
      scrollable: find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(lastRow.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await flushDispose(tester);
  });

  testWidgets('Re-download all queues every stale track', (tester) async {
    final pathA = realFile('a');
    final pathB = realFile('b');
    await _insertTrack(
      db,
      uuid: 'a',
      revision: 6,
      downloadedAtRevision: 5,
      filePath: pathA,
    );
    await _insertTrack(
      db,
      uuid: 'b',
      revision: 6,
      downloadedAtRevision: 5,
      downloadedQuality: 'original',
      filePath: pathB,
    );

    await tester.pumpWidget(wrap());
    await tester.pump();
    await openSheet(tester);

    await tester.tap(find.text('Re-download all'));
    await settleRealIo(tester);

    final jobs = {
      for (final j in manager.snapshot())
        j.uuidId: (j.quality, j.replacesFilePath),
    };
    expect(jobs, {'a': ('192', pathA), 'b': ('original', pathB)});
    expect(find.text('Re-downloading…'), findsNWidgets(2));
    expect(find.text('Re-download queued'), findsOneWidget);

    await flushDispose(tester);
  });

  testWidgets('a failed Re-download shows the "Couldn’t queue" snackbar',
      (tester) async {
    await _insertTrack(
      db,
      uuid: 'abc',
      revision: 6,
      downloadedAtRevision: 5,
      filePath: realFile('abc'),
    );

    await tester.pumpWidget(wrap(failingQualities: {'192'}));
    await tester.pump();
    await openSheet(tester);

    await tester.tap(find.byTooltip('Re-download'));
    await settleRealIo(tester);

    expect(manager.snapshot(), isEmpty);
    expect(find.text('Couldn’t queue re-download. Try again.'), findsOneWidget);
    expect(find.text('Re-download queued'), findsNothing);
    expect(find.byTooltip('Re-download'), findsOneWidget,
        reason: 'the row stays actionable, not stuck "Re-downloading…"');

    await flushDispose(tester);
  });

  testWidgets(
    'Re-download all with one failing quality group still queues the rest '
    'and reports the partial failure',
    (tester) async {
      await _insertTrack(
        db,
        uuid: 'a',
        revision: 6,
        downloadedAtRevision: 5,
        filePath: realFile('a'),
      );
      await _insertTrack(
        db,
        uuid: 'b',
        revision: 6,
        downloadedAtRevision: 5,
        downloadedQuality: 'original',
        filePath: realFile('b'),
      );

      // The first group ('192', inserted first) fails; 'original' must still
      // be queued after it.
      await tester.pumpWidget(wrap(failingQualities: {'192'}));
      await tester.pump();
      await openSheet(tester);

      await tester.tap(find.text('Re-download all'));
      await settleRealIo(tester);

      expect(manager.snapshot().map((j) => j.uuidId), ['b']);
      expect(
        find.text('Couldn’t queue re-download for 1 of 2 tracks. Try again.'),
        findsOneWidget,
      );
      expect(find.text('Re-download queued'), findsNothing);
      expect(find.text('Re-downloading…'), findsOneWidget);

      await flushDispose(tester);
    },
  );

  testWidgets('Dismiss all clears the list and the banner', (tester) async {
    await _insertTrack(db, uuid: 'a', revision: 6, downloadedAtRevision: 5);
    await _insertTrack(db, uuid: 'b', revision: 9, downloadedAtRevision: 5);

    await tester.pumpWidget(wrap());
    await tester.pump();
    await openSheet(tester);

    await tester.tap(find.text('Dismiss all'));
    await tester.pump(const Duration(seconds: 1));

    final dismissed = {
      for (final r in await db.select(db.tracks).get())
        r.uuidId: r.staleDismissedAtRevision,
    };
    expect(dismissed, {'a': 6, 'b': 9});
    expect(find.text('Nothing to review'), findsOneWidget);
    expect(bannerText, findsNothing);

    await flushDispose(tester);
  });
}

/// Throws from [enqueueTracksAtQuality] for the listed qualities.
class _FlakyDownloadManager extends DownloadManager {
  _FlakyDownloadManager(
    this._failing, {
    required super.db,
    required super.coverArtStore,
    required super.directoryProvider,
    required super.isOfflineFn,
  });
  final Set<String> _failing;

  @override
  Future<void> enqueueTracksAtQuality(
    List<TrackUI> tracks, {
    required String quality,
    bool force = false,
  }) async {
    if (_failing.contains(quality)) throw StateError('enqueue failed');
    return super.enqueueTracksAtQuality(tracks, quality: quality, force: force);
  }
}

class _FixedSettings extends SettingsNotifier {
  _FixedSettings(this._notify, this._downloadQuality);
  final bool _notify;
  final String _downloadQuality;

  @override
  Future<AppSettings> build() async {
    return AppSettings(
      persistedStreamQuality: 'original',
      downloadQuality: _downloadQuality,
      notifyStaleDownloads: _notify,
    );
  }
}
