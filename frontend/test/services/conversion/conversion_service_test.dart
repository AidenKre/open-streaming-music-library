// SC-26 (5A.0): the conversion rules live in the model. ConversionService
// decides whether a conversion may start (online, not loaded in the player,
// a fresh completed sync, no pending edit, the track still exists, the
// server advertises convert with an allowed target, a still-valid preset)
// and maps enqueue/cancel failures to user text. The view only shows the
// sheets and the messages it returns.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/conversion_job.dart';
import 'package:frontend/models/dto/client_track_dto.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/conversion/conversion_service.dart';
import 'package:frontend/services/server_binding_gate.dart';

import '../../helpers/server_binding.dart';
import '../../helpers/test_offline.dart';

class _Sync extends TrackSyncNotifier {
  _Sync({this.result = true, this.onSync});
  final bool result;
  final Future<void> Function()? onSync;
  int calls = 0;
  @override
  Future<TrackSyncState> build() async => const TrackSyncState();
  @override
  Future<void> sync() async {}
  @override
  Future<bool> syncFresh() async {
    calls++;
    await onSync?.call();
    return result;
  }
}

/// The real syncFresh's rule: it fails at once unless the connection is
/// verified right now.
class _FastFailSync extends _Sync {
  _FastFailSync(this.gate);
  final ServerBindingGate gate;
  @override
  Future<bool> syncFresh() async {
    calls++;
    return gate.state is BindingVerified;
  }
}

class _Jobs extends ConversionJobsNotifier {
  _Jobs({this.enqueueError, this.cancelError});
  final Object? enqueueError;
  final Object? cancelError;
  final enqueued = <Map<String, Object?>>[];
  final cancelled = <int>[];
  int refreshes = 0;
  @override
  List<ConversionJob> build() => const [];
  @override
  Future<void> refreshAll() async => refreshes++;
  @override
  Future<void> cancel(int jobId) async {
    cancelled.add(jobId);
    if (cancelError != null) throw cancelError!;
  }

  @override
  Future<ConversionJob> enqueue({
    required String uuidId,
    required String targetCodec,
    required int? targetBitrateKbps,
    required int? baseRevision,
  }) async {
    enqueued.add({
      'uuidId': uuidId,
      'targetCodec': targetCodec,
      'targetBitrateKbps': targetBitrateKbps,
      'baseRevision': baseRevision,
    });
    if (enqueueError != null) throw enqueueError!;
    return ConversionJob(
      jobId: 1,
      uuidId: uuidId,
      targetCodec: targetCodec,
      targetContainer: 'm4a',
      status: const ConversionQueued(),
    );
  }
}

const _caps = AppInfo(
  entities: {
    'track': EntityInfo(actions: ['convert']),
  },
  conversion: ConversionCapabilities(
    targets: [
      ConversionTargetInfo(codec: 'aac', isLossless: false),
      ConversionTargetInfo(codec: 'flac', isLossless: true),
    ],
    bitratePresets: [320, 256, 192, 128],
  ),
);

ApiException _apiError(int status, Object detail) =>
    ApiException(status, jsonEncode({'detail': detail}));

