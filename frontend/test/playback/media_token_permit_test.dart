// Sign-off OPEN-M-11 step D (2026-11-17): the player's media token
// (`?access_token=` in stream URLs) follows the same rule as the session
// token. It is attached only when the binding gate allows it at the moment a
// stream source is built. A seed whose stream sources were built while a
// verdict was pending waits for that verdict (bounded by the gate) before it
// hands them to the native player. Sources built without the token get it on
// the next verification (`refreshWithheldMediaTokens`), and on a
// different-server verdict every stream source is replaced by one without
// the token (`releaseRemoteSources`; the queue player stops a remote current
// item first, in its lane; review r1 F5). On a failed check, signed out or no
// session, the sources ahead lose the token too (review r1 F4).
// A URL already handed to the native player cannot be withdrawn any other
// way.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/api/token_permit.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/services/server_binding_gate.dart';

class MockAudioPlayer extends Mock implements ja.AudioPlayer {}

class FakeAudioSource extends Fake implements ja.AudioSource {}

/// The binding gate's answer, controlled by the test.
class _Permit implements TokenPermit {
  bool allow = false;
  Completer<void>? pending;
  final asked = <Uri>[];
  int settles = 0;

  @override
  bool allowsTokenTo(Uri url) {
    asked.add(url);
    return allow;
  }

  @override
  Future<void> verdictSettled() {
    settles++;
    return pending?.future ?? Future.value();
  }
}

QueuePlaybackEntry _entry(int itemId, {String? filePath}) => QueuePlaybackEntry(
  itemId: itemId,
  queueType: QueueItemTypes.main,
  canonicalPosition: itemId,
  playPosition: itemId,
  uuidId: 'u$itemId',
  filePath: filePath,
);

Uri _uri(ja.AudioSource s) => (s as ja.UriAudioSource).uri;
bool _tokened(ja.AudioSource s) =>
    _uri(s).queryParameters.containsKey('access_token');

