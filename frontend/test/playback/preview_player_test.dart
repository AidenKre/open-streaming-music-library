import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_focus.dart';
import 'package:frontend/playback/codec_support.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/preview_engine.dart';
import 'package:frontend/playback/preview_player.dart';
import 'package:frontend/playback/track_cache_manager.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/quality_presets.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/server_binding_gate.dart';

import '../helpers/test_credentials.dart';
import 'audio_focus_test.dart'
    show FakeAudioSessionPort, FakeTimers, RelinquishingOwner;

/// The scope's binding gate: answers the token permit with [allowed].
class _Gate extends Fake implements ServerBindingGate {
  _Gate({required this.allowed});
  final bool allowed;
  final asked = <String>[];

  @override
  Future<bool> whenMaySendTokenTo(String baseUrl) async {
    asked.add(baseUrl);
    return allowed;
  }
}

class _Offline extends OfflineModeNotifier {
  @override
  bool build() {
    super.build();
    return true;
  }
}

void main() {
  group('preview sources (O11, OPEN-M-11)', () {
    PreviewSourceUris uris({
      bool offline = false,
      bool allowed = true,
      String? token = 'mt',
      List<String>? asked,
    }) =>
        PreviewSourceUris(
          baseUrl: 'http://srv:1/base',
          mediaToken: token,
          mayAttachToken: () async {
            asked?.add('asked');
            return allowed;
          },
          isOffline: () => offline,
        );

    test('a staged item previews through its media-token route', () async {
      final r = await uris().resolve(const StagedUploadPreview('i1'));
      expect(r.refusal, isNull);
      expect(r.uri.toString(),
          'http://srv:1/base/tracks/uploads/items/i1/preview?access_token=mt');
    });

    test('a library track previews through its normal stream URL', () async {
      final r = await uris().resolve(const LibraryTrackPreview('t1'));
      expect(r.uri.toString(),
          'http://srv:1/base/tracks/t1/stream?access_token=mt');
    });

    test('offline, preview needs a connection and asks nothing', () async {
      final asked = <String>[];
      final r = await uris(offline: true, asked: asked)
          .resolve(const StagedUploadPreview('i1'));
      expect(r.uri, isNull);
      expect(r.refusal, PreviewStatus.needsConnection);
      expect(asked, isEmpty);
    });

    test('the token may not go to this server: unavailable, no URI', () async {
      final r = await uris(allowed: false)
          .resolve(const LibraryTrackPreview('t1'));
      expect(r.uri, isNull);
      expect(r.refusal, PreviewStatus.unavailable);
    });

    test('no media token: unavailable', () async {
      final r = await uris(token: null).resolve(const StagedUploadPreview('i1'));
      expect(r.uri, isNull);
      expect(r.refusal, PreviewStatus.unavailable);
    });

    test('the staged URI builder keeps the base path', () {
      expect(
          buildStagedPreviewUri('http://h/x/', 'i', mediaToken: 'm').toString(),
          'http://h/x/tracks/uploads/items/i/preview?access_token=m');
    });

    test('the scope provider asks the gate about the scope base URL',
        () async {
      final gate = _Gate(allowed: true);
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(testApiClient('http://srv:1',
            MockClient((_) async => http.Response('', 500)))),
        credentialsProvider.overrideWithValue(testCredentials),
        serverBindingGateProvider.overrideWithValue(gate),
      ]);
      addTearDown(c.dispose);
      final r = await c
          .read(previewSourceUrisProvider)
          .resolve(const StagedUploadPreview('i1'));
      expect(gate.asked, ['http://srv:1']);
      expect(r.uri?.queryParameters['access_token'],
          testCredentials.mediaToken);
    });

    test('the scope provider reads the offline flag', () async {
      final gate = _Gate(allowed: true);
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(testApiClient('http://srv:1',
            MockClient((_) async => http.Response('', 500)))),
        credentialsProvider.overrideWithValue(testCredentials),
        serverBindingGateProvider.overrideWithValue(gate),
        offlineModeProvider.overrideWith(_Offline.new),
      ]);
      addTearDown(c.dispose);
      final r = await c
          .read(previewSourceUrisProvider)
          .resolve(const LibraryTrackPreview('t1'));
      expect(r.refusal, PreviewStatus.needsConnection);
      expect(gate.asked, isEmpty);
    });

    // Sign-off OPEN-M-11 (E8 review): a failed server check is handled like
    // offline (as playback does since step D): the preview needs a
    // connection, not "unavailable".
    test('the scope provider: the server check failed reads as needs a '
        'connection', () async {
      final gate = _Gate(allowed: false);
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(testApiClient('http://srv:1',
            MockClient((_) async => http.Response('', 500)))),
        credentialsProvider.overrideWithValue(testCredentials),
        serverBindingGateProvider.overrideWithValue(gate),
        streamsUnavailableProvider.overrideWithValue(() => true),
      ]);
      addTearDown(c.dispose);
      final r = await c
          .read(previewSourceUrisProvider)
          .resolve(const LibraryTrackPreview('t1'));
      expect(r.refusal, PreviewStatus.needsConnection);
      expect(gate.asked, isEmpty);
    });
  });

  // 7-R1-25: a library-track preview streams at the quality the device's
  // codec rule gives (LocalSourcePolicy.streamQualityFor; the user's decision
  // of 2026-11-09 on device codec support): "original" of a codec this device
  // cannot decode streams at the transcoded fallback, as the queue plays it.
  group('7-R1-25: a library preview follows the device codec rule', () {
    const noFlac =
        CodecSupport({AudioCodecFamily.mp3, AudioCodecFamily.aac});

    PreviewSourceUris uris({
      required CodecSupport codecs,
      String? codec,
      List<String>? looked,
      bool offline = false,
    }) =>
        PreviewSourceUris(
          baseUrl: 'http://srv:1/base',
          mediaToken: 'mt',
          mayAttachToken: () async => true,
          isOffline: () => offline,
          localSources: LocalSourcePolicy(codecs: codecs),
          sourceCodecOf: (uuid) async {
            looked?.add(uuid);
            return codec;
          },
        );

    test('a codec the device cannot decode streams transcoded', () async {
      final looked = <String>[];
      final r = await uris(codecs: noFlac, codec: 'flac', looked: looked)
          .resolve(const LibraryTrackPreview('t1'));
      expect(looked, ['t1']);
      expect(r.uri!.path, '/base/tracks/t1/stream');
      expect(r.uri!.queryParameters['quality'], transcodedFallbackQuality);
      expect(r.uri!.queryParameters['access_token'], 'mt');
    });

    test('a codec the device decodes streams the original', () async {
      final r = await uris(codecs: noFlac, codec: 'mp3')
          .resolve(const LibraryTrackPreview('t1'));
      expect(r.uri.toString(),
          'http://srv:1/base/tracks/t1/stream?access_token=mt');
    });

    test('an unknown codec streams the original (unknown is never '
        'unsupported)', () async {
      final r = await uris(codecs: noFlac, codec: null)
          .resolve(const LibraryTrackPreview('t1'));
      expect(r.uri!.queryParameters.containsKey('quality'), isFalse);
    });

    test('a device whose codecs are unknown streams the original', () async {
      final r = await uris(codecs: const CodecSupport.unknown(), codec: 'flac')
          .resolve(const LibraryTrackPreview('t1'));
      expect(r.uri!.queryParameters.containsKey('quality'), isFalse);
    });

    test('a staged item never asks for a track codec', () async {
      final looked = <String>[];
      final r = await uris(codecs: noFlac, codec: 'flac', looked: looked)
          .resolve(const StagedUploadPreview('i1'));
      expect(looked, isEmpty);
      expect(r.uri.toString(),
          'http://srv:1/base/tracks/uploads/items/i1/preview?access_token=mt');
    });

    test('a refused preview asks for nothing', () async {
      final looked = <String>[];
      final r = await uris(
              codecs: noFlac, codec: 'flac', looked: looked, offline: true)
          .resolve(const LibraryTrackPreview('t1'));
      expect(r.refusal, PreviewStatus.needsConnection);
      expect(looked, isEmpty);
    });

    test('a codec lookup that fails is an unknown codec: the original plays '
        '(review r1 finding 6)', () async {
      final r = await PreviewSourceUris(
        baseUrl: 'http://srv:1/base',
        mediaToken: 'mt',
        mayAttachToken: () async => true,
        isOffline: () => false,
        localSources: LocalSourcePolicy(codecs: noFlac),
        sourceCodecOf: (_) async => throw StateError('database closed'),
      ).resolve(const LibraryTrackPreview('t1'));
      expect(r.refusal, isNull);
      expect(r.uri.toString(),
          'http://srv:1/base/tracks/t1/stream?access_token=mt');
    });

    test('the scope provider uses the shared rule and the local catalog codec',
        () async {
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(testApiClient('http://srv:1',
            MockClient((_) async => http.Response('', 500)))),
        credentialsProvider.overrideWithValue(testCredentials),
        serverBindingGateProvider.overrideWithValue(_Gate(allowed: true)),
        codecSupportProvider.overrideWithValue(noFlac),
        browseRepositoryProvider
            .overrideWithValue(_CatalogCodecs({'t1': 'flac', 't2': 'mp3'})),
      ]);
      addTearDown(c.dispose);
      final flac = await c
          .read(previewSourceUrisProvider)
          .resolve(const LibraryTrackPreview('t1'));
      expect(flac.uri!.queryParameters['quality'], transcodedFallbackQuality);
      final mp3 = await c
          .read(previewSourceUrisProvider)
          .resolve(const LibraryTrackPreview('t2'));
      expect(mp3.uri!.queryParameters.containsKey('quality'), isFalse);
      final absent = await c
          .read(previewSourceUrisProvider)
          .resolve(const LibraryTrackPreview('not-synced'));
      expect(absent.uri!.queryParameters.containsKey('quality'), isFalse,
          reason: 'a track not in the local catalog has an unknown codec');
    });
  });


  group('PreviewPlayer (spec §5 Preview, SC-27 inv. 5)', () {
    late FakeTimers timers;
    late AudioFocus focus;
    late RelinquishingOwner library;
    late List<FakePreviewEngine> engines;
    late bool offline;
    late bool allowed;
    Completer<void>? gate;

    setUp(() {
      timers = FakeTimers();
      focus = AudioFocus(_NoSession(), timer: timers.create);
      library = RelinquishingOwner('queue');
      focus.bind(AudioOutput.queue, library);
      engines = [];
      offline = false;
      allowed = true;
      gate = null;
    });

    tearDown(() => focus.dispose());

    ProviderContainer container() {
      final c = ProviderContainer(overrides: [
        audioFocusProvider.overrideWithValue(focus),
        previewSourceUrisProvider.overrideWithValue(PreviewSourceUris(
          baseUrl: 'http://srv:1',
          mediaToken: 'mt',
          mayAttachToken: () async {
            await gate?.future;
            return allowed;
          },
          isOffline: () => offline,
        )),
        previewEngineFactoryProvider.overrideWithValue(() {
          final engine = FakePreviewEngine();
          engines.add(engine);
          return engine;
        }),
      ]);
      addTearDown(c.dispose);
      c.listen(previewPlayerProvider, (_, _) {});
      return c;
    }

    PreviewPlayer player(ProviderContainer c) =>
        c.read(previewPlayerProvider.notifier);
    PreviewState state(ProviderContainer c) => c.read(previewPlayerProvider);

    /// Starts [source] and lets the library acknowledge; the load is left
    /// pending.
    Future<FakePreviewEngine> loading(ProviderContainer c,
        [PreviewSource source = const StagedUploadPreview('i1')]) async {
      unawaited(player(c).play(source));
      await pumpEventQueue();
      library.acknowledge();
      await pumpEventQueue();
      return engines.last;
    }

    Future<FakePreviewEngine> playing(ProviderContainer c) async {
      final engine = await loading(c);
      engine.finishLoad(const Duration(seconds: 30));
      await pumpEventQueue();
      engine.emit(const EngineTransportState(true, EngineProcessingState.ready));
      await pumpEventQueue();
      return engine;
    }

    test('play asks the library to stop first, then loads and plays one '
        'source', () async {
      final c = container();
      unawaited(player(c).play(const StagedUploadPreview('i1')));
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.loading);
      expect(state(c).source, const StagedUploadPreview('i1'));
      expect(library.relinquishes, 1);
      expect(engines.expand((e) => e.loads), isEmpty,
          reason: 'nothing loads before the library acknowledged');
      library.acknowledge();
      await pumpEventQueue();
      final engine = engines.single;
      expect(engine.loads.single.toString(),
          'http://srv:1/tracks/uploads/items/i1/preview?access_token=mt');
      expect(engine.plays, 0);
      engine.finishLoad(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(engine.plays, 1);
      expect(state(c).status, PreviewStatus.playing);
      expect(state(c).duration, const Duration(seconds: 30));
      expect(focus.holder, AudioOutput.preview);
    });

    test('a library that never acknowledges: nothing loads or plays',
        () async {
      final c = container();
      unawaited(player(c).play(const StagedUploadPreview('i1')));
      await pumpEventQueue();
      timers.fireAll();
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.failed);
      expect(engines.expand((e) => e.loads), isEmpty);
      expect(engines.fold<int>(0, (n, e) => n + e.plays), 0);
    });

    test('offline: "needs a connection", and the library is not paused',
        () async {
      offline = true;
      final c = container();
      await player(c).play(const StagedUploadPreview('i1'));
      expect(state(c).status, PreviewStatus.needsConnection);
      expect(library.relinquishes, 0);
      expect(engines, isEmpty);
    });

    test('the token may not go to this server: unavailable, library not '
        'paused', () async {
      allowed = false;
      final c = container();
      await player(c).play(const LibraryTrackPreview('t1'));
      expect(state(c).status, PreviewStatus.unavailable);
      expect(library.relinquishes, 0);
      expect(engines, isEmpty);
    });

    test('a new source supersedes a pending load', () async {
      final c = container();
      final engine = await loading(c);
      unawaited(player(c).play(const LibraryTrackPreview('t2')));
      await pumpEventQueue();
      expect(engine.stops, greaterThanOrEqualTo(1));
      engine.finishLoad(null); // the old load completes late
      await pumpEventQueue();
      expect(engine.plays, 0, reason: 'a superseded load never plays');
      engine.finishLoad(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(engine.loads.last.path, '/tracks/t2/stream');
      expect(engine.plays, 1);
      expect(state(c).source, const LibraryTrackPreview('t2'));
      expect(state(c).status, PreviewStatus.playing);
    });

    test('a failed load reports failed and plays nothing', () async {
      final c = container();
      final engine = await loading(c);
      engine.failLoad();
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.failed);
      expect(engine.plays, 0);
    });

    test('a library play while preview loads stops preview; the late load '
        'never plays', () async {
      final c = container();
      final engine = await loading(c);
      final back = focus.beforePlay(AudioOutput.queue);
      await pumpEventQueue();
      expect(await back, isTrue);
      expect(focus.holder, AudioOutput.queue);
      expect(engine.stops, greaterThanOrEqualTo(1));
      expect(state(c).status, PreviewStatus.idle);
      engine.finishLoad(null);
      await pumpEventQueue();
      expect(engine.plays, 0);
    });

    test('a library play while preview is still resolving its source '
        'leaves preview idle, not loading for ever', () async {
      gate = Completer<void>();
      final c = container();
      unawaited(player(c).play(const StagedUploadPreview('i1')));
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.loading);
      final back = focus.beforePlay(AudioOutput.queue);
      await pumpEventQueue();
      expect(await back, isTrue);
      expect(state(c).status, PreviewStatus.idle);
      gate!.complete();
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.idle);
      expect(focus.holder, AudioOutput.queue);
      expect(engines.fold<int>(0, (n, e) => n + e.plays), 0);
    });

    test('asked to give the output up while playing, preview stops and '
        'acknowledges once its engine reports not playing', () async {
      final c = container();
      final engine = await playing(c);
      bool? granted;
      unawaited(focus.beforePlay(AudioOutput.queue).then((g) => granted = g));
      await pumpEventQueue();
      expect(engine.stops, 1);
      expect(state(c).status, PreviewStatus.idle);
      expect(granted, isNull, reason: 'the engine still reports playing');
      engine.emit(const EngineTransportState(false, EngineProcessingState.idle));
      await pumpEventQueue();
      expect(granted, isTrue);
    });

    test('pause and resume while holding the output', () async {
      final c = container();
      final engine = await playing(c);
      await player(c).pause();
      expect(engine.pauses, 1);
      expect(state(c).status, PreviewStatus.paused);
      await player(c).resume();
      expect(engine.plays, 2);
      expect(state(c).status, PreviewStatus.playing);
      expect(library.relinquishes, 1, reason: 'preview already holds');
    });

    test('resume after the library took the output back stops the library '
        'again and reloads the source', () async {
      final c = container();
      final engine = await playing(c);
      final back = focus.beforePlay(AudioOutput.queue);
      await pumpEventQueue();
      engine.emit(const EngineTransportState(false, EngineProcessingState.idle));
      expect(await back, isTrue);
      unawaited(player(c).resume());
      await pumpEventQueue();
      expect(library.relinquishes, 2);
      library.acknowledge();
      await pumpEventQueue();
      final reloaded = engines.last;
      expect(reloaded.loads.last, engine.loads.first);
      reloaded.finishLoad(null);
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.playing);
      expect(focus.holder, AudioOutput.preview);
    });

    test('close stops, disposes the engine and gives the output up; the '
        'library is not resumed', () async {
      final c = container();
      final engine = await playing(c);
      await player(c).close();
      expect(engine.stops, greaterThanOrEqualTo(1));
      expect(engine.disposed, isTrue);
      expect(focus.holder, isNull);
      expect(library.relinquishes, 1);
      expect(library.calls, isEmpty);
      expect(state(c).status, PreviewStatus.idle);
      expect(state(c).source, isNull);
      expect(focus.yieldedBy(AudioOutput.queue), isTrue,
          reason: 'the library stays paused for the user to resume');
    });

    test('a finished preview reports completed and keeps the output',
        () async {
      final c = container();
      final engine = await playing(c);
      engine.emit(
          const EngineTransportState(true, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.completed);
      expect(focus.holder, AudioOutput.preview);
    });

    test('quiesce closes admission at once, cancels the pending load, stops '
        'the engine and gives the output up', () async {
      final c = container();
      final engine = await loading(c);
      final quiescing = player(c).quiesce();
      unawaited(player(c).play(const LibraryTrackPreview('t9')));
      await quiescing;
      engine.finishLoad(null);
      await pumpEventQueue();
      expect(engines.fold<int>(0, (n, e) => n + e.plays), 0);
      expect(engines.expand((e) => e.loads), hasLength(1),
          reason: 'nothing admitted after quiesce');
      expect(engine.disposed, isTrue);
      expect(focus.holder, isNull);
      expect(state(c).status, PreviewStatus.idle);
    });

    test('quiesced is terminal: play and resume do nothing; quiesce is '
        'idempotent', () async {
      final c = container();
      await player(c).quiesce();
      await player(c).quiesce();
      await player(c).play(const StagedUploadPreview('i1'));
      await player(c).resume();
      expect(engines, isEmpty);
      expect(library.relinquishes, 0);
    });

    test('quiesce while the library has not yet acknowledged: no late audio, '
        'and the library can still take the output', () async {
      final c = container();
      unawaited(player(c).play(const StagedUploadPreview('i1')));
      await pumpEventQueue();
      await player(c).quiesce();
      library.acknowledge();
      await pumpEventQueue();
      expect(engines.fold<int>(0, (n, e) => n + e.plays), 0);
      expect(engines.expand((e) => e.loads), isEmpty);
      final back = focus.beforePlay(AudioOutput.queue);
      await pumpEventQueue();
      expect(await back, isTrue);
    });

    test('R1-01: replaying a finished preview reloads it (a finished plugin '
        'ignores play)', () async {
      final c = container();
      final engine = await playing(c);
      engine.emit(
          const EngineTransportState(true, EngineProcessingState.completed));
      await pumpEventQueue();
      unawaited(player(c).resume());
      await pumpEventQueue();
      final all = engines.expand((e) => e.loads).toList();
      expect(all, hasLength(2), reason: 'the source is loaded again');
      engines.last.finishLoad(null);
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.playing);
    });

    // U19-FE-PB-ENGINE-A-06: the stop before a new load reports the old
    // source's `completed`; that must not strand the new preview.
    test('U19-A-06 a preview of another item after a finished one plays',
        () async {
      final c = container();
      final engine = await playing(c);
      engine.emit(
          const EngineTransportState(true, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.completed);

      unawaited(player(c).play(const StagedUploadPreview('i2')));
      await pumpEventQueue();
      engines.last.finishLoad(null);
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.playing);
      expect(state(c).source, const StagedUploadPreview('i2'));
      expect(engines.last.plays, greaterThanOrEqualTo(2));
    });

    test('U19-A-06 a finished preview still reports completed after a later '
        'one finishes too', () async {
      final c = container();
      final engine = await playing(c);
      engine.emit(
          const EngineTransportState(true, EngineProcessingState.completed));
      await pumpEventQueue();
      unawaited(player(c).play(const StagedUploadPreview('i2')));
      await pumpEventQueue();
      engines.last.finishLoad(null);
      await pumpEventQueue();
      engines.last.emit(
          const EngineTransportState(true, EngineProcessingState.completed));
      await pumpEventQueue();
      expect(state(c).status, PreviewStatus.completed);
    });

    test('R1-05: close while the library has not yet acknowledged leaves '
        'preview without the output', () async {
      final c = container();
      unawaited(player(c).play(const StagedUploadPreview('i1')));
      await pumpEventQueue();
      await player(c).close();
      library.acknowledge();
      await pumpEventQueue();
      expect(focus.holder, isNot(AudioOutput.preview));
      expect(engines.expand((e) => e.loads), isEmpty);
    });

    test('dispose cancels a pending load and releases the output', () async {
      final c = container();
      final engine = await loading(c);
      c.dispose();
      engine.finishLoad(null);
      await pumpEventQueue();
      expect(engine.plays, 0);
      expect(engine.disposed, isTrue);
      expect(focus.holder, isNull);
    });
  });
  group('PreviewPlayer as the focus owner: interruptions and noisy output '
      '(7-L06)', () {
    late FakeAudioSessionPort port;
    late AudioFocus focus;
    late RelinquishingOwner library;
    late List<FakePreviewEngine> engines;

    setUp(() {
      port = FakeAudioSessionPort();
      focus = AudioFocus(port, timer: FakeTimers().create);
      library = RelinquishingOwner('queue');
      focus.bind(AudioOutput.queue, library);
      engines = [];
    });

    tearDown(() async {
      focus.dispose();
      await port.controller.close();
    });

    Future<(ProviderContainer, PreviewPlayer, FakePreviewEngine)>
        playing() async {
      final c = ProviderContainer(overrides: [
        audioFocusProvider.overrideWithValue(focus),
        previewSourceUrisProvider.overrideWithValue(PreviewSourceUris(
          baseUrl: 'http://srv:1',
          mediaToken: 'mt',
          mayAttachToken: () async => true,
          isOffline: () => false,
        )),
        previewEngineFactoryProvider.overrideWithValue(() {
          final engine = FakePreviewEngine();
          engines.add(engine);
          return engine;
        }),
      ]);
      addTearDown(c.dispose);
      c.listen(previewPlayerProvider, (_, _) {});
      final player = c.read(previewPlayerProvider.notifier);
      unawaited(player.play(const StagedUploadPreview('i1')));
      await pumpEventQueue();
      library.acknowledge();
      await pumpEventQueue();
      engines.single.finishLoad(null);
      await pumpEventQueue();
      expect(c.read(previewPlayerProvider).status, PreviewStatus.playing);
      return (c, player, engines.single);
    }

    Future<void> emit(AudioSessionEvent event) async {
      port.emit(event);
      await pumpEventQueue();
    }

    test('an interruption pauses preview and its end resumes it; the library '
        'hears nothing and is never resumed', () async {
      final (c, _, engine) = await playing();
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      expect(engine.pauses, 1);
      expect(c.read(previewPlayerProvider).status, PreviewStatus.paused);
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(engine.plays, 2);
      expect(c.read(previewPlayerProvider).status, PreviewStatus.playing);
      expect(library.calls, isEmpty);
      expect(library.relinquishes, 1, reason: 'asked once, at preview start');
      expect(focus.holder, AudioOutput.preview);
    });

    test('a user pause during an interruption is never undone', () async {
      final (_, player, engine) = await playing();
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await player.pause();
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(engine.plays, 1);
    });

    test('an interruption whose end may not resume stays paused', () async {
      final (c, _, engine) = await playing();
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.unknown));
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.unknown));
      expect(engine.plays, 1);
      expect(c.read(previewPlayerProvider).status, PreviewStatus.paused);
    });

    test('an interruption of paused preview does not start it', () async {
      final (_, player, engine) = await playing();
      await player.pause();
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(engine.plays, 1);
    });

    test('unplugged headphones pause preview; a later interruption end does '
        'not resume it', () async {
      final (c, _, engine) = await playing();
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      await emit(const AudioBecameNoisy());
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(engine.plays, 1);
      expect(c.read(previewPlayerProvider).status, PreviewStatus.paused);
      expect(library.calls, isEmpty);
    });

    test('a library take-back during an interruption: its end resumes '
        'neither preview nor (through preview) the library', () async {
      final (_, _, engine) = await playing();
      await emit(const AudioInterruptionBegan(AudioInterruptionKind.pause));
      expect(await focus.beforePlay(AudioOutput.queue), isTrue);
      await emit(const AudioInterruptionEnded(AudioInterruptionKind.pause));
      expect(engine.plays, 1, reason: 'preview gave the output away');
      expect(focus.holder, AudioOutput.queue);
    });
  });
  group('SC-15: the preview player is a reset quiesce participant', () {
    test('it runs after the listen recorder and before history (SC-15 '
        'order)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect([for (final q in c.read(localQuiescablesProvider)) q.quiesceName],
          ['playback', 'listens', 'preview', 'history', 'uploads', 'delete-jobs',
           'owned-file-cleanup', 'submissions']);
    });

    test('quiescing never builds a preview player', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final preview = c
          .read(localQuiescablesProvider)
          .singleWhere((q) => q.quiesceName == 'preview');
      await preview.quiesce();
      expect(c.exists(previewPlayerProvider), isFalse);
    });

    test('quiescing a live preview player silences it', () async {
      final focus = AudioFocus(_NoSession(), timer: FakeTimers().create);
      addTearDown(focus.dispose);
      final engines = <FakePreviewEngine>[];
      final c = ProviderContainer(overrides: [
        audioFocusProvider.overrideWithValue(focus),
        previewSourceUrisProvider.overrideWithValue(PreviewSourceUris(
          baseUrl: 'http://srv:1',
          mediaToken: 'mt',
          mayAttachToken: () async => true,
          isOffline: () => false,
        )),
        previewEngineFactoryProvider.overrideWithValue(() {
          final engine = FakePreviewEngine();
          engines.add(engine);
          return engine;
        }),
      ]);
      addTearDown(c.dispose);
      c.listen(previewPlayerProvider, (_, _) {});
      final player = c.read(previewPlayerProvider.notifier);
      unawaited(player.play(const StagedUploadPreview('i1')));
      await pumpEventQueue();
      engines.single.finishLoad(null);
      await pumpEventQueue();
      expect(engines.single.plays, 1);
      await c
          .read(localQuiescablesProvider)
          .singleWhere((q) => q.quiesceName == 'preview')
          .quiesce();
      expect(engines.single.stops, greaterThanOrEqualTo(1));
      expect(focus.holder, isNull);
      await player.play(const StagedUploadPreview('i2'));
      expect(engines, hasLength(1), reason: 'quiesced is terminal');
    });
  });
}