TrackUI _loaded(String uuid) => TrackUI(
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

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final dto = ClientTrackDto.fromJson({
      'uuid_id': 'u1',
      'created_at': 1000,
      'last_updated': 1000,
      'revision': 1,
      'metadata': {
        'title': 'T',
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
  });

  tearDown(() => db.close());

  ({ProviderContainer c, _Sync sync, _Jobs jobs}) scope({
    bool offline = false,
    TrackUI? playing,
    TrackUI? Function()? playingNow,
    _Sync? sync,
    _Jobs? jobs,
    AppInfo caps = _caps,
    Object? appInfoError,
    AppInfo Function()? capsNow,
    ServerBindingGate? gate,
  }) {
    final s = sync ?? _Sync();
    final j = jobs ?? _Jobs();
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (playingNow != null)
          currentTrackProvider.overrideWith((ref) => playingNow())
        else
          currentTrackProvider.overrideWithValue(playing),
        trackSyncProvider.overrideWith(() => s),
        appInfoProvider.overrideWith((ref) async {
          if (appInfoError != null) throw appInfoError;
          return capsNow?.call() ?? caps;
        }),
        conversionJobsProvider.overrideWith(() => j),
        offlineModeProvider.overrideWith(() => TestOffline(offline)),
        if (gate != null) serverBindingGateProvider.overrideWithValue(gate),
      ],
    );
    addTearDown(c.dispose);
    return (c: c, sync: s, jobs: j);
  }

  ConversionService service(ProviderContainer c) =>
      c.read(conversionServiceProvider);

  group('prepare', () {
    test('no preset: the user picks from the allowed targets', () async {
      final s = scope();
      final prep = await service(s.c).prepare('u1');
      expect(prep, isA<ConversionNeedsTarget>());
      final draft = (prep as ConversionNeedsTarget).draft;
      expect(draft.uuidId, 'u1');
      expect(draft.sourceCodec, 'flac');
      expect(draft.revision, 1);
      expect(draft.allowedTargets.map((t) => t.codec), ['aac']);
      expect(draft.bitratePresets, [320, 256, 192, 128]);
      expect(s.sync.calls, 1, reason: 'a fresh sync first');
    });

    // U22-FE-LIFECYCLE-B-08: every app resume (each window refocus on the
    // desktop) re-probes the server. Convert right after it waits for that
    // check (bounded) instead of failing "Couldn't sync" at once.
    test('right after an app resume, Convert waits for the pending check',
        () async {
      await seedTestBinding(db, baseUrl: 'http://s');
      final controlled = ControlledGate(db);
      addTearDown(controlled.dispose);
      unawaited(controlled.gate.startConnection('http://s'));
      await pumpEventQueue();
      controlled.respond('inst-1');
      await controlled.gate.awaitVerified();
      unawaited(controlled.gate.startConnection('http://s')); // the resume
      await pumpEventQueue();

      final s = scope(
          sync: _FastFailSync(controlled.gate), gate: controlled.gate);
      final prep = service(s.c).prepare('u1');
      await pumpEventQueue();
      controlled.respond('inst-1');
      expect(await prep, isA<ConversionNeedsTarget>());
      expect(s.sync.calls, 1);
    });

    // U25-A-04: every provider is read before the first wait, so a rebuild
    // of the service while the fresh sync runs (its ref disposed) still
    // gets the verdict instead of a use-after-dispose error.
    test('reads its providers before waiting: a rebuild during the sync '
        'still answers', () async {
      late ProviderContainer c;
      final s = scope(
        sync: _Sync(
          onSync: () async {
            c.invalidate(conversionServiceProvider);
            c.read(conversionServiceProvider); // the old ref is disposed
          },
        ),
      );
      c = s.c;
      final prep = await service(c).prepare('u1');
      expect(prep, isA<ConversionNeedsTarget>());
      expect(s.sync.calls, 1);
    });

    // Review r1 #2: capabilities refreshed while the sync runs (recovery's
    // refetch, or the flush's 422 drift) are the ones checked, as before.
    test('capabilities refreshed during the sync are the ones checked',
        () async {
      var current = const AppInfo(); // advertises no convert
      late ProviderContainer c;
      final s = scope(
        capsNow: () => current,
        sync: _Sync(
          onSync: () async {
            current = _caps;
            c.invalidate(appInfoProvider);
          },
        ),
      );
      c = s.c;
      expect(await service(c).prepare('u1'), isA<ConversionNeedsTarget>());
    });

    // The capabilities are read before the sync now: a refusal that never
    // gets to them leaves no unhandled error behind (the test zone would
    // report it).
    test('a refusal before the capability check leaves no stray error',
        () async {
      final s = scope(
        sync: _Sync(result: false),
        appInfoError: StateError('capabilities unavailable'),
      );
      final prep = await service(s.c).prepare('u1');
      expect(prep, isA<ConversionRefused>());
      await pumpEventQueue();
    });

    test('the revision is read after the fresh sync', () async {
      final s = scope(
        sync: _Sync(onSync: () => db.updateTrackRevision('u1', 7)),
      );
      final prep = await service(s.c).prepare('u1');
      expect((prep as ConversionNeedsTarget).draft.revision, 7);
    });

    test('a still-allowed preset is ready without asking', () async {
      final prep = await service(
        scope().c,
      ).prepare('u1', presetCodec: 'aac', presetBitrateKbps: 192);
      expect(prep, isA<ConversionReady>());
      final ready = prep as ConversionReady;
      expect(ready.choice.codec, 'aac');
      expect(ready.choice.bitrateKbps, 192);
    });

    test('a preset no longer allowed falls back to asking', () async {
      final prep = await service(
        scope().c,
      ).prepare('u1', presetCodec: 'aac', presetBitrateKbps: 64);
      expect(prep, isA<ConversionNeedsTarget>());
    });

    final refusals =
        <
          String,
          ({
            String message,
            bool syncs,
            ({ProviderContainer c, _Sync sync, _Jobs jobs}) Function() make,
            Future<void> Function()? arrange,
          })
        >{
          'offline': (
            message: "You're offline. Converting needs the server.",
            syncs: false,
            make: () => scope(offline: true),
            arrange: null,
          ),
          'loaded in the player': (
            message:
                'This track is loaded in the player. Stop or skip it before '
                'converting.',
            syncs: false,
            make: () => scope(playing: _loaded('u1')),
            arrange: null,
          ),
          'sync failed': (
            message: "Couldn't sync with the server. Try again.",
            syncs: true,
            make: () => scope(sync: _Sync(result: false)),
            arrange: null,
          ),
          'pending edit': (
            message:
                "Finish syncing this track's pending edit before converting.",
            syncs: true,
            make: () => scope(),
            arrange: () => db
                .into(db.pendingEdits)
                .insert(
                  PendingEditsCompanion.insert(
                    uuidId: 'u1',
                    writeMode: 'db_only',
                    status: const Value('pending'),
                    valuesJson: '{}',
                    baseRevision: const Value(1),
                    updatedAt: 1000,
                  ),
                )
                .then((_) {}),
          ),
          'track gone': (
            message: 'This track is no longer in your library.',
            syncs: true,
            make: () => scope(),
            arrange: () => db
                .customStatement("DELETE FROM trackmetadata WHERE uuid_id='u1'")
                .then((_) => db.customStatement(
                      "DELETE FROM tracks WHERE uuid_id='u1'",
                    )),
          ),
          'not advertised': (
            message: "This server doesn't support conversion.",
            syncs: true,
            make: () => scope(
              caps: const AppInfo(
                entities: {'track': EntityInfo(actions: [])},
                conversion: ConversionCapabilities(
                  targets: [
                    ConversionTargetInfo(codec: 'aac', isLossless: false),
                  ],
                  bitratePresets: [192],
                ),
              ),
            ),
            arrange: null,
          ),
          'no allowed target': (
            message: 'No conversion targets are available for this track.',
            syncs: true,
            make: () => scope(
              caps: const AppInfo(
                entities: {
                  'track': EntityInfo(actions: ['convert']),
                },
                conversion: ConversionCapabilities(
                  targets: [
                    ConversionTargetInfo(codec: 'flac', isLossless: true),
                  ],
                  bitratePresets: [192],
                ),
              ),
            ),
            arrange: null,
          ),
        };

    for (final entry in refusals.entries) {
      test('refused: ${entry.key}', () async {
        final r = entry.value;
        await r.arrange?.call();
        final s = r.make();
        final prep = await service(s.c).prepare('u1');
        expect(prep, isA<ConversionRefused>());
        expect((prep as ConversionRefused).message, r.message);
        expect(s.sync.calls, r.syncs ? 1 : 0);
        expect(s.jobs.enqueued, isEmpty);
      });
    }
  });

  group('submit', () {
    Future<ConversionDraft> draft(ProviderContainer c) async =>
        ((await service(c).prepare('u1')) as ConversionNeedsTarget).draft;

    test('enqueues the post-sync revision; null means started', () async {
      final s = scope();
      final d = await draft(s.c);
      final error = await service(
        s.c,
      ).submit(d, const ConvertTargetChoice(codec: 'aac', bitrateKbps: 192));
      expect(error, isNull);
      expect(s.jobs.enqueued.single, {
        'uuidId': 'u1',
        'targetCodec': 'aac',
        'targetBitrateKbps': 192,
        'baseRevision': 1,
      });
    });

    test('a lossless target never carries a bitrate', () async {
      final s = scope(
        caps: const AppInfo(
          entities: {
            'track': EntityInfo(actions: ['convert']),
          },
          conversion: ConversionCapabilities(
            targets: [ConversionTargetInfo(codec: 'alac', isLossless: true)],
            bitratePresets: [192],
          ),
        ),
      );
      final d = await draft(s.c);
      await service(
        s.c,
      ).submit(d, const ConvertTargetChoice(codec: 'alac', bitrateKbps: 192));
      expect(s.jobs.enqueued.single['targetBitrateKbps'], isNull);
    });

    test('playback that started meanwhile refuses the submit', () async {
      TrackUI? nowPlaying;
      final s = scope(playingNow: () => nowPlaying);
      final d = await draft(s.c);
      nowPlaying = _loaded('u1'); // playback started while the sheets were open
      s.c.invalidate(currentTrackProvider);
      final error = await service(
        s.c,
      ).submit(d, const ConvertTargetChoice(codec: 'aac', bitrateKbps: 192));
      expect(
        error,
        'This track is loaded in the player. Stop or skip it before '
        'converting.',
      );
      expect(s.jobs.enqueued, isEmpty);
    });

    test('job_active: a readable message, and the jobs are refreshed', () async {
      final s = scope(
        jobs: _Jobs(
          enqueueError: ApiException(
            409,
            jsonEncode({
              'detail': {'error': 'job_active'},
            }),
          ),
        ),
      );
      final d = await draft(s.c);
      final error = await service(
        s.c,
      ).submit(d, const ConvertTargetChoice(codec: 'aac', bitrateKbps: 192));
      expect(error, 'A conversion for this track is already in progress.');
      expect(s.jobs.refreshes, 1);
    });

    test('a network failure reads as unreachable', () async {
      final s = scope(
        jobs: _Jobs(enqueueError: NetworkException('down', attemptsMade: 1)),
      );
      final d = await draft(s.c);
      expect(
        await service(
          s.c,
        ).submit(d, const ConvertTargetChoice(codec: 'aac', bitrateKbps: 192)),
        "Couldn't reach the server. Try again.",
      );
    });
  });

  group('cancel', () {
    test('null when cancelled', () async {
      final s = scope();
      expect(await service(s.c).cancel(5), isNull);
      expect(s.jobs.cancelled, [5]);
    });

    test('a failed cancel is a message, never an uncaught error', () async {
      final s = scope(jobs: _Jobs(cancelError: ApiException(500, 'boom')));
      expect(
        await service(s.c).cancel(5),
        "Couldn't cancel the conversion. Try again.",
      );
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
        canConvertTrack(isOffline: false, appInfo: _caps, codec: 'flac'),
        isTrue,
      );
      expect(
        canConvertTrack(isOffline: true, appInfo: _caps, codec: 'flac'),
        isFalse,
      );
      expect(
        canConvertTrack(
          isOffline: false,
          appInfo: AppInfo(conversion: _caps.conversion),
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
}