void main() {
  late MockAudioPlayer player;
  late StreamController<int?> indexController;
  late _Permit permit;
  late List<List<ja.AudioSource>> seeded;
  late List<(int, ja.AudioSource)> inserted;
  late List<int> removed;
  late int stops;

  setUpAll(() {
    registerFallbackValue(FakeAudioSource());
    registerFallbackValue(Duration.zero);
  });

  setUp(() {
    player = MockAudioPlayer();
    indexController = StreamController<int?>.broadcast();
    permit = _Permit();
    seeded = [];
    inserted = [];
    removed = [];
    stops = 0;
    var currentIndex = 0;
    when(() => player.positionDiscontinuityStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => player.playing).thenReturn(false);
    when(() => player.processingState).thenReturn(ja.ProcessingState.ready);
    when(() => player.duration).thenReturn(null);
    when(() => player.speed).thenReturn(1.0);
    when(() => player.errorStream).thenAnswer((_) => const Stream.empty());
    when(() => player.setAudioSources(any(),
        initialIndex: any(named: 'initialIndex'),
        initialPosition: any(named: 'initialPosition'))).thenAnswer((inv) async {
      seeded.add(List<ja.AudioSource>.from(
          inv.positionalArguments.first as List<ja.AudioSource>));
      currentIndex = inv.namedArguments[#initialIndex] as int? ?? 0;
      return const Duration(minutes: 3);
    });
    when(() => player.seek(any(), index: any(named: 'index')))
        .thenAnswer((inv) async {
      final index = inv.namedArguments[#index] as int?;
      if (index != null) currentIndex = index;
    });
    when(() => player.pause()).thenAnswer((_) async {});
    when(() => player.play()).thenAnswer((_) async {});
    when(() => player.stop()).thenAnswer((_) async => stops++);
    when(() => player.insertAudioSource(any(), any())).thenAnswer((inv) async {
      inserted.add((
        inv.positionalArguments[0] as int,
        inv.positionalArguments[1] as ja.AudioSource,
      ));
    });
    when(() => player.removeAudioSourceAt(any())).thenAnswer((inv) async {
      removed.add(inv.positionalArguments[0] as int);
    });
    when(() => player.dispose()).thenAnswer((_) async {});
    when(() => player.currentIndex).thenAnswer((_) => currentIndex);
    when(() => player.position).thenReturn(const Duration(seconds: 42));
    when(() => player.playerStateStream).thenAnswer((_) => const Stream.empty());
    when(() => player.positionStream).thenAnswer((_) => const Stream.empty());
    when(() => player.durationStream).thenAnswer((_) => const Stream.empty());
    when(() => player.currentIndexStream)
        .thenAnswer((_) => indexController.stream);
  });

  tearDown(() => indexController.close());

  JustAudioEngine engine({TokenPermit? mediaTokenPermit}) {
    final e = JustAudioEngine(player,
        streamBaseUrl: 'http://scope:9',
        streamMediaToken: 'media-token-A',
        mediaTokenPermit: mediaTokenPermit);
    addTearDown(e.dispose);
    return e;
  }

  group('at source build', () {
    test('allowed: stream sources carry the media token', () async {
      permit.allow = true;
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      expect(seeded.single.every(_tokened), isTrue);
      expect(permit.asked.first.path, '/tracks/u1/stream');
    });

    test('refused (a settled verdict): no stream source carries it', () async {
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      expect(seeded.single.any(_tokened), isFalse);
      expect(_uri(seeded.single.first).path, '/tracks/u1/stream');
    });

    test('no permit: fail closed, no token', () async {
      final e = engine();
      await e.setSeed([_entry(1)], currentItemId: 1);
      await pumpEventQueue();
      expect(seeded.single.any(_tokened), isFalse);
    });

    test('a local file never asks and never waits', () async {
      permit.pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1, filePath: '/dl/u1.m4a')], currentItemId: 1);
      await pumpEventQueue();
      expect(seeded, hasLength(1));
      expect(_uri(seeded.single.single).scheme, 'file');
      expect(permit.settles, 0);
    });

    test('allowed at build: the seed does not wait, even with a verdict '
        'pending', () async {
      permit
        ..allow = true
        ..pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1)], currentItemId: 1);
      await pumpEventQueue();
      expect(seeded, hasLength(1));
      expect(permit.settles, 0);
    });
  });

  // A tap made while the launch (or resume) check runs: the seed waits for
  // the verdict, bounded by the gate (ServerBindingGate.tokenWaitBound),
  // then hands the sources to the native player with or without the token.
  group('a seed made while a verdict is pending', () {
    test('waits, then goes with the token once verified', () async {
      permit.pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      expect(seeded, isEmpty, reason: 'nothing handed to the native player');

      permit.allow = true;
      permit.pending!.complete();
      await pumpEventQueue();
      expect(seeded.single.every(_tokened), isTrue);
    });

    test('a negative verdict (or the bound): handed over without the token',
        () async {
      permit.pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1)], currentItemId: 1);
      permit.pending!.complete();
      await pumpEventQueue();
      expect(seeded.single.any(_tokened), isFalse);
    });

    test('a newer seed during the wait supersedes it', () async {
      permit.pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1)], currentItemId: 1);
      await pumpEventQueue();
      permit.allow = true;
      await e.setSeed([_entry(5)], currentItemId: 5); // allowed: no wait
      await pumpEventQueue();
      permit.pending!.complete();
      await pumpEventQueue();
      expect(seeded, hasLength(1));
      expect(_uri(seeded.single.single).path, '/tracks/u5/stream');
    });
  });

  // Review r1 F2: only the current item's source can make a seed wait; a
  // downloaded current item never waits (its stream neighbours get the
  // token at the next verification).
  test('a downloaded current item with a stream neighbour does not wait',
      () async {
    permit.pending = Completer<void>();
    final e = engine(mediaTokenPermit: permit);
    await e.setSeed([_entry(1, filePath: '/dl/u1.m4a'), _entry(2)],
        currentItemId: 1);
    await pumpEventQueue();
    expect(seeded, hasLength(1));
    expect(permit.settles, 0);
    expect(_tokened(seeded.single[1]), isFalse);
  });

  // Review r1 F1: work issued while the seed waits for its verdict still
  // finds the native source the seed hands over.
  group('work issued while the seed waits', () {
    test('a quality rebuild of the current item reaches the native player',
        () async {
      permit.pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      await e.rebuildCurrentSource('256', Duration.zero);
      permit.allow = true;
      permit.pending!.complete();
      await pumpEventQueue();
      expect(seeded, hasLength(1));
      expect(removed, [0]);
      expect(inserted.single.$1, 0);
      expect(_uri(inserted.single.$2).queryParameters['quality'], '256');
    });

    test('a download finishing replaces the native stream by the file',
        () async {
      permit.pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      await e.refreshLoadedSourcesForAvailabilityChanges(
          [_entry(2, filePath: '/dl/u2.m4a')]);
      permit.allow = true;
      permit.pending!.complete();
      await pumpEventQueue();
      expect(removed, [1]);
      expect(_uri(inserted.single.$2).scheme, 'file');
    });
  });

  group('the next verification', () {
    // A stream built without the token cannot be playing (the server refuses
    // it), so the current item gets the token too and goes back to its
    // position: e.g. a queue restored during an offline launch, whose
    // current item is a stream, plays once the server is verified.
    test('gives the token to every stream source built without it, the '
        'current item included (back to its position); local files are left '
        'alone', () async {
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed(
          [_entry(1), _entry(2), _entry(3, filePath: '/dl/u3.m4a'), _entry(4)],
          currentItemId: 1);
      await pumpEventQueue();
      expect(seeded.single.any(_tokened), isFalse);

      permit.allow = true;
      await e.refreshWithheldMediaTokens();
      await pumpEventQueue();

      expect(removed.toSet(), {0, 1, 3}, reason: 'items 1, 2 and 4');
      expect(inserted.map((i) => i.$1).toSet(), {0, 1, 3});
      expect(inserted.every((i) => _tokened(i.$2)), isTrue);
      verify(() => player.seek(const Duration(seconds: 42), index: 0))
          .called(1);
    });

    // The Verified edge reaches both the waiting seed and the binding's
    // refresh. Whichever runs first, the native player gets one tokened copy
    // of each source and the refresh does not replace it again.
    test('a refresh while a seed waits for the same verdict: one tokened '
        'copy, no second replacement', () async {
      permit.pending = Completer<void>();
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      expect(seeded, isEmpty);

      permit.allow = true;
      await e.refreshWithheldMediaTokens(); // the binding, first
      permit.pending!.complete(); // then the seed's wait ends
      await pumpEventQueue();

      expect(seeded.single.every(_tokened), isTrue);
      expect(removed, isEmpty, reason: 'nothing applied needed replacing');
      expect(inserted, isEmpty);

      await e.refreshWithheldMediaTokens(); // a later verification
      await pumpEventQueue();
      expect(inserted, isEmpty);

      // The issued and applied sources agree: a quality rebuild of the
      // current item finds its native source (by its plugin source).
      await e.rebuildCurrentSource('256', Duration.zero);
      await pumpEventQueue();
      expect(removed, [0]);
      expect(inserted.single.$1, 0);
      expect(_tokened(inserted.single.$2), isTrue);

      // ...and a download that finishes for item 2 replaces its native
      // stream by the file.
      removed.clear();
      inserted.clear();
      await e.refreshLoadedSourcesForAvailabilityChanges(
          [_entry(2, filePath: '/dl/u2.m4a')]);
      await pumpEventQueue();
      expect(removed, [1]);
      expect(_uri(inserted.single.$2).scheme, 'file');
    });

    // Review r1 F7: after a source error the plugin needs a reset stop
    // before a replaced current item can start (as a new seed does).
    test('a current item whose load failed is reset (stop) before its '
        'replacement', () async {
      when(() => player.setAudioSources(any(),
              initialIndex: any(named: 'initialIndex'),
              initialPosition: any(named: 'initialPosition')))
          .thenThrow(ja.PlayerException(401, 'unauthorized', 0));
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1)], currentItemId: 1);
      await pumpEventQueue();
      expect(stops, 0);

      permit.allow = true;
      await e.refreshWithheldMediaTokens();
      await pumpEventQueue();
      expect(stops, 1);
      expect(removed, [0]);
      expect(_tokened(inserted.single.$2), isTrue);
    });

    test('nothing to do when every stream source has the token', () async {
      permit.allow = true;
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      await e.refreshWithheldMediaTokens();
      await pumpEventQueue();
      expect(removed, isEmpty);
      expect(inserted, isEmpty);
    });

    test('still refused: nothing changes', () async {
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2)], currentItemId: 1);
      await pumpEventQueue();
      await e.refreshWithheldMediaTokens();
      await pumpEventQueue();
      expect(inserted, isEmpty);
    });
  });

  group('releasing tokened sources', () {
    test('everything (a different server): every stream source, the current '
        'one included and back to its position, loses the token; local files '
        'are left alone; the engine does not stop itself', () async {
      permit.allow = true;
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed(
          [_entry(1), _entry(2, filePath: '/dl/u2.m4a'), _entry(3)],
          currentItemId: 1);
      await pumpEventQueue();
      expect(_tokened(seeded.single[0]), isTrue);

      permit.allow = false;
      await e.releaseRemoteSources(includeCurrent: true);
      await pumpEventQueue();

      expect(stops, 0, reason: 'the queue player stops, in its lane');
      expect(removed.toSet(), {0, 2});
      expect(inserted.map((i) => i.$1).toSet(), {0, 2});
      expect(inserted.any((i) => _tokened(i.$2)), isFalse);
      verify(() => player.seek(const Duration(seconds: 42), index: 0))
          .called(1);
    });

    test('ahead only (a failed check): the current item keeps its source',
        () async {
      permit.allow = true;
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1), _entry(2), _entry(3)], currentItemId: 1);
      await pumpEventQueue();
      permit.allow = false;
      await e.releaseRemoteSources(includeCurrent: false);
      await pumpEventQueue();
      expect(removed.toSet(), {1, 2});
      expect(inserted.any((i) => _tokened(i.$2)), isFalse);

      // ...and the next verification gives them the token back.
      removed.clear();
      inserted.clear();
      permit.allow = true;
      await e.refreshWithheldMediaTokens();
      await pumpEventQueue();
      expect(removed.toSet(), {1, 2});
      expect(inserted.every((i) => _tokened(i.$2)), isTrue);
    });

    test('a local current item keeps playing (no stop); the stream sources '
        'lose the token', () async {
      permit.allow = true;
      final e = engine(mediaTokenPermit: permit);
      await e.setSeed([_entry(1, filePath: '/dl/u1.m4a'), _entry(2)],
          currentItemId: 1);
      await pumpEventQueue();
      permit.allow = false;
      await e.releaseRemoteSources(includeCurrent: true);
      await pumpEventQueue();
      expect(stops, 0);
      expect(removed, [1]);
      expect(inserted.single.$1, 1);
      expect(_tokened(inserted.single.$2), isFalse);
    });
  });

  // Review r1 F4/F5: what the queue player does in its lane for each gate
  // state.
  group('the gate state to the engine', () {
    test('Verified refreshes, a different server releases everything, a '
        'failed check / signed out / no session release what is ahead; a '
        'pending verdict does nothing', () {
      expect(mediaTokenActionFor(const BindingVerified(token: 't', instanceId: 'i')),
          MediaTokenAction.refresh);
      expect(
          mediaTokenActionFor(const BindingDifferentServer(
              boundInstanceId: 'a', serverInstanceId: 'b')),
          MediaTokenAction.releaseAll);
      for (final s in <BindingGateState>[
        BindingUnverified(StateError('x')),
        const BindingSignedOut(),
        const BindingNoSession(),
      ]) {
        expect(mediaTokenActionFor(s), MediaTokenAction.releaseAhead,
            reason: '$s');
      }
      for (final s in <BindingGateState>[
        const BindingIdle(),
        const BindingVerifying(),
      ]) {
        expect(mediaTokenActionFor(s), MediaTokenAction.none, reason: '$s');
      }
    });

    test('streams count as unavailable (like offline) while offline or '
        'while the check failed; not while a verdict is pending', () {
      expect(remoteStreamsUnavailable(offline: true, gate: const BindingIdle()),
          isTrue);
      expect(
          remoteStreamsUnavailable(
              offline: false, gate: BindingUnverified(StateError('x'))),
          isTrue);
      for (final gate in <BindingGateState>[
        const BindingIdle(),
        const BindingVerifying(),
        const BindingVerified(token: 't', instanceId: 'i'),
      ]) {
        expect(remoteStreamsUnavailable(offline: false, gate: gate), isFalse,
            reason: '$gate');
      }
    });

    // Review r1 F3/F11: the one predicate the engine, the queue player and
    // the playback requests read.
    test('streamsUnavailableProvider reads the offline flag and the gate',
        () {
      final gate = _StateGate(const BindingVerified(token: 't', instanceId: 'i'));
      final c = ProviderContainer(overrides: [
        serverBindingGateProvider.overrideWithValue(gate),
      ]);
      addTearDown(c.dispose);
      final unavailable = c.read(streamsUnavailableProvider);
      expect(unavailable(), isFalse);
      gate.current = BindingUnverified(StateError('x'));
      expect(unavailable(), isTrue);
      gate.current = const BindingVerifying();
      expect(unavailable(), isFalse);
      c.read(offlineModeProvider.notifier)
        ..enterOffline()
        ..cancelOfflinePolling();
      expect(unavailable(), isTrue);
    });
  });
}

class _StateGate extends Fake implements ServerBindingGate {
  _StateGate(this.current);
  BindingGateState current;
  @override
  BindingGateState get state => current;
}