class _NoSession implements AudioSessionPort {
  @override
  Stream<AudioSessionEvent> get events => const Stream.empty();
}

/// A preview engine whose loads the test completes, recording commands.
class FakePreviewEngine implements PreviewEngine {
  final loads = <Uri>[];
  final _pending = <Completer<Duration?>>[];
  final _transport = StreamController<EngineTransportState>.broadcast();
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  bool disposed = false;

  /// Completes the oldest pending load.
  void finishLoad(Duration? duration) =>
      _pending.removeAt(0).complete(duration);

  void failLoad() =>
      _pending.removeAt(0).completeError(const PreviewLoadFailed());

  EngineTransportState? _last;

  void emit(EngineTransportState state) {
    _last = state;
    _transport.add(state);
  }

  @override
  Future<Duration?> load(Uri uri) {
    loads.add(uri);
    final load = Completer<Duration?>();
    _pending.add(load);
    return load.future;
  }

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  /// Like just_audio 0.10.5 (U19-A-06): stopping a finished player reports
  /// `(false, completed)` before it goes idle.
  @override
  Future<void> stop() async {
    stops++;
    if (_last?.processingState == EngineProcessingState.completed) {
      emit(const EngineTransportState(false, EngineProcessingState.completed));
    }
  }

  @override
  Stream<EngineTransportState> get transportStates => _transport.stream;

  @override
  void dispose() => disposed = true;
}

/// The local catalog, as far as a preview needs it: each track's codec.
class _CatalogCodecs extends Fake implements BrowseRepository {
  _CatalogCodecs(this.codecs);
  final Map<String, String?> codecs;

  @override
  Future<TrackUI?> getTrack(String uuidId) async {
    if (!codecs.containsKey(uuidId)) return null;
    return TrackUI(
      uuidId: uuidId,
      createdAt: 1,
      lastUpdated: 1,
      duration: 180,
      bitrateKbps: 900,
      sampleRateHz: 44100,
      channels: 2,
      hasAlbumArt: false,
      codec: codecs[uuidId],
    );
  }
}
