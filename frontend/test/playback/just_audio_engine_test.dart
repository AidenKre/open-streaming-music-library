import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/api/token_permit.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/local_source_policy.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/playback/playback_target_resolver.dart'
    show PlaybackSourceKind;
import 'package:frontend/repositories/queue_repository.dart';

class MockAudioPlayer extends Mock implements ja.AudioPlayer {}

class FakeAudioSource extends Fake implements ja.AudioSource {}

/// Fixture: the media token is allowed (sign-off OPEN-M-11 step D).
class _AllowAll implements TokenPermit {
  @override
  bool allowsTokenTo(Uri url) => true;
  @override
  Future<void> verdictSettled() async {}
}

void main() {
  late MockAudioPlayer player;
  late StreamController<int?> currentIndexController;
  late StreamController<ja.PositionDiscontinuity> discontinuityController;
  late StreamController<ja.PlayerException> errorController;
  late int currentIndex;
  JustAudioEngine? controller;

  setUpAll(() {
    registerFallbackValue(FakeAudioSource());
    registerFallbackValue(Duration.zero);
    registerFallbackValue(ja.LoopMode.off);
  });

  setUp(() {
    player = MockAudioPlayer();
    currentIndexController = StreamController<int?>.broadcast();
    discontinuityController =
        StreamController<ja.PositionDiscontinuity>.broadcast();
    currentIndex = 0;
    when(() => player.positionDiscontinuityStream)
        .thenAnswer((_) => discontinuityController.stream);
    when(() => player.playing).thenReturn(false);
    when(() => player.processingState).thenReturn(ja.ProcessingState.ready);
    when(() => player.duration).thenReturn(null);
    when(() => player.speed).thenReturn(1.0);
    errorController = StreamController<ja.PlayerException>.broadcast();
    when(() => player.errorStream).thenAnswer((_) => errorController.stream);
    when(
      () => player.setAudioSources(
        any(),
        initialIndex: any(named: 'initialIndex'),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).thenAnswer((invocation) async {
      // Like the plugin: the seeded initial index becomes current.
      currentIndex = invocation.namedArguments[#initialIndex] as int? ?? 0;
      return const Duration(minutes: 3);
    });
    when(
      () => player.seek(any(), index: any(named: 'index')),
    ).thenAnswer((invocation) async {
      final index = invocation.namedArguments[#index] as int?;
      if (index != null) currentIndex = index;
    });
    when(() => player.pause()).thenAnswer((_) async {});
    when(() => player.stop()).thenAnswer((_) async {});
    when(() => player.setVolume(any())).thenAnswer((_) async {});
    when(() => player.setLoopMode(any())).thenAnswer((_) async {});
    when(() => player.insertAudioSource(any(), any())).thenAnswer((_) async {});
    when(() => player.removeAudioSourceAt(any())).thenAnswer((_) async {});
    when(() => player.dispose()).thenAnswer((_) async {});
    when(() => player.currentIndex).thenAnswer((_) => currentIndex);
    when(() => player.position).thenReturn(Duration.zero);
    when(
      () => player.playerStateStream,
    ).thenAnswer((_) => const Stream.empty());
    when(() => player.positionStream).thenAnswer((_) => const Stream.empty());
    when(() => player.durationStream).thenAnswer((_) => const Stream.empty());
    when(
      () => player.currentIndexStream,
    ).thenAnswer((_) => currentIndexController.stream);

    controller = JustAudioEngine(player);
  });

  tearDown(() {
    controller?.dispose();
    currentIndexController.close();
    discontinuityController.close();
    errorController.close();
  });

  test(
    'setSeed completes even when underlying play future remains pending',
    () async {
      final playCompleter = Completer<void>();
      when(() => player.play()).thenAnswer((_) => playCompleter.future);

      await expectLater(
        controller!.setSeed(
          [_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1,
          autoPlay: true,
        ),
        completes,
      );
      await pumpEventQueue();

      verify(
        () => player.setAudioSources(
          any(),
          initialIndex: 0,
          initialPosition: Duration.zero,
        ),
      ).called(1);
      verify(() => player.play()).called(1);
    },
  );

  test(
    'play returns immediately even when underlying play future is pending',
    () async {
      final playCompleter = Completer<void>();
      when(() => player.play()).thenAnswer((_) => playCompleter.future);

      await expectLater(controller!.play(), completes);
      await pumpEventQueue();

      verify(() => player.play()).called(1);
    },
  );

  test(
    'replaceFutureEntries removes only items after the current item',
    () async {
      when(() => player.play()).thenAnswer((_) async {});

      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 2);

      currentIndex = 1;

      await controller!.replaceFutureEntries(
        currentItemId: 2,
        entries: [
          _entry(itemId: 4, playPosition: 2),
          _entry(itemId: 5, playPosition: 3),
        ],
      );
      await pumpEventQueue();

      verify(() => player.removeAudioSourceAt(2)).called(1);
      verify(() => player.insertAudioSource(2, any())).called(1);
      verify(() => player.insertAudioSource(3, any())).called(1);
      expect(controller!.loadedItemIds, [1, 2, 4, 5]);
      expect(controller!.currentItemId, 2);
    },
  );

  test(
    'rebuildAroundCurrent suppresses transient current-item churn',
    () async {
      final emittedItemIds = <int?>[];
      final sub = controller!.currentItemIdStream.listen(emittedItemIds.add);

      // Like the plugin: edits before the playing source shift its index,
      // and each shift is reported.
      when(() => player.removeAudioSourceAt(any())).thenAnswer((invocation) async {
        final index = invocation.positionalArguments[0] as int;
        if (index < currentIndex) currentIndex--;
        currentIndexController.add(currentIndex);
      });
      when(() => player.insertAudioSource(any(), any())).thenAnswer((invocation) async {
        final index = invocation.positionalArguments[0] as int;
        if (index <= currentIndex) currentIndex++;
        currentIndexController.add(currentIndex);
      });

      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 2);
      await pumpEventQueue();

      emittedItemIds.clear();
      await controller!.rebuildAroundCurrent(
        currentItemId: 2,
        entries: [
          _entry(itemId: 1, playPosition: 0),
          _entry(itemId: 4, playPosition: 1),
          _entry(itemId: 2, playPosition: 2),
          _entry(itemId: 5, playPosition: 3),
        ],
      );
      await pumpEventQueue();

      expect(emittedItemIds, isEmpty);
      expect(controller!.currentItemId, 2);

      currentIndex = 3;
      currentIndexController.add(3);
      await Future<void>.delayed(Duration.zero);

      expect(emittedItemIds, [5]);
      await sub.cancel();
    },
  );

  group('5B.0c: command issuance vs. completion (SC-27 invariant 3)', () {
    late Completer<Duration?> load;

    setUp(() {
      load = Completer<Duration?>();
      when(() => player.play()).thenAnswer((_) => Completer<void>().future);
      when(
        () => player.setAudioSources(
          any(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).thenAnswer((invocation) {
        currentIndex = invocation.namedArguments[#initialIndex] as int? ?? 0;
        return load.future;
      });
    });

    List<QueuePlaybackEntry> seed() => [
          _entry(itemId: 1, playPosition: 5),
          _entry(itemId: 2, playPosition: 6),
          _entry(itemId: 3, playPosition: 7),
        ];

    Future<bool> returned(Future<void> command) async {
      var done = false;
      unawaited(command.then((_) => done = true));
      await pumpEventQueue();
      return done;
    }

    test('setSeed returns while the load is stalled; the load reports later',
        () async {
      final events = <EngineLoadEvent>[];
      final sub = controller!.loadEvents.listen(events.add);
      expect(await returned(controller!.setSeed(seed(), currentItemId: 2)),
          isTrue, reason: 'the lane must not wait for the load');
      expect(events, isEmpty);
      load.complete(const Duration(minutes: 3));
      await pumpEventQueue();
      expect(events.single.outcome, EngineLoadOutcome.loaded);
      expect(events.single.duration, const Duration(minutes: 3));
      expect(events.single.playlistRevision, controller!.playlistRevision);
      await sub.cancel();
    });

    test('a failed load is reported, never thrown into the lane', () async {
      final events = <EngineLoadEvent>[];
      final sub = controller!.loadEvents.listen(events.add);
      expect(await returned(controller!.setSeed(seed(), currentItemId: 2)),
          isTrue);
      load.completeError(ja.PlayerException(7, 'boom', 1));
      await pumpEventQueue();
      expect(events.single.outcome, EngineLoadOutcome.failed);
      expect(events.single.errorCode, 7);
      expect(events.single.errorMessage, 'boom');
      await sub.cancel();
    });

    test('pause and stop reach the player while a load is stalled', () async {
      when(() => player.pause()).thenAnswer((_) => Completer<void>().future);
      when(() => player.stop()).thenAnswer((_) => Completer<void>().future);
      expect(await returned(
          controller!.setSeed(seed(), currentItemId: 2, autoPlay: true)), isTrue);
      expect(await returned(controller!.pause()), isTrue);
      verify(() => player.pause()).called(1);
      expect(await returned(controller!.stop()), isTrue);
      verify(() => player.stop()).called(1);
    });

    test('edits during a stalled load return at once and apply after it',
        () async {
      final calls = <String>[];
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((invocation) async {
        calls.add('insert@${invocation.positionalArguments[0]}');
      });
      expect(await returned(controller!.setSeed(seed(), currentItemId: 2)),
          isTrue);
      expect(
        await returned(
            controller!.addEntries([_entry(itemId: 4, playPosition: 8)])),
        isTrue,
      );
      expect(controller!.loadedItemIds, [1, 2, 3, 4],
          reason: 'the engine model reflects the issued edit');
      expect(calls, isEmpty, reason: 'native work waits for the load');
      load.complete(null);
      await pumpEventQueue();
      expect(calls, ['insert@3']);
    });

    test('a play issued before a later pause never starts audio', () async {
      expect(await returned(controller!.setSeed(seed(), currentItemId: 2)),
          isTrue);
      expect(await returned(controller!.play()), isTrue);
      expect(await returned(controller!.pause()), isTrue);
      load.complete(null);
      await pumpEventQueue();
      verifyNever(() => player.play());
    });

    test('a replacement seed does not wait behind a stalled one', () async {
      expect(await returned(controller!.setSeed(seed(), currentItemId: 2)),
          isTrue);
      expect(
          await returned(
              controller!.addEntries([_entry(itemId: 4, playPosition: 8)])),
          isTrue);
      final second = Completer<Duration?>();
      when(
        () => player.setAudioSources(
          any(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).thenAnswer((_) => second.future);
      final events = <EngineLoadEvent>[];
      final sub = controller!.loadEvents.listen(events.add);
      expect(
        await returned(controller!.setSeed(
            [_entry(itemId: 9, playPosition: 0)],
            currentItemId: 9)),
        isTrue,
      );
      verify(
        () => player.setAudioSources(
          any(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).called(2);
      expect(controller!.loadedItemIds, [9]);
      final inserted = <int>[];
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((invocation) async {
        inserted.add(invocation.positionalArguments[0] as int);
      });
      await controller!.addEntries([_entry(itemId: 10, playPosition: 1)]);
      second.complete(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(inserted, [1],
          reason: 'work of the new seed does not wait for the old load');
      load.complete(null);
      await pumpEventQueue();
      expect(inserted, [1], reason: "the old seed's queued insert is dropped");
      expect(events.map((e) => e.outcome),
          [EngineLoadOutcome.loaded, EngineLoadOutcome.superseded]);
      await sub.cancel();
    });

    test('seekToItem targets the index after earlier inserts apply', () async {
      load.complete(null);
      await controller!.setSeed(seed(), currentItemId: 2);
      await pumpEventQueue();
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      expect(
          await returned(
              controller!.addEntries([_entry(itemId: 0, playPosition: 1)])),
          isTrue);
      expect(await returned(controller!.seekToItem(3)), isTrue);
      verifyNever(() => player.seek(any(), index: any(named: 'index')));
      insert.complete();
      await pumpEventQueue();
      verify(() => player.seek(Duration.zero, index: 3)).called(1);
    });

    test('an edit after a reorder inserts at the reordered position',
        () async {
      load.complete(null);
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 2);
      await pumpEventQueue();
      final inserted = <int>[];
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((invocation) async {
        inserted.add(invocation.positionalArguments[0] as int);
      });
      // A manual edit renumbers play positions; item 3 now plays later.
      controller!.replaceLoadedEntriesMetadata([
        _entry(itemId: 3, playPosition: 9),
      ]);
      await controller!.addEntries([_entry(itemId: 4, playPosition: 5)]);
      await pumpEventQueue();
      expect(controller!.loadedItemIds, [1, 2, 4, 3]);
      expect(inserted, [2], reason: 'native order matches the issued order');
    });

    test('a download flip rebuilds only that source, in place', () async {
      load.complete(null);
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, filePath: '/a'),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 1);
      await pumpEventQueue();
      final calls = <String>[];
      when(() => player.removeAudioSourceAt(any())).thenAnswer((i) async {
        calls.add('remove@${i.positionalArguments[0]}');
      });
      when(() => player.insertAudioSource(any(), any())).thenAnswer((i) async {
        calls.add('insert@${i.positionalArguments[0]}');
      });
      await controller!.refreshLoadedSourcesForAvailabilityChanges([
        _entry(itemId: 2, playPosition: 1, filePath: '/b'),
        _entry(itemId: 3, playPosition: 2),
      ]);
      await pumpEventQueue();
      expect(calls, ['remove@1', 'insert@1']);
      expect(controller!.loadedItemIds, [1, 2, 3]);
    });

    // Review major 1: a download suspected after a failure streams, even
    // though its entry still records the file, until playback resolves it.
    test('a suspected download is rebuilt as the stream and stays one',
        () async {
      final policy = LocalSourcePolicy();
      final engine = JustAudioEngine(player, localSources: policy);
      addTearDown(engine.dispose);
      load.complete(null);
      final seed = [
        _entry(itemId: 1, playPosition: 0, uuidId: 'a', filePath: '/a'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'b'),
      ];
      await engine.setSeed(seed, currentItemId: 1);
      await pumpEventQueue();
      final failures = <EngineSourceFailure>[];
      final sub = engine.sourceFailures.listen(failures.add);
      final calls = <String>[];
      when(() => player.removeAudioSourceAt(any())).thenAnswer((i) async {
        calls.add('remove@${i.positionalArguments[0]}');
      });
      when(() => player.insertAudioSource(any(), any())).thenAnswer((i) async {
        calls.add('insert@${i.positionalArguments[0]}');
      });
      policy.suspect('a', '/a');
      await engine.refreshLoadedSourcesForAvailabilityChanges(seed);
      await pumpEventQueue();
      expect(calls, ['remove@0', 'insert@0'],
          reason: 'the same entry, now a stream');
      await engine.refreshLoadedSourcesForAvailabilityChanges(seed);
      await pumpEventQueue();
      expect(calls, hasLength(2), reason: 'already a stream: no rebuild');
      errorController.add(ja.PlayerException(0, 'x', 0));
      await pumpEventQueue();
      expect(failures.single.source?.localPath, isNull,
          reason: 'its failure is a stream failure');
      await sub.cancel();
    });

    test('offline, a vanished current file is handed to the rescue',
        () async {
      final offline = JustAudioEngine(player, isOfflineFn: () => true);
      addTearDown(offline.dispose);
      load.complete(null);
      await offline.setSeed([
        _entry(itemId: 1, playPosition: 0, filePath: '/a'),
        _entry(itemId: 2, playPosition: 1, filePath: '/b'),
      ], currentItemId: 1);
      await pumpEventQueue();
      final rescues = <int>[];
      final sub = offline.unavailableAdvanceStream
          .listen((event) => rescues.add(event.itemId));
      await offline.refreshLoadedSourcesForAvailabilityChanges([
        _entry(itemId: 1, playPosition: 0),
      ]);
      await pumpEventQueue();
      expect(rescues, [1]);
      verifyNever(() => player.removeAudioSourceAt(any()));
      // Its metadata changed (no file): an index event onto it is unplayable.
      currentIndexController.add(0);
      await pumpEventQueue();
      expect(rescues, [1, 1]);
      await sub.cancel();
    });

    test('a seek resolves its index against what the plugin has applied',
        () async {
      load.complete(null);
      await controller!.setSeed(seed(), currentItemId: 2);
      await pumpEventQueue();
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      // Issued back to back: the seek runs before the insert is applied.
      unawaited(controller!.seekToItem(3));
      unawaited(controller!.addEntries([_entry(itemId: 0, playPosition: 1)]));
      await pumpEventQueue();
      verify(() => player.seek(Duration.zero, index: 2)).called(1);
      insert.complete();
    });
  });

  group('5B.0c: observation provenance (SC-27 invariant 6)', () {
    late List<PlaybackObservation> seen;
    late StreamSubscription<PlaybackObservation> sub;

    setUp(() {
      when(() => player.play()).thenAnswer((_) async {});
      seen = [];
      sub = controller!.observations.listen(seen.add);
    });

    tearDown(() => sub.cancel());

    List<QueuePlaybackEntry> seed() => [
          _entry(itemId: 1, playPosition: 5, uuidId: 'u1'),
          _entry(itemId: 2, playPosition: 6, uuidId: 'u2'),
          _entry(itemId: 3, playPosition: 7, uuidId: 'u3'),
        ];

    Future<void> seeded() async {
      await controller!.setSeed(seed(), currentItemId: 2, sessionId: 7);
      await pumpEventQueue();
    }

    test('an applied seed settles on its current source', () async {
      await seeded();
      final settled = seen.last;
      expect(settled.uncertain, isFalse);
      expect(settled.source?.itemId, 2);
      expect(settled.source?.trackUuid, 'u2');
      expect(settled.source?.sessionId, 7);
      expect(settled.transitionCause, PlaybackTransitionCause.queueReplacement);
      expect(settled.playlistRevision, controller!.playlistRevision);
      expect(settled.runtimeId, controller!.runtimeId);
      expect(settled.duration, isNull, reason: 'unknown is not zero');
      expect(settled.rate, 1.0);
    });

    test('an insert before the current item never misattributes', () async {
      await seeded();
      final playing = seen.last.source!;
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      await controller!.addEntries([_entry(itemId: 0, playPosition: 1)]);
      seen.clear();
      // The plugin's index already counts the insert; its sequence may not.
      currentIndex = 2;
      currentIndexController.add(2);
      await pumpEventQueue();
      expect(seen.single.uncertain, isTrue);
      expect(seen.single.source, playing);
      insert.complete();
      await pumpEventQueue();
      final settled = seen.last;
      expect(settled.uncertain, isFalse);
      expect(settled.source, playing);
      expect(settled.transitionCause, PlaybackTransitionCause.queueEdit);
      expect(settled.playlistRevision, controller!.playlistRevision);
      currentIndexController.add(2);
      await pumpEventQueue();
      expect(seen.last.source, playing);
      expect(seen.where((o) => !o.uncertain && o.source?.itemId == 3),
          isEmpty);
    });

    test('an advance during an edit settles on the new item', () async {
      final items = <int?>[];
      final itemSub = controller!.currentItemIdStream.listen(items.add);
      await seeded();
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      await controller!.addEntries([_entry(itemId: 0, playPosition: 1)]);
      // The plugin finishes item 2 and moves on while the insert is pending.
      currentIndex = 3;
      currentIndexController.add(3);
      await pumpEventQueue();
      expect(items, isEmpty, reason: 'not trusted while pending');
      insert.complete();
      await pumpEventQueue();
      expect(seen.last.source?.itemId, 3);
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.transitionCause, PlaybackTransitionCause.naturalAdvance);
      expect(items, [3]);
      await itemSub.cancel();
    });

    test('every created source has its own id; metadata keeps it', () async {
      await seeded();
      final first = seen.last.source!.sourceId;
      controller!.replaceLoadedEntriesMetadata(
          [_entry(itemId: 2, playPosition: 6, uuidId: 'u2')]);
      currentIndexController.add(1);
      await pumpEventQueue();
      expect(seen.last.source?.sourceId, first,
          reason: 'a metadata update keeps the created source');
      await controller!.rebuildCurrentSource('low', Duration.zero);
      await pumpEventQueue();
      final rebuilt = seen.last;
      expect(rebuilt.transitionCause, PlaybackTransitionCause.qualityRebuild);
      expect(rebuilt.source?.itemId, 2);
      expect(rebuilt.source?.sourceId, isNot(first));
    });

    test('a seed rejected for a missing current item keeps the session '
        'identity of the applied seed', () async {
      await seeded();
      await expectLater(
          controller!.setSeed(seed(), currentItemId: 99, sessionId: 9),
          throwsStateError);
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      await controller!.seekToItem(4);
      await pumpEventQueue();
      expect(seen.last.source?.itemId, 4);
      expect(seen.last.source?.sessionId, 7);
    });

    test('seeks settle on their target with the command cause', () async {
      final items = <int?>[];
      final itemSub = controller!.currentItemIdStream.listen(items.add);
      await seeded();
      await controller!.seekToItem(3);
      await pumpEventQueue();
      expect(seen.last.source?.itemId, 3);
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.transitionCause, PlaybackTransitionCause.userSkip);
      expect(items, [3]);
      await controller!.seek(const Duration(seconds: 10));
      await pumpEventQueue();
      expect(seen.last.source?.itemId, 3);
      expect(seen.last.transitionCause, PlaybackTransitionCause.userSeek);
      await controller!.seekToItem(2,
          cause: PlaybackTransitionCause.naturalAdvance);
      await pumpEventQueue();
      expect(seen.last.transitionCause, PlaybackTransitionCause.naturalAdvance);
      await itemSub.cancel();
    });

    test('auto-advance: a new source is natural, the same one a loop',
        () async {
      await seeded();
      ja.PlaybackEvent at(int index) => ja.PlaybackEvent(currentIndex: index);
      discontinuityController.add(ja.PositionDiscontinuity(
          ja.PositionDiscontinuityReason.autoAdvance, at(1), at(2)));
      await pumpEventQueue();
      expect(seen.last.transitionCause, PlaybackTransitionCause.naturalAdvance);
      expect(seen.last.source?.itemId, 3);
      discontinuityController.add(ja.PositionDiscontinuity(
          ja.PositionDiscontinuityReason.autoAdvance, at(2), at(2)));
      await pumpEventQueue();
      expect(seen.last.transitionCause,
          PlaybackTransitionCause.repeatOneRestart);
      expect(seen.last.source?.itemId, 3);
    });

    test('observations are ordered and name their runtime', () async {
      await seeded();
      currentIndexController.add(2);
      await controller!.seek(Duration.zero);
      await pumpEventQueue();
      final sequences = seen.map((o) => o.sequence).toList();
      expect(sequences.length, greaterThanOrEqualTo(3));
      for (var i = 1; i < sequences.length; i++) {
        expect(sequences[i], greaterThan(sequences[i - 1]));
      }
      final other = JustAudioEngine(player);
      expect(other.runtimeId, isNot(controller!.runtimeId));
      other.dispose();
    });
  });

  group('5B.0c: audio focus at the single play() (SC-27 invariant 5)', () {
    test('play waits for focus and is skipped when denied', () async {
      when(() => player.play()).thenAnswer((_) async {});
      var granted = false;
      final gated = JustAudioEngine(player, beforePlay: () async => granted);
      addTearDown(gated.dispose);
      await gated.play();
      await pumpEventQueue();
      verifyNever(() => player.play());
      granted = true;
      await gated.play();
      await pumpEventQueue();
      verify(() => player.play()).called(1);
    });

    test('the production player is built with plugin interruptions off',
        () {
      bool? captured;
      final engine = JustAudioEngine.create(
        newPlayer: ({required bool handleInterruptions}) {
          captured = handleInterruptions;
          return player;
        },
      );
      addTearDown(engine.dispose);
      expect(captured, isFalse);
    });
  });

  group('5B.0c audit (a) regressions', () {
    setUp(() => when(() => player.play()).thenAnswer((_) async {}));

    test('M1: work of an old seed stops at its next step after a new seed',
        () async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
      ], currentItemId: 1);
      await pumpEventQueue();
      final first = Completer<void>();
      final inserted = <int>[];
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((invocation) async {
        inserted.add(invocation.positionalArguments[0] as int);
        if (inserted.length == 1) await first.future;
      });
      await controller!.addEntries([
        _entry(itemId: 3, playPosition: 2),
        _entry(itemId: 4, playPosition: 3),
      ]);
      await pumpEventQueue();
      expect(inserted, [2], reason: 'the first insert is in flight');
      await controller!.setSeed([
        _entry(itemId: 10, playPosition: 0),
        _entry(itemId: 11, playPosition: 1),
        _entry(itemId: 12, playPosition: 2),
      ], currentItemId: 10);
      first.complete();
      await pumpEventQueue();
      expect(inserted, [2], reason: "the old seed's next insert is dropped");
      final items = <int?>[];
      final sub = controller!.currentItemIdStream.listen(items.add);
      // 7P.1: the next item (an explained advance); on the old seed index 1
      // would have named item 2.
      currentIndex = 1;
      currentIndexController.add(1);
      await pumpEventQueue();
      expect(items, [11], reason: 'indices map onto the new seed only');
      await sub.cancel();
    });

    test('M2: a refresh puts its rebuilt sources into the issued model',
        () async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
      ], currentItemId: 1);
      await pumpEventQueue();
      final calls = <String>[];
      when(() => player.removeAudioSourceAt(any())).thenAnswer((i) async {
        calls.add('remove@${i.positionalArguments[0]}');
      });
      when(() => player.insertAudioSource(any(), any())).thenAnswer((i) async {
        calls.add('insert@${i.positionalArguments[0]}');
      });
      final downloaded = [
        _entry(itemId: 1, playPosition: 0, filePath: '/a'),
        _entry(itemId: 2, playPosition: 1),
      ];
      await controller!.refreshLoadedSourcesForAvailabilityChanges(downloaded);
      await pumpEventQueue();
      expect(calls, ['remove@0', 'insert@0']);
      calls.clear();
      await controller!.refreshLoadedSourcesForAvailabilityChanges(downloaded);
      await pumpEventQueue();
      expect(calls, isEmpty, reason: 'nothing changed the second time');
      clearInteractions(player);
      await controller!.rebuildCurrentSource('low', Duration.zero);
      await pumpEventQueue();
      expect(calls, ['remove@0', 'insert@0'],
          reason: 'the current source is found and rebuilt');
    });

    test('M3: desired play is reported while an autoPlay load is pending',
        () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      when(
        () => player.setAudioSources(any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition')),
      ).thenAnswer((_) => Completer<Duration?>().future);
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, autoPlay: true);
      // The plugin is not playing yet: play() waits behind the load.
      states.add(ja.PlayerState(false, ja.ProcessingState.loading));
      await pumpEventQueue();
      expect(seen.last,
          const EngineTransportState(true, EngineProcessingState.loading));
      // The plugin emits nothing for a pause before it ever played; the
      // engine reports its own desired change.
      await engine.pause();
      await pumpEventQueue();
      expect(seen.last,
          const EngineTransportState(false, EngineProcessingState.loading));
      await sub.cancel();
    });

    test('follow-up: a shuffle rebuild keeps the native order for later adds',
        () async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 2);
      await pumpEventQueue();
      await controller!.rebuildAroundCurrent(currentItemId: 2, entries: [
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 4, playPosition: 1),
        _entry(itemId: 2, playPosition: 5),
        _entry(itemId: 5, playPosition: 6),
      ]);
      await pumpEventQueue();
      final inserted = <int>[];
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((invocation) async {
        inserted.add(invocation.positionalArguments[0] as int);
      });
      await controller!.addEntries([_entry(itemId: 6, playPosition: 3)]);
      await pumpEventQueue();
      expect(controller!.loadedItemIds, [1, 4, 6, 2, 5]);
      expect(inserted, [2], reason: 'before the current at its new position');
    });

    test('round 3: metadata changed during a pending seed load survives it',
        () async {
      final load = Completer<Duration?>();
      when(
        () => player.setAudioSources(any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition')),
      ).thenAnswer((invocation) {
        currentIndex = invocation.namedArguments[#initialIndex] as int? ?? 0;
        return load.future;
      });
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 2);
      await controller!.rebuildAroundCurrent(currentItemId: 2, entries: [
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 4, playPosition: 1),
        _entry(itemId: 2, playPosition: 5),
        _entry(itemId: 5, playPosition: 6),
      ]);
      final inserted = <int>[];
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((invocation) async {
        inserted.add(invocation.positionalArguments[0] as int);
      });
      load.complete(null);
      await pumpEventQueue();
      inserted.clear();
      await controller!.addEntries([_entry(itemId: 7, playPosition: 3)]);
      await pumpEventQueue();
      expect(controller!.loadedItemIds, [1, 4, 7, 2, 5]);
      expect(inserted, [2]);
    });

    test('round 3: a play dropped by a newer seed leaves no desired play',
        () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      final load = Completer<Duration?>();
      when(
        () => player.setAudioSources(any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition')),
      ).thenAnswer((_) => load.future);
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, autoPlay: true);
      await engine.setSeed([_entry(itemId: 2, playPosition: 0)],
          currentItemId: 2);
      load.complete(null);
      states.add(ja.PlayerState(false, ja.ProcessingState.ready));
      await pumpEventQueue();
      verifyNever(() => player.play());
      expect(seen.last.playing, isFalse);
      await sub.cancel();
    });

    test('round 3: a stale focus refusal cannot cancel a newer play',
        () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      when(() => player.playing).thenReturn(true);
      final firstVerdict = Completer<bool>();
      var asks = 0;
      final engine = JustAudioEngine(player,
          beforePlay: () => ++asks == 1 ? firstVerdict.future : Future.value(true));
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1);
      await engine.play();
      await pumpEventQueue();
      await engine.setSeed([_entry(itemId: 2, playPosition: 0)],
          currentItemId: 2, autoPlay: true);
      await pumpEventQueue();
      verify(() => player.play()).called(1);
      firstVerdict.complete(false);
      await pumpEventQueue();
      expect(seen.last.playing, isTrue, reason: 'the newer play stands');
      await sub.cancel();
    });

    test('audit (b): raw source failures carry the failing source', () async {
      when(() => player.play()).thenAnswer((_) async {});
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'u2'),
      ], currentItemId: 1, sessionId: 4);
      await pumpEventQueue();
      final failures = <EngineSourceFailure>[];
      final sub = controller!.sourceFailures.listen(failures.add);
      errorController.add(ja.PlayerException(404, 'not found', 1));
      await pumpEventQueue();
      expect(failures.single.source?.itemId, 2);
      expect(failures.single.source?.trackUuid, 'u2');
      expect(failures.single.source?.sessionId, 4);
      expect(failures.single.uncertain, isFalse);
      expect(failures.single.errorCode, 404);
      expect(failures.single.errorMessage, 'not found');
      expect(failures.single.playlistRevision, controller!.playlistRevision);
      // While an edit is being applied the index may name the old playlist.
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      await controller!.addEntries([_entry(itemId: 0, playPosition: -1)]);
      errorController.add(ja.PlayerException(404, 'not found', 1));
      await pumpEventQueue();
      expect(failures.last.uncertain, isTrue);
      expect(failures.last.source, isNull);
      insert.complete();
      await sub.cancel();
    });

    test('branch audit: a failure during a transition is re-reported with '
        'the settled identity when the plugin stopped on it', () async {
      when(() => player.play()).thenAnswer((_) async {});
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'u2'),
      ], currentItemId: 1, sessionId: 4);
      await pumpEventQueue();
      final failures = <EngineSourceFailure>[];
      final sub = controller!.sourceFailures.listen(failures.add);
      for (final stopped in [true, false]) {
        failures.clear();
        final insert = Completer<void>();
        when(() => player.insertAudioSource(any(), any()))
            .thenAnswer((_) => insert.future);
        await controller!.addEntries([_entry(itemId: stopped ? 3 : 4, playPosition: stopped ? 2 : 3)]);
        errorController.add(ja.PlayerException(404, 'not found', 0));
        await pumpEventQueue();
        expect(failures.single.uncertain, isTrue);
        when(() => player.processingState)
            .thenReturn(stopped ? ja.ProcessingState.idle : ja.ProcessingState.ready);
        insert.complete();
        await pumpEventQueue();
        if (stopped) {
          expect(failures, hasLength(2), reason: 'settled: re-reported');
          expect(failures.last.uncertain, isFalse);
          expect(failures.last.source?.itemId, 1, reason: 'the settled current source');
          expect(failures.last.errorCode, 404);
        } else {
          expect(failures, hasLength(1),
              reason: 'the plugin plays on: the failure was not the current source');
        }
      }
      await sub.cancel();
    });

    // Live gate (2026-11-07, macOS): after a source error the plugin sits
    // deactivated (or stuck loading the dead source) with `playing` still
    // true, so neither a seek, a play nor a plain new seed starts the next
    // item. The next seed resets the plugin first.
    test('live gate: the first seed after a source error stops the plugin '
        'first; later seeds do not', () async {
      final calls = <String>[];
      when(() => player.stop()).thenAnswer((_) async => calls.add('stop'));
      when(
        () => player.setAudioSources(
          any(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).thenAnswer((invocation) async {
        calls.add('load');
        currentIndex = invocation.namedArguments[#initialIndex] as int? ?? 0;
        return const Duration(minutes: 3);
      });
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1);
      await pumpEventQueue();
      expect(calls, ['load']);
      errorController.add(ja.PlayerException(-1004, 'cannot connect', 0));
      await pumpEventQueue();
      calls.clear();
      await controller!.setSeed([_entry(itemId: 2, playPosition: 1)],
          currentItemId: 2);
      await pumpEventQueue();
      expect(calls, ['stop', 'load'], reason: 'reset, then load the target');
      calls.clear();
      await controller!.setSeed([_entry(itemId: 3, playPosition: 2)],
          currentItemId: 3);
      await pumpEventQueue();
      expect(calls, ['load'], reason: 'no error since: no reset');
    });

    test('live gate: the reset keeps a desired play (the core plays on)',
        () async {
      when(() => player.stop()).thenAnswer((_) async {});
      when(() => player.play()).thenAnswer((_) async {});
      final seen = <EngineTransportState>[];
      final sub = controller!.transportStateStream.listen(seen.add);
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, autoPlay: true);
      await pumpEventQueue();
      when(() => player.playing).thenReturn(true); // the play was issued
      errorController.add(ja.PlayerException(-1004, 'cannot connect', 0));
      await pumpEventQueue();
      // The recovery re-seeds without autoPlay and plays only if the
      // desired transport is still playing.
      await controller!.setSeed([_entry(itemId: 2, playPosition: 1)],
          currentItemId: 2);
      await pumpEventQueue();
      expect(seen.last.playing, isTrue,
          reason: 'the reset stop is not a dropped or reverted play');
      await sub.cancel();
    });

    // Review (2026-11-07): a held failure belongs to the source the plugin
    // was on; a seek elsewhere, a stop or the seed's own load failure must
    // not re-report it against another item (since decision 6 that could
    // mark a healthy download damaged).
    group('review: a held failure is not blamed on another item', () {
      Future<List<EngineSourceFailure>> holdDuringInsert() async {
        when(() => player.play()).thenAnswer((_) async {});
        await controller!.setSeed([
          _entry(itemId: 1, playPosition: 0, uuidId: 'u1'),
          _entry(itemId: 2, playPosition: 1, uuidId: 'u2'),
        ], currentItemId: 1, sessionId: 4);
        await pumpEventQueue();
        final failures = <EngineSourceFailure>[];
        addTearDown(controller!.sourceFailures.listen(failures.add).cancel);
        return failures;
      }

      test('a seek to another item drops the held failure', () async {
        final failures = await holdDuringInsert();
        final insert = Completer<void>();
        when(() => player.insertAudioSource(any(), any()))
            .thenAnswer((_) => insert.future);
        await controller!.addEntries([_entry(itemId: 3, playPosition: 2)]);
        errorController.add(ja.PlayerException(404, 'not found', 0));
        await pumpEventQueue();
        expect(failures.single.uncertain, isTrue);
        await controller!.seekToItem(2); // the core moves on to item 2
        when(() => player.processingState).thenReturn(ja.ProcessingState.idle);
        insert.complete();
        await pumpEventQueue();
        expect(failures, hasLength(1),
            reason: "item 1's failure is not re-reported as item 2's");
      });

      test('a stop drops the held failure', () async {
        final failures = await holdDuringInsert();
        when(() => player.stop()).thenAnswer((_) async {});
        final insert = Completer<void>();
        when(() => player.insertAudioSource(any(), any()))
            .thenAnswer((_) => insert.future);
        await controller!.addEntries([_entry(itemId: 3, playPosition: 2)]);
        errorController.add(ja.PlayerException(404, 'not found', 0));
        await pumpEventQueue();
        await controller!.stop();
        when(() => player.processingState).thenReturn(ja.ProcessingState.idle);
        insert.complete();
        await pumpEventQueue();
        expect(failures, hasLength(1), reason: 'stopped: nothing to recover');
      });

      test("a seed whose load fails reports it once, as the load event",
          () async {
        final failures = <EngineSourceFailure>[];
        final loads = <EngineLoadEvent>[];
        final subs = [
          controller!.sourceFailures.listen(failures.add),
          controller!.loadEvents.listen(loads.add),
        ];
        when(
          () => player.setAudioSources(
            any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition'),
          ),
        ).thenAnswer((_) async {
          // Like Android: the error reaches the error stream AND fails the
          // load.
          errorController.add(ja.PlayerException(0, 'decode', 0));
          await pumpEventQueue();
          throw ja.PlayerException(0, 'decode', 0);
        });
        when(() => player.processingState).thenReturn(ja.ProcessingState.idle);
        await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
            currentItemId: 1);
        await pumpEventQueue();
        expect(loads.map((e) => e.outcome), [EngineLoadOutcome.failed]);
        expect(failures.where((f) => !f.uncertain), isEmpty,
            reason: 'no second, certain report of the same failure');
        for (final sub in subs) {
          await sub.cancel();
        }
      });
    });

    test('branch audit: a completion while the engine replaces sources is not '
        'the queue end; at settle a real one still is', () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      when(() => player.playing).thenReturn(true);
      when(() => player.pause()).thenAnswer((_) async {});
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, autoPlay: true);
      await pumpEventQueue();
      for (final realEnd in [false, true]) {
        final insert = Completer<void>();
        when(() => player.insertAudioSource(any(), any()))
            .thenAnswer((_) => insert.future);
        await engine.addEntries([_entry(itemId: realEnd ? 3 : 2, playPosition: realEnd ? 2 : 1)]);
        // The native playlist briefly ends while the engine edits it.
        states.add(ja.PlayerState(true, ja.ProcessingState.completed));
        await pumpEventQueue();
        verifyNever(() => player.pause());
        expect(seen.last.processingState, isNot(EngineProcessingState.completed),
            reason: 'a transient end during a transition is not reported');
        when(() => player.processingState).thenReturn(
            realEnd ? ja.ProcessingState.completed : ja.ProcessingState.ready);
        insert.complete();
        await pumpEventQueue();
        if (realEnd) {
          verify(() => player.pause()).called(1);
          expect(seen.last,
              const EngineTransportState(false, EngineProcessingState.completed));
        } else {
          verifyNever(() => player.pause());
          expect(seen.last.playing, isTrue, reason: 'desired play kept');
        }
      }
      await sub.cancel();
    });

    test('round 4: reaching the end pauses the plugin and clears desired play',
        () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      when(() => player.playing).thenReturn(true);
      when(() => player.pause()).thenAnswer((_) async {});
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, autoPlay: true);
      await pumpEventQueue();
      // just_audio keeps playing == true at completion.
      states.add(ja.PlayerState(true, ja.ProcessingState.completed));
      await pumpEventQueue();
      verify(() => player.pause()).called(1);
      expect(seen.last,
          const EngineTransportState(false, EngineProcessingState.completed));
      await sub.cancel();
    });

    test('follow-up: a refused play clears the desired transport', () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      final engine = JustAudioEngine(player, beforePlay: () async => false);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.play();
      await pumpEventQueue();
      expect(seen, isNotEmpty, reason: 'the desired change is reported');
      expect(seen.last.playing, isFalse, reason: 'focus denied: no audio');
      verifyNever(() => player.play());
      await sub.cancel();
    });

    test('follow-up: a play the plugin reverts clears the desired transport',
        () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.play();
      await pumpEventQueue();
      verify(() => player.play()).called(1);
      // Audio-session activation failed: the plugin reverted to paused.
      when(() => player.playing).thenReturn(false);
      states.add(ja.PlayerState(false, ja.ProcessingState.ready));
      await pumpEventQueue();
      expect(seen.last,
          const EngineTransportState(false, EngineProcessingState.ready));
      await sub.cancel();
    });

    test('follow-up: an offline rescue at settle names no unplayable item',
        () async {
      final offline = JustAudioEngine(player, isOfflineFn: () => true);
      addTearDown(offline.dispose);
      await offline.setSeed([
        _entry(itemId: 1, playPosition: 0, filePath: '/a'),
        _entry(itemId: 2, playPosition: 1),
      ], currentItemId: 1);
      await pumpEventQueue();
      final seen = <PlaybackObservation>[];
      final sub = offline.observations.listen(seen.add);
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      await offline.addEntries([_entry(itemId: 3, playPosition: 2)]);
      currentIndex = 1;
      insert.complete();
      await pumpEventQueue();
      expect(
          seen.where((o) => !o.uncertain && o.source?.itemId == 2), isEmpty);
      await sub.cancel();
    });

    test('minor 1: offline, an advance during an edit onto a streaming-only '
        'entry is handed to the rescue', () async {
      final offline = JustAudioEngine(player, isOfflineFn: () => true);
      addTearDown(offline.dispose);
      await offline.setSeed([
        _entry(itemId: 1, playPosition: 0, filePath: '/a'),
        _entry(itemId: 2, playPosition: 1),
      ], currentItemId: 1);
      await pumpEventQueue();
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      final rescues = <int>[];
      final items = <int?>[];
      final subs = [
        offline.unavailableAdvanceStream.listen((e) => rescues.add(e.itemId)),
        offline.currentItemIdStream.listen(items.add),
      ];
      await offline.addEntries([_entry(itemId: 3, playPosition: 2)]);
      currentIndex = 1;
      insert.complete();
      await pumpEventQueue();
      expect(rescues, [2]);
      expect(items, isEmpty);
      for (final sub in subs) {
        await sub.cancel();
      }
    });

    test('minor 2: sources inserted later carry metadata updated meanwhile',
        () async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
      ], currentItemId: 1);
      await pumpEventQueue();
      final insert = Completer<void>();
      final inserted = <int>[];
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((invocation) async {
        inserted.add(invocation.positionalArguments[0] as int);
        if (inserted.length == 1) await insert.future;
      });
      await controller!.addEntries([
        _entry(itemId: 3, playPosition: 5),
        _entry(itemId: 4, playPosition: 6),
      ]);
      await pumpEventQueue();
      // A reorder while the first insert is pending moves item 3 last.
      controller!.replaceLoadedEntriesMetadata(
          [_entry(itemId: 3, playPosition: 9)]);
      insert.complete();
      await pumpEventQueue();
      // (Metadata updates do not reorder the issued list; the core replaces
      // the suffix after an edit. The native order is the invariant here.)
      expect(inserted, [2, 2],
          reason: 'item 4 goes before the moved item 3 natively too');
    });

    test('minor 3: a stop during the load keeps the seeded playlist',
        () async {
      when(
        () => player.setAudioSources(any(),
            initialIndex: any(named: 'initialIndex'),
            initialPosition: any(named: 'initialPosition')),
      ).thenAnswer((_) async => throw ja.PlayerInterruptedException('stop'));
      final events = <EngineLoadEvent>[];
      final sub = controller!.loadEvents.listen(events.add);
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
      ], currentItemId: 1);
      await pumpEventQueue();
      expect(events.single.outcome, EngineLoadOutcome.interrupted);
      await controller!.seekToItem(2);
      await pumpEventQueue();
      verify(() => player.seek(Duration.zero, index: 1)).called(1);
      await sub.cancel();
    });
  });

  group('5B.0c audit (c): exit proofs and fidelity', () {
    test('buffering mapped through the engine, playing vs paused', () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      when(() => player.play()).thenAnswer((_) async {});
      when(() => player.playing).thenReturn(true);
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)], currentItemId: 1, autoPlay: true);
      await pumpEventQueue();
      states.add(ja.PlayerState(true, ja.ProcessingState.buffering));
      await pumpEventQueue();
      expect(seen.last, const EngineTransportState(true, EngineProcessingState.buffering));
      await engine.pause();
      when(() => player.playing).thenReturn(false);
      states.add(ja.PlayerState(false, ja.ProcessingState.buffering));
      await pumpEventQueue();
      expect(seen.last, const EngineTransportState(false, EngineProcessingState.buffering));
      await sub.cancel();
    });

    test('a pause while focus is pending never starts audio', () async {
      when(() => player.play()).thenAnswer((_) async {});
      final verdict = Completer<bool>();
      final engine = JustAudioEngine(player, beforePlay: () => verdict.future);
      addTearDown(engine.dispose);
      await engine.play();
      await pumpEventQueue();
      await engine.pause();
      verdict.complete(true);
      await pumpEventQueue();
      verifyNever(() => player.play());
    });

    test('a remove before the current item never misattributes', () async {
      when(() => player.play()).thenAnswer((_) async {});
      final seen = <PlaybackObservation>[];
      final sub = controller!.observations.listen(seen.add);
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 2);
      await pumpEventQueue();
      final playing = seen.last.source!;
      expect(playing.itemId, 2);
      final remove = Completer<void>();
      when(() => player.removeAudioSourceAt(any())).thenAnswer((_) => remove.future);
      await controller!.removeItem(1);
      seen.clear();
      currentIndex = 0;
      currentIndexController.add(0);
      await pumpEventQueue();
      expect(seen.single.uncertain, isTrue);
      expect(seen.single.source, playing);
      remove.complete();
      await pumpEventQueue();
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source, playing);
      expect(seen.where((o) => !o.uncertain && o.source?.itemId != 2), isEmpty);
      await sub.cancel();
    });

    test('dispose during a stalled load: no events, no plugin work after', () async {
      final load = Completer<Duration?>();
      when(() => player.setAudioSources(any(), initialIndex: any(named: 'initialIndex'), initialPosition: any(named: 'initialPosition'))).thenAnswer((_) => load.future);
      when(() => player.play()).thenAnswer((_) async {});
      final engine = JustAudioEngine(player);
      final events = <Object>[];
      engine.loadEvents.listen(events.add);
      engine.observations.listen(events.add);
      engine.sourceFailures.listen(events.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)], currentItemId: 1, autoPlay: true);
      await engine.addEntries([_entry(itemId: 2, playPosition: 1)]);
      engine.dispose();
      load.complete(null);
      errorController.add(ja.PlayerException(1, 'x', 0));
      await pumpEventQueue();
      expect(events, isEmpty);
      verifyNever(() => player.play());
      verifyNever(() => player.insertAudioSource(any(), any()));
    });

    test('a quick resume after pause survives the pause echo', () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      var playing = false;
      when(() => player.playing).thenAnswer((_) => playing);
      when(() => player.play()).thenAnswer((_) async { playing = true; });
      when(() => player.pause()).thenAnswer((_) async { playing = false; });
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final seen = <EngineTransportState>[];
      final sub = engine.transportStateStream.listen(seen.add);
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)], currentItemId: 1, autoPlay: true);
      await pumpEventQueue();
      await engine.pause();
      states.add(ja.PlayerState(false, ja.ProcessingState.ready)); // the pause echo, in flight
      await engine.play();
      await pumpEventQueue();
      verify(() => player.play()).called(2);
      expect(seen.last.playing, isTrue);
      await sub.cancel();
    });

    test('observation fields map the plugin, not constants', () async {
      when(() => player.play()).thenAnswer((_) async {});
      when(() => player.playing).thenReturn(true);
      when(() => player.duration).thenReturn(const Duration(minutes: 4));
      when(() => player.position).thenReturn(const Duration(seconds: 12));
      final seen = <PlaybackObservation>[];
      final sub = controller!.observations.listen(seen.add);
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)], currentItemId: 1);
      await pumpEventQueue();
      expect(seen.last.playing, isTrue);
      expect(seen.last.duration, const Duration(minutes: 4));
      expect(seen.last.position, const Duration(seconds: 12));
      await sub.cancel();
    });
  });

  // Phase M §7.2, SC-27 Phase M amendment, M-U20: the engine builds stream
  // URIs from its scope's base URL, passed explicitly.
  test('stream sources use the base URL the engine was built with', () async {
    final engine = JustAudioEngine(player, streamBaseUrl: 'http://scope:9/base');
    addTearDown(engine.dispose);
    await engine.setSeed(
      [_entry(itemId: 1, playPosition: 0, uuidId: 'abc')],
      currentItemId: 1,
    );
    await pumpEventQueue();
    final sources = verify(
      () => player.setAudioSources(
        captureAny(),
        initialIndex: any(named: 'initialIndex'),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).captured.single as List<ja.AudioSource>;
    final uri = (sources.single as ja.UriAudioSource).uri;
    expect('${uri.scheme}://${uri.authority}${uri.path}',
        'http://scope:9/base/tracks/abc/stream');
  });

  // Phase M §7.3 / SC-27 Phase M amendment (M-U20, exit proof): the player's
  // stream URI is the ONE place a token appears in a URL: the scope's media
  // token as `?access_token=`, because just_audio can't send headers on
  // every platform.
  group('Phase M: media token', () {
    Future<Uri> seededUri(JustAudioEngine engine, {String? quality}) async {
      if (quality != null) engine.setStreamQuality(quality);
      await engine.setSeed(
        [_entry(itemId: 1, playPosition: 0, uuidId: 'abc')],
        currentItemId: 1,
      );
      await pumpEventQueue();
      final sources = verify(
        () => player.setAudioSources(
          captureAny(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).captured.single as List<ja.AudioSource>;
      return (sources.single as ja.UriAudioSource).uri;
    }

    // Sign-off OPEN-M-11 step D: only while the binding gate allows it (an
    // allowing permit here; media_token_permit_test covers the rule).
    test('stream sources carry the scope media token as access_token',
        () async {
      final engine = JustAudioEngine(player,
          streamBaseUrl: 'http://scope:9', streamMediaToken: 'media-token-A',
          mediaTokenPermit: _AllowAll());
      addTearDown(engine.dispose);
      final uri = await seededUri(engine, quality: '256');
      expect(uri.path, '/tracks/abc/stream');
      expect(uri.queryParameters,
          {'quality': '256', 'access_token': 'media-token-A'});
    });

    test('without a media token the stream URI has no access_token',
        () async {
      final engine = JustAudioEngine(player, streamBaseUrl: 'http://scope:9');
      addTearDown(engine.dispose);
      final uri = await seededUri(engine);
      expect(uri.queryParameters, isNot(contains('access_token')));
    });

    test('a local file source never carries the token', () async {
      final engine = JustAudioEngine(player,
          streamBaseUrl: 'http://scope:9',
          streamMediaToken: 'media-token-A',
          localSources: LocalSourcePolicy());
      addTearDown(engine.dispose);
      await engine.setSeed(
        [_entry(itemId: 1, playPosition: 0, filePath: '/dl/abc.m4a')],
        currentItemId: 1,
      );
      await pumpEventQueue();
      final sources = verify(
        () => player.setAudioSources(
          captureAny(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).captured.single as List<ja.AudioSource>;
      final uri = (sources.single as ja.UriAudioSource).uri;
      expect(uri.scheme, 'file');
      expect('$uri', isNot(contains('media-token-A')));
    });
  });

  // Phase M §7.2 "No secrets in logs" (M-U20, exit proof): player errors can
  // quote the stream URL; the engine redacts the access_token value from
  // what it logs and from the messages it reports onward.
  group('Phase M: redacted player errors', () {
    const leaky = 'Could not load http://scope:9/tracks/abc/stream'
        '?quality=256&access_token=media-token-A (404)';

    test('a source failure is logged and reported without the token',
        () async {
      final logs = <String>[];
      final engine = JustAudioEngine(player,
          streamBaseUrl: 'http://scope:9',
          streamMediaToken: 'media-token-A',
          log: logs.add);
      addTearDown(engine.dispose);
      when(() => player.play()).thenAnswer((_) async {});
      await engine.setSeed(
        [_entry(itemId: 1, playPosition: 0, uuidId: 'abc')],
        currentItemId: 1,
      );
      await pumpEventQueue();
      final failures = <EngineSourceFailure>[];
      final sub = engine.sourceFailures.listen(failures.add);
      addTearDown(sub.cancel);
      errorController.add(ja.PlayerException(404, leaky, 0));
      await pumpEventQueue();

      expect(logs, isNotEmpty);
      for (final line in logs) {
        expect(line, isNot(contains('media-token-A')));
      }
      expect(logs.join('\n'), contains('access_token='));
      expect(failures.single.errorMessage, isNot(contains('media-token-A')));
      expect(failures.single.errorMessage, contains('/tracks/abc/stream'));
    });

    test('the literal media token is redacted wherever it appears', () async {
      final logs = <String>[];
      final engine = JustAudioEngine(player,
          streamBaseUrl: 'http://scope:9',
          streamMediaToken: 'media-token-A',
          log: logs.add);
      addTearDown(engine.dispose);
      when(() => player.play()).thenAnswer((_) async {});
      await engine.setSeed(
        [_entry(itemId: 1, playPosition: 0, uuidId: 'abc')],
        currentItemId: 1,
      );
      await pumpEventQueue();
      final failures = <EngineSourceFailure>[];
      final sub = engine.sourceFailures.listen(failures.add);
      addTearDown(sub.cancel);
      errorController.add(ja.PlayerException(
          401, 'bad credential media-token-A for {token: media-token-A}', 0));
      await pumpEventQueue();
      expect(logs, isNotEmpty);
      for (final line in logs) {
        expect(line, isNot(contains('media-token-A')));
      }
      expect(failures.single.errorMessage, isNot(contains('media-token-A')));
    });

    // Review r1 m-R1-31: the two remaining sites, a load error that is not
    // a PlayerException and a held failure re-reported at settle.
    test('a non-player load error is reported without the token', () async {
      when(
        () => player.setAudioSources(
          any(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).thenAnswer((_) async => throw Exception(leaky));
      final engine = JustAudioEngine(player,
          streamBaseUrl: 'http://scope:9',
          streamMediaToken: 'media-token-A',
          log: (_) {});
      addTearDown(engine.dispose);
      final events = <EngineLoadEvent>[];
      final sub = engine.loadEvents.listen(events.add);
      addTearDown(sub.cancel);
      await engine.setSeed(
        [_entry(itemId: 1, playPosition: 0, uuidId: 'abc')],
        currentItemId: 1,
      );
      await pumpEventQueue();

      expect(events.single.outcome, EngineLoadOutcome.failed);
      expect(events.single.errorMessage, isNot(contains('media-token-A')));
      expect(events.single.errorMessage, contains('/tracks/abc/stream'));
    });

    test('a held failure re-reported at settle carries no token', () async {
      when(() => player.play()).thenAnswer((_) async {});
      final engine = JustAudioEngine(player,
          streamBaseUrl: 'http://scope:9',
          streamMediaToken: 'media-token-A',
          log: (_) {});
      addTearDown(engine.dispose);
      await engine.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'abc'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'def'),
      ], currentItemId: 1);
      await pumpEventQueue();
      final failures = <EngineSourceFailure>[];
      final sub = engine.sourceFailures.listen(failures.add);
      addTearDown(sub.cancel);
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      await engine.addEntries([_entry(itemId: 3, playPosition: 2)]);
      errorController.add(ja.PlayerException(404, leaky, 0));
      await pumpEventQueue();
      when(() => player.processingState).thenReturn(ja.ProcessingState.idle);
      insert.complete();
      await pumpEventQueue();

      expect(failures, hasLength(2), reason: 'held, then re-reported');
      for (final failure in failures) {
        expect(failure.errorMessage, isNot(contains('media-token-A')));
      }
    });

    test('a failed load is logged and reported without the token', () async {
      final logs = <String>[];
      when(
        () => player.setAudioSources(
          any(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).thenAnswer((_) async => throw ja.PlayerException(404, leaky, 0));
      final engine = JustAudioEngine(player,
          streamBaseUrl: 'http://scope:9',
          streamMediaToken: 'media-token-A',
          log: logs.add);
      addTearDown(engine.dispose);
      final events = <EngineLoadEvent>[];
      final sub = engine.loadEvents.listen(events.add);
      addTearDown(sub.cancel);
      await engine.setSeed(
        [_entry(itemId: 1, playPosition: 0, uuidId: 'abc')],
        currentItemId: 1,
      );
      await pumpEventQueue();

      expect(events.single.outcome, EngineLoadOutcome.failed);
      expect(events.single.errorMessage, isNot(contains('media-token-A')));
      expect(logs, isNotEmpty);
      for (final line in logs) {
        expect(line, isNot(contains('media-token-A')));
      }
    });
  });

  // SC-27 §6 row 1 (7P.1): a native command that fails is a typed value on
  // the engine's stream, never only a log line.
  group('7P.1 typed command failure', () {
    late List<EngineCommandFailure> failures;
    late StreamSubscription<EngineCommandFailure> failureSub;

    setUp(() {
      when(() => player.play()).thenAnswer((_) async {});
      failures = [];
      failureSub = controller!.commandFailures.listen(failures.add);
    });

    tearDown(() => failureSub.cancel());

    /// Items 1 (current), 2; returns the seed's playlist revision.
    Future<int> seeded() async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'u2'),
      ], currentItemId: 1, sessionId: 7);
      final seedRevision = controller!.playlistRevision;
      await pumpEventQueue();
      return seedRevision;
    }

    test('a native insert that throws is one typed failure naming the source '
        'by id and kind only', () async {
      final seedRevision = await seeded();
      when(() => player.insertAudioSource(any(), any())).thenThrow(
          ja.PlayerException(7,
              'cannot open file:///music/u3.flac?access_token=secret', 2));
      await controller!.addEntries([
        _entry(itemId: 3, playPosition: 2, uuidId: 'u3',
            filePath: '/music/u3.flac'),
      ]);
      await pumpEventQueue();

      final failure = failures.single;
      expect(failure.command, EngineCommand.insert);
      expect(failure.reason, EngineCommandFailureReason.failed);
      expect(failure.diverged, isTrue);
      expect(
          failure.target,
          const EngineCommandTarget(
              itemId: 3, trackUuid: 'u3', sourceKind: PlaybackSourceKind.local));
      expect(failure.seedRevision, seedRevision);
      expect(failure.playlistRevision, controller!.playlistRevision);
      expect(failure.runtimeId, controller!.runtimeId);
      expect(failure.errorCode, 7);
      expect(failure.cause, PlaybackTransitionCause.queueEdit);
      for (final text in ['$failure', '${failure.target}']) {
        expect(text, isNot(contains('/music')));
        expect(text, isNot(contains('secret')));
      }
    });

    test('a native remove that throws is typed with the removed stream source',
        () async {
      final seedRevision = await seeded();
      when(() => player.removeAudioSourceAt(any()))
          .thenThrow(StateError('platform refused'));
      await controller!.removeItem(2);
      await pumpEventQueue();

      final failure = failures.single;
      expect(failure.command, EngineCommand.remove);
      expect(failure.reason, EngineCommandFailureReason.failed);
      expect(failure.diverged, isTrue);
      expect(
          failure.target,
          const EngineCommandTarget(
              itemId: 2, trackUuid: 'u2', sourceKind: PlaybackSourceKind.remote));
      expect(failure.seedRevision, seedRevision);
      expect(failure.errorCode, isNull, reason: 'not a plugin error');
    });

    test('a failure inside a multi-step edit names the step that failed',
        () async {
      await seeded();
      // replaceFutureEntries removes item 2, then inserts 4: the insert fails.
      when(() => player.insertAudioSource(any(), any()))
          .thenThrow(ja.PlayerException(1, 'no', 1));
      await controller!.replaceFutureEntries(currentItemId: 1, entries: [
        _entry(itemId: 4, playPosition: 1, uuidId: 'u4'),
      ]);
      await pumpEventQueue();
      verify(() => player.removeAudioSourceAt(1)).called(1);
      expect(failures.single.command, EngineCommand.insert);
      expect(failures.single.target?.itemId, 4);
    });

    test('commands that apply report nothing', () async {
      await seeded();
      await controller!.addEntries([_entry(itemId: 3, playPosition: 2)]);
      await controller!.removeItem(2);
      await controller!.seekToItem(3);
      await pumpEventQueue();
      expect(failures, isEmpty);
    });
  });

  // 7P.1: after a native command failed the engine no longer knows what the
  // plugin holds. Nothing is settled, committed or labelled naturalAdvance
  // until the core reseeds (rebuild from queue data).
  group('7P.1 divergence', () {
    late List<PlaybackObservation> seen;
    late List<int?> items;
    late List<EngineCommandFailure> failures;
    late List<EngineSourceFailure> sourceFailures;
    late List<EngineTransportState> transport;
    late StreamController<ja.PlayerState> states;
    final subs = <StreamSubscription<Object?>>[];

    setUp(() {
      when(() => player.play()).thenAnswer((_) async {});
      states = StreamController<ja.PlayerState>.broadcast();
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      // Rebuilt so it listens to the plugin state stream above.
      controller!.dispose();
      controller = JustAudioEngine(player);
      seen = [];
      items = [];
      failures = [];
      sourceFailures = [];
      transport = [];
      subs
        ..add(controller!.observations.listen(seen.add))
        ..add(controller!.currentItemIdStream.listen(items.add))
        ..add(controller!.commandFailures.listen(failures.add))
        ..add(controller!.sourceFailures.listen(sourceFailures.add))
        ..add(controller!.transportStateStream.listen(transport.add));
    });

    tearDown(() async {
      for (final sub in subs) {
        await sub.cancel();
      }
      subs.clear();
      await states.close();
    });

    Future<void> seeded() async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 5, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 6, uuidId: 'u2'),
        _entry(itemId: 3, playPosition: 7, uuidId: 'u3'),
      ], currentItemId: 2, sessionId: 7, autoPlay: true);
      await pumpEventQueue();
      seen.clear();
    }

    /// An insert that fails once the test says so.
    Completer<void> failingInsert() {
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      return insert;
    }

    test('the settle after a failed insert commits nothing and labels '
        'nothing naturalAdvance', () async {
      await seeded();
      final insert = failingInsert();
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      // The plugin's index moved while its playlist edit failed.
      currentIndex = 2;
      currentIndexController.add(2);
      await pumpEventQueue();
      insert.completeError(ja.PlayerException(1, 'no', 3));
      await pumpEventQueue();

      expect(failures, hasLength(1));
      expect(items, isEmpty, reason: 'nothing committed from a diverged playlist');
      expect(controller!.currentItemId, 2);
      expect(seen.where((o) => !o.uncertain), isEmpty,
          reason: 'nothing is settled until a reseed');
      expect(
          seen.where(
              (o) => o.transitionCause == PlaybackTransitionCause.naturalAdvance),
          isEmpty);
    });

    test('while diverged, index reports and auto-advances are not trusted',
        () async {
      await seeded();
      when(() => player.insertAudioSource(any(), any()))
          .thenThrow(StateError('refused'));
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      await pumpEventQueue();
      seen.clear();

      currentIndex = 2;
      currentIndexController.add(2);
      discontinuityController.add(ja.PositionDiscontinuity(
        ja.PositionDiscontinuityReason.autoAdvance,
        ja.PlaybackEvent(currentIndex: 1),
        ja.PlaybackEvent(currentIndex: 2),
      ));
      await pumpEventQueue();

      expect(items, isEmpty);
      expect(seen, isNotEmpty);
      expect(seen.every((o) => o.uncertain), isTrue);
      expect(
          seen.where(
              (o) => o.transitionCause == PlaybackTransitionCause.naturalAdvance),
          isEmpty);
    });

    test('while diverged, a completed report is not the queue end', () async {
      when(() => player.playing).thenReturn(true);
      await seeded();
      when(() => player.insertAudioSource(any(), any()))
          .thenThrow(StateError('refused'));
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      await pumpEventQueue();
      transport.clear();

      states.add(ja.PlayerState(true, ja.ProcessingState.completed));
      await pumpEventQueue();

      expect(transport.map((t) => t.processingState),
          isNot(contains(EngineProcessingState.completed)));
      verifyNever(() => player.pause());
    });

    test('a source failure held during the failed edit is not blamed on a '
        'settled source', () async {
      await seeded();
      final insert = failingInsert();
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      errorController.add(ja.PlayerException(404, 'gone', 1));
      await pumpEventQueue();
      expect(sourceFailures.single.uncertain, isTrue);
      when(() => player.processingState).thenReturn(ja.ProcessingState.idle);
      insert.completeError(StateError('refused'));
      await pumpEventQueue();

      expect(sourceFailures, hasLength(1),
          reason: 'no settled re-report from a diverged playlist');
    });

    test('U19-FE-PB-ENGINE-B-01: a source failure after the failed edit, '
        'while diverged, is uncertain and names no item; the rebuild\'s seed '
        'drops it', () async {
      await seeded(); // item 2 plays at index 1
      currentIndex = 1;
      when(() => player.insertAudioSource(any(), any()))
          .thenThrow(StateError('refused'));
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      await pumpEventQueue();
      expect(failures, hasLength(1), reason: 'precondition: diverged');

      when(() => player.processingState).thenReturn(ja.ProcessingState.idle);
      errorController.add(ja.PlayerException(404, 'gone', null));
      await pumpEventQueue();
      expect(sourceFailures, hasLength(1));
      expect(sourceFailures.single.uncertain, isTrue,
          reason: 'the plugin\'s index is not proof while diverged');
      expect(sourceFailures.single.source, isNull);

      // The queue player's rebuild: a new seed around the current item.
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 5, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 6, uuidId: 'u2'),
      ], currentItemId: 2, sessionId: 7);
      await pumpEventQueue();
      expect(sourceFailures, hasLength(1),
          reason: 'nothing is re-reported against a guessed item');
    });

    test('one failure per seed; the next seed trusts the plugin again',
        () async {
      await seeded();
      final firstSeed = failures.length;
      when(() => player.insertAudioSource(any(), any()))
          .thenThrow(StateError('refused'));
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      await controller!.addEntries([_entry(itemId: 5, playPosition: 9)]);
      await pumpEventQueue();
      expect(failures, hasLength(firstSeed + 1));
      final diverged = failures.single.seedRevision;

      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 5, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 6, uuidId: 'u2'),
      ], currentItemId: 1, sessionId: 7);
      final reseed = controller!.playlistRevision;
      await pumpEventQueue();
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.itemId, 1);

      currentIndex = 1;
      currentIndexController.add(1);
      await pumpEventQueue();
      expect(items.last, 2, reason: 'a natural advance is trusted again');

      await controller!.addEntries([_entry(itemId: 6, playPosition: 7)]);
      await pumpEventQueue();
      expect(failures, hasLength(2));
      expect(failures.last.seedRevision, reseed);
      expect(reseed, isNot(diverged));
    });
    test('a failure of work a newer seed replaced is not reported', () async {
      await seeded();
      final insert = failingInsert();
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, sessionId: 8);
      insert.completeError(StateError('refused'));
      await pumpEventQueue();
      expect(failures, isEmpty);
      expect(seen.last.uncertain, isFalse,
          reason: 'the new seed is not diverged');
    });
  });

  // 7P.1: just_audio's seek() returns without seeking while the plugin is
  // loading (just_audio 0.10.5 `seek`, `case ProcessingState.loading`).
  group('7P.1 dropped seek', () {
    late List<PlaybackObservation> seen;
    late List<int?> items;
    late List<EngineCommandFailure> failures;
    final subs = <StreamSubscription<Object?>>[];

    setUp(() {
      when(() => player.play()).thenAnswer((_) async {});
      seen = [];
      items = [];
      failures = [];
      subs
        ..add(controller!.observations.listen(seen.add))
        ..add(controller!.currentItemIdStream.listen(items.add))
        ..add(controller!.commandFailures.listen(failures.add));
    });

    tearDown(() async {
      for (final sub in subs) {
        await sub.cancel();
      }
      subs.clear();
    });

    Future<int> seeded() async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'u2'),
        _entry(itemId: 3, playPosition: 2, uuidId: 'u3'),
      ], currentItemId: 2, sessionId: 7);
      final revision = controller!.playlistRevision;
      await pumpEventQueue();
      seen.clear();
      return revision;
    }

    test('a seek while the plugin loads is a typed dropped seek with the '
        'asked position', () async {
      final seedRevision = await seeded();
      when(() => player.processingState).thenReturn(ja.ProcessingState.loading);
      await controller!.seek(const Duration(seconds: 30));
      await pumpEventQueue();

      final failure = failures.single;
      expect(failure.command, EngineCommand.seek);
      expect(failure.reason, EngineCommandFailureReason.dropped);
      expect(failure.diverged, isTrue);
      expect(failure.position, const Duration(seconds: 30));
      expect(failure.cause, PlaybackTransitionCause.userSeek);
      expect(failure.target?.itemId, 2);
      expect(failure.target?.trackUuid, 'u2');
      expect(failure.seedRevision, seedRevision);
    });

    test('an item seek dropped while loading is never settled as a natural '
        'advance back to the old item', () async {
      await seeded();
      when(() => player.processingState).thenReturn(ja.ProcessingState.loading);
      // The plugin ignores it: its index stays on item 2 (index 1).
      when(() => player.seek(any(), index: any(named: 'index')))
          .thenAnswer((_) async {});
      await controller!.seekToItem(1,
          cause: PlaybackTransitionCause.userSkip);
      await pumpEventQueue();

      final failure = failures.single;
      expect(failure.command, EngineCommand.seek);
      expect(failure.reason, EngineCommandFailureReason.dropped);
      expect(failure.target?.itemId, 1);
      expect(failure.position, Duration.zero);
      expect(failure.cause, PlaybackTransitionCause.userSkip);
      expect(items, [1], reason: 'only the issued move; never back to 2');
      expect(
          seen.where(
              (o) => o.transitionCause == PlaybackTransitionCause.naturalAdvance),
          isEmpty);
      expect(seen.where((o) => !o.uncertain), isEmpty);
    });

    test('a seek that throws is a typed failed seek', () async {
      await seeded();
      when(() => player.seek(any(), index: any(named: 'index')))
          .thenThrow(ja.PlayerException(3, 'seek refused', 1));
      await controller!.seekToItem(3,
          position: const Duration(seconds: 4),
          cause: PlaybackTransitionCause.naturalAdvance);
      await pumpEventQueue();

      final failure = failures.single;
      expect(failure.command, EngineCommand.seek);
      expect(failure.reason, EngineCommandFailureReason.failed);
      expect(failure.target?.itemId, 3);
      expect(failure.position, const Duration(seconds: 4));
      expect(failure.cause, PlaybackTransitionCause.naturalAdvance);
      expect(failure.errorCode, 3);
    });

    test('seeks on a ready or idle plugin are not reported', () async {
      await seeded();
      await controller!.seek(const Duration(seconds: 3));
      when(() => player.processingState).thenReturn(ja.ProcessingState.idle);
      await controller!.seekToItem(3);
      await pumpEventQueue();
      expect(failures, isEmpty);
    });

    test('a stop while diverged is still a certain stop of the settled item',
        () async {
      await seeded();
      when(() => player.processingState).thenReturn(ja.ProcessingState.loading);
      await controller!.seek(const Duration(seconds: 30));
      await pumpEventQueue();
      expect(failures, hasLength(1));
      await controller!.stop();
      await pumpEventQueue();
      final stop = seen.last;
      expect(stop.transitionCause, PlaybackTransitionCause.stop);
      expect(stop.uncertain, isFalse, reason: 'a stop is a real boundary');
      expect(stop.source?.itemId, 2);
    });
  });

  // 7P.1: an index the plugin reports outside any transition is trusted only
  // when it can be explained: the same item, the next one, or the wrap to the
  // first under a native loop-all the engine asked for. A late report of the
  // old playlist is never committed.
  group('7P.1 unexplained index', () {
    late List<PlaybackObservation> seen;
    late List<int?> items;
    late List<EngineCommandFailure> failures;
    final subs = <StreamSubscription<Object?>>[];

    setUp(() {
      when(() => player.play()).thenAnswer((_) async {});
      seen = [];
      items = [];
      failures = [];
      subs
        ..add(controller!.observations.listen(seen.add))
        ..add(controller!.currentItemIdStream.listen(items.add))
        ..add(controller!.commandFailures.listen(failures.add));
    });

    tearDown(() async {
      for (final sub in subs) {
        await sub.cancel();
      }
      subs.clear();
    });

    /// Items 1, 2, 3 at indices 0, 1, 2; [current] is current.
    Future<int> seeded({int current = 2}) async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 5, uuidId: 'u1'),
        _entry(itemId: 2, playPosition: 6, uuidId: 'u2'),
        _entry(itemId: 3, playPosition: 7, uuidId: 'u3'),
      ], currentItemId: current, sessionId: 7);
      final revision = controller!.playlistRevision;
      await pumpEventQueue();
      seen.clear();
      return revision;
    }

    void report(int index) {
      currentIndex = index;
      currentIndexController.add(index);
    }

    test('the next item is a natural advance (unchanged)', () async {
      await seeded();
      report(2);
      await pumpEventQueue();
      expect(items, [3]);
      expect(failures, isEmpty);
    });

    test('a late report of the old index after an insert before the current '
        'item is a typed failure, never committed', () async {
      final seedRevision = await seeded();
      await controller!.addEntries([_entry(itemId: 0, playPosition: 4)]);
      report(2); // item 2 shifted to index 2: correct
      await pumpEventQueue();
      expect(items, isEmpty);
      report(1); // late: the old playlist's index of item 2, now item 1
      await pumpEventQueue();

      expect(items, isEmpty, reason: 'never committed');
      expect(controller!.currentItemId, 2);
      final failure = failures.single;
      expect(failure.reason, EngineCommandFailureReason.unexplainedIndex);
      expect(failure.diverged, isTrue);
      expect(failure.target?.itemId, 1, reason: 'the item the plugin named');
      expect(failure.seedRevision, seedRevision);
      expect(
          seen.where(
              (o) => o.transitionCause == PlaybackTransitionCause.naturalAdvance),
          isEmpty);
    });

    test('a jump past the next item is a typed failure', () async {
      await seeded(current: 1);
      report(2);
      await pumpEventQueue();
      expect(items, isEmpty);
      expect(failures.single.reason, EngineCommandFailureReason.unexplainedIndex);
      expect(failures.single.target?.itemId, 3);
    });

    test('the wrap to the first item is trusted only under a requested '
        'native loop-all', () async {
      await seeded(current: 3);
      await controller!.setLoopMode(EngineLoopMode.all);
      report(0);
      await pumpEventQueue();
      expect(items, [1]);
      expect(failures, isEmpty);
    });

    test('a wrap the engine did not ask for is a typed failure', () async {
      await seeded(current: 3);
      await controller!.setLoopMode(EngineLoopMode.off);
      report(0);
      await pumpEventQueue();
      expect(items, isEmpty);
      expect(failures.single.reason, EngineCommandFailureReason.unexplainedIndex);
    });

    test('a settle on an index that is not the next item is a typed failure, '
        'not a natural advance', () async {
      await seeded();
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      await controller!.addEntries([_entry(itemId: 4, playPosition: 8)]);
      report(0); // while pending: the plugin went back to item 1
      await pumpEventQueue();
      insert.complete();
      await pumpEventQueue();

      expect(items, isEmpty);
      expect(controller!.currentItemId, 2);
      expect(failures.single.reason, EngineCommandFailureReason.unexplainedIndex);
      expect(failures.single.target?.itemId, 1);
      expect(
          seen.where(
              (o) => o.transitionCause == PlaybackTransitionCause.naturalAdvance),
          isEmpty);
      expect(seen.last.uncertain, isTrue);
    });
  });

  // 7-R1-05 (7P.1 R1-06): just_audio keeps the plugin's old index until the
  // platform reports the new one, so after an edit that shifts the playing
  // item (a remove or insert before it, a rebuild around it) the index read
  // at the settle can be the pre-edit one. An index is explained by the
  // playlist as it was when the command that moved it was issued, never by
  // the playlist now: the stale index is not a natural advance and not a
  // failure; the plugin's fresh report confirms the item.
  group('7-R1-05 stale index after an edit', () {
    late List<PlaybackObservation> seen;
    late List<int?> items;
    late List<EngineCommandFailure> failures;
    late StreamController<Duration> positions;
    final subs = <StreamSubscription<Object?>>[];

    setUp(() {
      // An engine whose position ticks the test drives.
      positions = StreamController<Duration>.broadcast();
      when(() => player.positionStream).thenAnswer((_) => positions.stream);
      controller?.dispose();
      controller = JustAudioEngine(player);
      when(() => player.play()).thenAnswer((_) async {});
      // Like the plugin on Android: an edit returns before the platform
      // reports the shifted index (the Dart side keeps the old one).
      when(() => player.removeAudioSourceAt(any())).thenAnswer((_) async {});
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) async {});
      seen = [];
      items = [];
      failures = [];
      subs
        ..add(controller!.observations.listen(seen.add))
        ..add(controller!.currentItemIdStream.listen(items.add))
        ..add(controller!.commandFailures.listen(failures.add));
    });

    tearDown(() async {
      for (final sub in subs) {
        await sub.cancel();
      }
      subs.clear();
      await positions.close();
    });

    /// Items 1..4 (a, b, c, d) at indices 0..3; [current] is current.
    Future<void> seeded({int current = 2}) async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'a'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'b'),
        _entry(itemId: 3, playPosition: 2, uuidId: 'c'),
        _entry(itemId: 4, playPosition: 3, uuidId: 'd'),
      ], currentItemId: current, sessionId: 7);
      await pumpEventQueue();
      seen.clear();
    }

    void report(int index) {
      currentIndex = index;
      currentIndexController.add(index);
    }

    Iterable<PlaybackObservation> advances() => seen.where(
        (o) => o.transitionCause == PlaybackTransitionCause.naturalAdvance);

    // 7-R2-12: a replacement queue seeded while reports of the old queue's
    // steps are still outstanding starts from a fresh trail: its settle and
    // its first reports are explained by the new queue only.
    test('7-R2-12 a new seed drops the old queue\'s outstanding steps: the '
        'new queue settles certain and advances normally', () async {
      await seeded(); // b plays at index 1
      await controller!.removeItem(1); // a removed: steps [1 (b), 0 (b)]
      await pumpEventQueue();
      expect(seen.last.uncertain, isTrue,
          reason: 'precondition: the old queue\'s report is outstanding');
      seen.clear();

      // The replacement plays y at index 1, the stale step's index.
      await controller!.setSeed([
        _entry(itemId: 10, playPosition: 0, uuidId: 'x'),
        _entry(itemId: 11, playPosition: 1, uuidId: 'y'),
        _entry(itemId: 12, playPosition: 2, uuidId: 'z'),
      ], currentItemId: 11, sessionId: 8);
      await pumpEventQueue();
      expect(seen.last.uncertain, isFalse,
          reason: 'index 1 belongs to the new queue, not to the old b');
      expect(seen.last.source?.itemId, 11);

      report(2); // z: the new queue's natural advance
      await pumpEventQueue();
      expect(failures, isEmpty);
      expect(controller!.currentItemId, 12);
      expect(items, [12], reason: 'z committed, nothing else');
      expect(seen.last.uncertain, isFalse);
    });

    test('removing an earlier item with the index reported after the remove '
        'returns: no advance, no failure, the playing item stays', () async {
      await seeded(); // b plays at index 1
      await controller!.removeItem(1); // b shifts to index 0
      await pumpEventQueue();
      // The settle read the stale index 1 (now c): not an advance.
      expect(items, isEmpty, reason: 'nothing committed');
      expect(controller!.currentItemId, 2);
      expect(advances(), isEmpty);
      expect(seen.last.uncertain, isTrue,
          reason: 'unconfirmed until the plugin reports the new index');

      report(0); // the plugin's fresh report
      await pumpEventQueue();
      expect(items, isEmpty);
      expect(failures, isEmpty, reason: 'no rebuild around any item');
      expect(controller!.currentItemId, 2);
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.itemId, 2);
      expect(advances(), isEmpty);
    });

    test('the same remove with the index reported before it returns (the '
        'Darwin order) settles certain on the playing item', () async {
      await seeded();
      when(() => player.removeAudioSourceAt(any())).thenAnswer((_) async {
        report(0);
      });
      await controller!.removeItem(1);
      await pumpEventQueue();
      expect(items, isEmpty);
      expect(failures, isEmpty);
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.itemId, 2);
    });

    test('position ticks while the stale index is outstanding are uncertain '
        'and never name the next item', () async {
      await seeded();
      await controller!.removeItem(1);
      await pumpEventQueue();
      seen.clear();
      positions.add(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(seen, isNotEmpty);
      expect(seen.every((o) => o.uncertain), isTrue);
      expect(seen.any((o) => o.source?.itemId == 3), isFalse);
      report(0);
      await pumpEventQueue();
      seen.clear();
      positions.add(const Duration(seconds: 6));
      await pumpEventQueue();
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.itemId, 2);
    });

    test('after the fresh report a natural advance is accepted again',
        () async {
      await seeded();
      await controller!.removeItem(1);
      await pumpEventQueue();
      report(0);
      await pumpEventQueue();
      report(1); // c, the next item, as the playlist is now
      await pumpEventQueue();
      expect(items, [3]);
      expect(failures, isEmpty);
    });

    test('while the stale index is outstanding, an index nothing explains is '
        'still a typed failure', () async {
      await seeded();
      await controller!.removeItem(1);
      await pumpEventQueue();
      report(2); // d: neither b now, b before the remove, nor b's next
      await pumpEventQueue();
      expect(items, isEmpty);
      expect(failures.single.reason,
          EngineCommandFailureReason.unexplainedIndex);
    });

    test('an insert before the playing item with the index reported late is '
        'not a failure (no needless rebuild)', () async {
      await seeded(); // b at index 1
      await controller!
          .addEntries([_entry(itemId: 0, playPosition: -1, uuidId: 'z')]);
      await pumpEventQueue();
      // The stale index 1 now names a (before b): unexplained today.
      expect(failures, isEmpty);
      expect(items, isEmpty);
      report(2); // b shifted to 2
      await pumpEventQueue();
      expect(failures, isEmpty);
      expect(items, isEmpty);
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.itemId, 2);
    });

    test('a rebuild around the playing item (shuffle toggle, repeat-all wrap) '
        'with the index reported late: no advance, no failure', () async {
      await seeded(current: 3); // c at index 2
      await controller!.rebuildAroundCurrent(currentItemId: 3, entries: [
        _entry(itemId: 1, playPosition: 0, uuidId: 'a'),
        _entry(itemId: 3, playPosition: 1, uuidId: 'c'),
        _entry(itemId: 2, playPosition: 2, uuidId: 'b'),
        _entry(itemId: 4, playPosition: 3, uuidId: 'd'),
      ]);
      await pumpEventQueue();
      // Applied [a, c, b, d]: the stale index 2 names b, the next item.
      expect(items, isEmpty, reason: 'b is not committed');
      expect(advances(), isEmpty);
      expect(failures, isEmpty);
      // Only the final index arrives (a platform that coalesces the steps'
      // reports): it cannot be told from the first of the in-order reports
      // (review r1, P1), so it is read as the older step. Nothing moves and
      // nothing fails; every step names c, so the observation is certain
      // (review r2) ...
      report(1); // c, as the rebuilt playlist has it
      await pumpEventQueue();
      expect(items, isEmpty);
      expect(failures, isEmpty);
      expect(controller!.currentItemId, 3);
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.itemId, 3);
      // ... and c's natural end, which the record cannot explain, commits.
      report(2); // b, after c in the rebuilt playlist
      await pumpEventQueue();
      expect(items, [2]);
      expect(failures, isEmpty);
      expect(seen.last.uncertain, isFalse);
      expect(seen.last.source?.itemId, 2);
    });

    test('an intermediate index of a rebuild reported late is not a failure',
        () async {
      await seeded(current: 3);
      await controller!.rebuildAroundCurrent(currentItemId: 3, entries: [
        _entry(itemId: 1, playPosition: 0, uuidId: 'a'),
        _entry(itemId: 3, playPosition: 1, uuidId: 'c'),
        _entry(itemId: 2, playPosition: 2, uuidId: 'b'),
        _entry(itemId: 4, playPosition: 3, uuidId: 'd'),
      ]);
      await pumpEventQueue();
      // c sat at index 0 once the items before it were removed.
      report(0);
      await pumpEventQueue();
      expect(failures, isEmpty);
      expect(items, isEmpty);
      report(1);
      await pumpEventQueue();
      expect(failures, isEmpty);
      expect(controller!.currentItemId, 3);
    });

    test('a new seed forgets the stale indices of the old playlist', () async {
      await seeded();
      await controller!.removeItem(1); // stale index 1 outstanding
      await pumpEventQueue();
      await seeded(current: 1); // a fresh playlist, a at index 0
      report(1); // b: the next item of the new playlist
      await pumpEventQueue();
      expect(items, [2], reason: 'a natural advance of the new playlist');
      expect(failures, isEmpty);
    });

    // The same rule for an item seek (a skip or a tap): until the plugin
    // reports the target's index, it may still report the item it left
    // (7P.1's residual, its live-gate check 2).
    // 7-fix-r1-pb review r1 (findings 1–4): the plugin reports each native
    // step's index in order. A report is explained by the step it belongs to;
    // only the report of the last step confirms the item, and the settle
    // never confirms early because the stale value happens to equal the
    // current one.
    group('review r1: reports belong to the steps, in order', () {
      Future<void> reportAll(List<int> indices) async {
        for (final i in indices) {
          report(i);
          await pumpEventQueue();
        }
      }

      void expectNothingMoved({int current = 3}) {
        expect(failures, isEmpty,
            reason: 'failures: ${failures.map((f) => f.reason)}');
        expect(items, isEmpty);
        expect(controller!.currentItemId, current);
        expect(advances(), isEmpty);
      }

      final shuffled = [
        _entry(itemId: 1, playPosition: 0, uuidId: 'a'),
        _entry(itemId: 3, playPosition: 1, uuidId: 'c'),
        _entry(itemId: 2, playPosition: 2, uuidId: 'b'),
        _entry(itemId: 4, playPosition: 3, uuidId: 'd'),
      ];

      test('P1: a rebuild whose every step is reported late, in order',
          () async {
        await seeded(current: 3); // c at 2
        await controller!
            .rebuildAroundCurrent(currentItemId: 3, entries: shuffled);
        await pumpEventQueue();
        await reportAll([1, 0, 1]); // remove a, remove b, insert a
        expectNothingMoved();
        expect(seen.last.uncertain, isFalse, reason: 'the last step confirms');
        expect(seen.last.source?.itemId, 3);
      });

      test('P2: a rebuild that leaves the item at its starting index, every '
          'step reported late', () async {
        await seeded(current: 3); // c at 2
        await controller!.rebuildAroundCurrent(currentItemId: 3, entries: [
          _entry(itemId: 2, playPosition: 0, uuidId: 'b'),
          _entry(itemId: 1, playPosition: 1, uuidId: 'a'),
          _entry(itemId: 3, playPosition: 2, uuidId: 'c'),
          _entry(itemId: 4, playPosition: 3, uuidId: 'd'),
        ]);
        await pumpEventQueue();
        expect(seen.last.uncertain, isTrue,
            reason: 'the settle read (2) is the value before the steps');
        await reportAll([1, 0, 1, 2]);
        expectNothingMoved();
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 3);
      });

      test('the same rebuild with each step reported before its call returns '
          '(the Darwin order) settles certain', () async {
        await seeded(current: 3);
        when(() => player.removeAudioSourceAt(any())).thenAnswer((inv) async {
          final index = inv.positionalArguments[0] as int;
          if (index < currentIndex) report(currentIndex - 1);
        });
        when(() => player.insertAudioSource(any(), any()))
            .thenAnswer((inv) async {
          final index = inv.positionalArguments[0] as int;
          if (index <= currentIndex) report(currentIndex + 1);
        });
        await controller!
            .rebuildAroundCurrent(currentItemId: 3, entries: shuffled);
        await pumpEventQueue();
        expectNothingMoved();
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 3);
      });

      test('P3: a remove and an insert before the item, both reported late',
          () async {
        await seeded(current: 3); // c at 2
        await controller!.removeItem(1); // c 2 -> 1
        await controller!
            .addEntries([_entry(itemId: 9, playPosition: -1, uuidId: 'z')]);
        await pumpEventQueue(); // c 1 -> 2
        await reportAll([1, 2]);
        expectNothingMoved();
        expect(seen.last.uncertain, isFalse);
      });

      test('P5: a remove before the item, then a skip, both reported late',
          () async {
        when(() => player.seek(any(), index: any(named: 'index')))
            .thenAnswer((_) async {});
        await seeded(); // b at 1
        await controller!.removeItem(1); // b 1 -> 0
        await pumpEventQueue();
        await controller!.seekToItem(3); // c, now at 1
        await pumpEventQueue();
        await reportAll([0, 1]);
        expect(failures, isEmpty,
            reason: 'failures: ${failures.map((f) => f.reason)}');
        expect(items, [3], reason: 'only the skip');
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 3);
      });

      test('P8: a quality rebuild of the playing source (removed, re-inserted, '
          'seeked), reported late: nothing committed, no failure', () async {
        when(() => player.seek(any(), index: any(named: 'index')))
            .thenAnswer((_) async {});
        await seeded(); // b at 1
        await controller!
            .rebuildCurrentSource('320', const Duration(seconds: 30));
        await pumpEventQueue();
        // The plugin plays c at 1 once b is removed; b' inserted at 1 pushes
        // c to 2; the seek brings it back to b' at 1.
        await reportAll([2, 1]);
        expectNothingMoved(current: 2);
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 2);
      });

      test('P8: a download landing for the playing track (its source '
          'refreshed), reported late: nothing committed, no failure',
          () async {
        when(() => player.seek(any(), index: any(named: 'index')))
            .thenAnswer((_) async {});
        await seeded(); // b at 1, streamed
        await controller!.refreshLoadedSourcesForAvailabilityChanges([
          _entry(itemId: 2, playPosition: 1, uuidId: 'b', filePath: '/dl/b'),
        ]);
        await pumpEventQueue();
        await reportAll([2, 1]);
        expectNothingMoved(current: 2);
      });

      test('P4: offline, an unavailable advance then the core\'s onward seek '
          'reported late: no failure', () async {
        when(() => player.seek(any(), index: any(named: 'index')))
            .thenAnswer((_) async {});
        final unavailable = <UnavailableAdvance>[];
        controller?.dispose();
        controller = JustAudioEngine(player, isOfflineFn: () => true);
        subs
          ..add(controller!.commandFailures.listen(failures.add))
          ..add(controller!.unavailableAdvanceStream.listen(unavailable.add));
        await controller!.setSeed([
          _entry(itemId: 1, playPosition: 0, uuidId: 'a', filePath: '/a'),
          _entry(itemId: 2, playPosition: 1, uuidId: 'b', filePath: '/b'),
          _entry(itemId: 3, playPosition: 2, uuidId: 'c'),
          _entry(itemId: 4, playPosition: 3, uuidId: 'd', filePath: '/d'),
        ], currentItemId: 2, sessionId: 7); // b at 1
        await pumpEventQueue();
        report(2); // natural advance onto c, which has no file
        await pumpEventQueue();
        expect(unavailable.single.itemId, 3);
        await controller!
            .seekToItem(4, cause: PlaybackTransitionCause.naturalAdvance);
        await pumpEventQueue(); // the settle reads the left item's index (2)
        expect(failures, isEmpty);
        report(3);
        await pumpEventQueue();
        expect(failures, isEmpty);
        expect(controller!.currentItemId, 4);
      });

      test('P7: a stop while reports are outstanding is a certain boundary',
          () async {
        await seeded(); // b at 1
        await controller!.removeItem(1);
        await pumpEventQueue();
        seen.clear();
        await controller!.stop();
        await pumpEventQueue();
        final stop = seen
            .where((o) => o.transitionCause == PlaybackTransitionCause.stop)
            .single;
        expect(stop.uncertain, isFalse);
        expect(stop.source?.itemId, 2);
      });
    });

    // Re-check R2-1 (the playing source is the last one) and the trade-off of
    // DEV-7fixpb-05: each recorded step carries the item the plugin is on, so
    // a report naming the committed item is a certain observation even while
    // later steps' reports are outstanding.
    group('review r2: the playing source last, and certainty by item', () {
      setUp(() {
        when(() => player.seek(any(), index: any(named: 'index')))
            .thenAnswer((_) async {});
      });

      Future<void> reportAll(List<int> indices) async {
        for (final i in indices) {
          report(i);
          await pumpEventQueue();
        }
      }

      test('Q1: a quality rebuild of the last source, reported late (the '
          'plugin falls back to the item before it, then the seek)', () async {
        await seeded(current: 4); // d at 3, last
        await controller!
            .rebuildCurrentSource('320', const Duration(seconds: 30));
        await pumpEventQueue();
        await reportAll([2, 3]);
        expect(failures, isEmpty,
            reason: 'failures: ${failures.map((f) => f.reason)}');
        expect(items, isEmpty);
        expect(controller!.currentItemId, 4);
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 4);
      });

      test('Q2: a quality rebuild of the last source with only the final '
          'report: certain on the playing item', () async {
        await seeded(current: 4);
        await controller!
            .rebuildCurrentSource('320', const Duration(seconds: 30));
        await pumpEventQueue();
        await reportAll([3]);
        expect(failures, isEmpty);
        expect(items, isEmpty);
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 4);
      });

      test('Q5: a quality rebuild of the last source in the Darwin order '
          '(each report before its call returns)', () async {
        await seeded(current: 4);
        when(() => player.removeAudioSourceAt(any())).thenAnswer((inv) async {
          final index = inv.positionalArguments[0] as int;
          if (index == currentIndex && index > 0) report(index - 1);
        });
        when(() => player.seek(any(), index: any(named: 'index')))
            .thenAnswer((inv) async {
          final index = inv.namedArguments[#index] as int?;
          if (index != null) report(index);
        });
        await controller!
            .rebuildCurrentSource('320', const Duration(seconds: 30));
        await pumpEventQueue();
        expect(failures, isEmpty);
        expect(items, isEmpty);
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 4);
      });

      test('a quality rebuild of the only track: the report confirms it',
          () async {
        await controller!.setSeed(
            [_entry(itemId: 1, playPosition: 0, uuidId: 'a')],
            currentItemId: 1, sessionId: 7);
        await pumpEventQueue();
        seen.clear();
        await controller!
            .rebuildAllSources('320', const Duration(seconds: 30));
        await pumpEventQueue();
        await reportAll([0]);
        expect(failures, isEmpty);
        expect(items, isEmpty);
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 1);
      });

      test('R3-1: a quality rebuild of every source while the first item '
          'plays, reported once: confirmed, ticks certain again', () async {
        await seeded(current: 1); // a at 0
        await controller!
            .rebuildAllSources('320', const Duration(seconds: 30));
        await pumpEventQueue();
        await reportAll([0]);
        expect(failures, isEmpty);
        expect(items, isEmpty);
        expect(seen.last.uncertain, isFalse);
        seen.clear();
        positions.add(const Duration(seconds: 31));
        await pumpEventQueue();
        expect(seen.last.uncertain, isFalse,
            reason: 'no report is left outstanding');
        expect(seen.last.source?.itemId, 1);
      });

      test('the playing source replaced with only the final report (a '
          'platform that coalesces): nothing committed, no failure; the '
          'report is ambiguous (c sat at that index too), so uncertain '
          '(DEV-7fixpb-05)', () async {
        await seeded(); // b at 1
        await controller!
            .rebuildCurrentSource('320', const Duration(seconds: 30));
        await pumpEventQueue();
        await reportAll([1]);
        expect(failures, isEmpty);
        expect(items, isEmpty);
        expect(controller!.currentItemId, 2);
        expect(seen.last.uncertain, isTrue);
      });
    });

    group('after an item seek', () {
      setUp(() {
        // The seek returns before the plugin reports the new index.
        when(() => player.seek(any(), index: any(named: 'index')))
            .thenAnswer((_) async {});
      });

      test('a skip back one: the left item read late is not an advance',
          () async {
        await seeded(current: 3); // c at index 2
        await controller!.seekToItem(2); // back to b (index 1)
        await pumpEventQueue();
        // The stale index 2 (c) is b's next item.
        expect(items, [2], reason: 'only the skip itself');
        expect(controller!.currentItemId, 2);
        expect(advances(), isEmpty);
        expect(failures, isEmpty);
        report(1);
        await pumpEventQueue();
        expect(items, [2]);
        expect(failures, isEmpty);
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 2);
      });

      test('a skip forward one: the left item read late is not a failure',
          () async {
        await seeded(); // b at index 1
        await controller!.seekToItem(3); // c (index 2)
        await pumpEventQueue();
        expect(failures, isEmpty, reason: 'no needless rebuild');
        expect(controller!.currentItemId, 3);
        report(2);
        await pumpEventQueue();
        expect(failures, isEmpty);
        expect(items, [3]);
        expect(seen.last.uncertain, isFalse);
        expect(seen.last.source?.itemId, 3);
      });

      test('after the fresh report, an index past the next item is a typed '
          'failure again', () async {
        await seeded(current: 3);
        await controller!.seekToItem(2);
        await pumpEventQueue();
        report(1); // b confirmed
        await pumpEventQueue();
        report(3); // d: past b's next item
        await pumpEventQueue();
        expect(failures.single.reason,
            EngineCommandFailureReason.unexplainedIndex);
        expect(controller!.currentItemId, 2);
      });
    });

    group('U19-FE-PB-ENGINE-B-01: a source failure is not pinned on a '
        'guessed item while index reports are outstanding', () {
      late List<EngineSourceFailure> sourceFailures;
      late StreamController<ja.PlayerState> pluginStates;

      setUp(() {
        // An engine that also hears the plugin's state reports.
        pluginStates = StreamController<ja.PlayerState>.broadcast();
        when(() => player.playerStateStream)
            .thenAnswer((_) => pluginStates.stream);
        controller?.dispose();
        controller = JustAudioEngine(player);
        sourceFailures = [];
        subs.add(controller!.sourceFailures.listen(sourceFailures.add));
      });

      tearDown(() => pluginStates.close());

      test('review r1 #2: the index report never comes; the plugin stops on '
          'the failure: it is the playing item\'s', () async {
        await seeded(); // b plays at index 1
        currentIndex = 1;
        await controller!.removeItem(1); // a removed; b's report outstanding
        await pumpEventQueue();
        errorController.add(ja.PlayerException(404, 'gone', null));
        await pumpEventQueue();
        expect(sourceFailures.single.uncertain, isTrue);

        when(() => player.processingState)
            .thenReturn(ja.ProcessingState.idle);
        pluginStates.add(ja.PlayerState(false, ja.ProcessingState.idle));
        await pumpEventQueue();
        expect(sourceFailures, hasLength(2),
            reason: 'released when the plugin stops, not held for ever');
        expect(sourceFailures.last.uncertain, isFalse);
        expect(sourceFailures.last.source?.itemId, 2);
      });

      test('review r1 #2: the plugin had already stopped when the failure '
          'came: it is the playing item\'s at once', () async {
        await seeded();
        currentIndex = 1;
        await controller!.removeItem(1);
        await pumpEventQueue();
        when(() => player.processingState)
            .thenReturn(ja.ProcessingState.idle);
        errorController.add(ja.PlayerException(404, 'gone', null));
        await pumpEventQueue();
        expect(sourceFailures, hasLength(2));
        expect(sourceFailures.first.uncertain, isTrue);
        expect(sourceFailures.last.uncertain, isFalse);
        expect(sourceFailures.last.source?.itemId, 2);
      });

      test('ordinary state (nothing outstanding): the playing track\'s '
          'failure is attributed at once, as before', () async {
        await seeded(); // b plays at index 1
        currentIndex = 1;
        when(() => player.processingState)
            .thenReturn(ja.ProcessingState.idle);
        errorController.add(ja.PlayerException(404, 'gone', null));
        await pumpEventQueue();
        expect(sourceFailures, hasLength(1));
        expect(sourceFailures.single.uncertain, isFalse);
        expect(sourceFailures.single.source?.itemId, 2);
        expect(sourceFailures.single.source?.trackUuid, 'b');
      });

      test('a failure while the remove\'s index report is outstanding is '
          'uncertain, then attributed to the playing item once the report '
          'arrives and the plugin stopped on it', () async {
        await seeded(); // b plays at index 1
        currentIndex = 1;
        await controller!.removeItem(1); // a removed; b moves to index 0
        await pumpEventQueue();
        // The Dart-side index still says 1, which now names c.
        errorController.add(ja.PlayerException(404, 'gone', null));
        await pumpEventQueue();
        expect(sourceFailures, hasLength(1));
        expect(sourceFailures.single.uncertain, isTrue,
            reason: 'index 1 is stale: c must not be blamed');
        expect(sourceFailures.single.source, isNull);

        when(() => player.processingState)
            .thenReturn(ja.ProcessingState.idle);
        report(0); // the plugin's fresh report: b
        await pumpEventQueue();
        expect(sourceFailures, hasLength(2),
            reason: 'the held failure is released once the plugin is proven');
        expect(sourceFailures.last.uncertain, isFalse);
        expect(sourceFailures.last.source?.itemId, 2);
        expect(sourceFailures.last.errorCode, 404);
      });

      test('the same, but the plugin plays on: the failure was another '
          'source\'s and nothing more is said', () async {
        await seeded();
        currentIndex = 1;
        await controller!.removeItem(1);
        await pumpEventQueue();
        errorController.add(ja.PlayerException(404, 'gone', null));
        await pumpEventQueue();
        expect(sourceFailures.single.uncertain, isTrue);
        report(0);
        await pumpEventQueue();
        expect(sourceFailures, hasLength(1));
      });
    });
  });

  // 7P.1: commands the engine sends the plugin directly are typed too. Only a
  // failed pause leaves the output untrusted (it may still be audible).
  group('7P.1 direct command failures', () {
    late List<EngineCommandFailure> failures;
    late List<EngineTransportState> transport;
    final subs = <StreamSubscription<Object?>>[];

    setUp(() {
      when(() => player.play()).thenAnswer((_) async {});
      failures = [];
      transport = [];
      subs
        ..add(controller!.commandFailures.listen(failures.add))
        ..add(controller!.transportStateStream.listen(transport.add));
    });

    tearDown(() async {
      for (final sub in subs) {
        await sub.cancel();
      }
      subs.clear();
    });

    Future<void> seeded() async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1'),
      ], currentItemId: 1, sessionId: 7);
      await pumpEventQueue();
    }

    test('a play the plugin refuses is typed and clears the desired play',
        () async {
      await seeded();
      when(() => player.play())
          .thenAnswer((_) async => throw ja.PlayerException(9, 'no session', 0));
      await controller!.play();
      await pumpEventQueue();
      final failure = failures.single;
      expect(failure.command, EngineCommand.play);
      expect(failure.reason, EngineCommandFailureReason.failed);
      expect(failure.diverged, isFalse);
      expect(failure.target?.itemId, 1);
      expect(failure.errorCode, 9);
      expect(transport.last.playing, isFalse);
    });

    test('a refused play does not cancel a newer pause-then-play', () async {
      await seeded();
      final refused = Completer<void>();
      var calls = 0;
      when(() => player.play()).thenAnswer((_) {
        calls++;
        return calls == 1 ? refused.future : Completer<void>().future;
      });
      await controller!.play();
      await pumpEventQueue();
      await controller!.pause();
      await controller!.play();
      await pumpEventQueue();
      refused.completeError(ja.PlayerException(9, 'late', 0));
      await pumpEventQueue();
      expect(transport.last.playing, isTrue, reason: 'the newer play stands');
    });

    test('a failed pause is typed and diverged', () async {
      await seeded();
      when(() => player.pause())
          .thenAnswer((_) async => throw StateError('stuck'));
      await controller!.pause();
      await pumpEventQueue();
      expect(failures.single.command, EngineCommand.pause);
      expect(failures.single.diverged, isTrue);
      expect(failures.single.target?.itemId, 1);
    });

    test('stop, loop mode and volume failures are typed, not diverged',
        () async {
      await seeded();
      when(() => player.stop()).thenAnswer((_) async => throw StateError('s'));
      when(() => player.setLoopMode(any()))
          .thenAnswer((_) async => throw StateError('l'));
      when(() => player.setVolume(any()))
          .thenAnswer((_) async => throw StateError('v'));
      await controller!.setLoopMode(EngineLoopMode.all);
      await controller!.setVolume(0.5);
      await controller!.stop();
      await pumpEventQueue();
      expect(failures.map((f) => f.command), [
        EngineCommand.setLoopMode,
        EngineCommand.setVolume,
        EngineCommand.stop,
      ]);
      expect(failures.every((f) => !f.diverged), isTrue);
      expect(failures.every((f) => f.reason == EngineCommandFailureReason.failed),
          isTrue);
    });
  });

  // 7P.1 (5B.0d m5): the core acknowledges window coverage only once the
  // engine reports the native work applied.
  group('7P.1 whenApplied', () {
    setUp(() => when(() => player.play()).thenAnswer((_) async {}));

    Future<void> seeded() async {
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, sessionId: 7);
      await pumpEventQueue();
    }

    Future<bool?> settle(Future<bool> applied) async {
      bool? result;
      unawaited(applied.then((r) => result = r));
      await pumpEventQueue();
      return result;
    }

    test('completes true once issued work has applied natively', () async {
      await seeded();
      final insert = Completer<void>();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => insert.future);
      await controller!.addEntries([_entry(itemId: 2, playPosition: 1)]);
      final applied = controller!.whenApplied();
      expect(await settle(applied), isNull, reason: 'still in flight');
      insert.complete();
      expect(await settle(applied), isTrue);
    });

    test('completes false when the work failed', () async {
      await seeded();
      when(() => player.insertAudioSource(any(), any()))
          .thenThrow(StateError('refused'));
      await controller!.addEntries([_entry(itemId: 2, playPosition: 1)]);
      expect(await settle(controller!.whenApplied()), isFalse);
    });

    test('completes false at once when a newer seed replaces stalled work',
        () async {
      await seeded();
      when(() => player.insertAudioSource(any(), any()))
          .thenAnswer((_) => Completer<void>().future); // never applies
      await controller!.addEntries([_entry(itemId: 2, playPosition: 1)]);
      final applied = controller!.whenApplied();
      await controller!.setSeed([_entry(itemId: 5, playPosition: 0)],
          currentItemId: 5, sessionId: 8);
      expect(await settle(applied), isFalse);
    });
  });

  // 7P.1 review r1 (R1-03): the seeks that follow a source replacement go
  // through the same dropped-seek check.
  group('7P.1 review r1 engine', () {
    late List<EngineCommandFailure> failures;
    late StreamSubscription<EngineCommandFailure> sub;

    setUp(() {
      when(() => player.play()).thenAnswer((_) async {});
      failures = [];
      sub = controller!.commandFailures.listen(failures.add);
    });

    tearDown(() => sub.cancel());

    for (final all in [false, true]) {
      test('R1-03: a ${all ? 'full' : 'current-source'} quality rebuild whose '
          'seek is dropped while loading is a typed failure', () async {
        await controller!.setSeed([
          _entry(itemId: 1, playPosition: 0, uuidId: 'u1'),
          _entry(itemId: 2, playPosition: 1, uuidId: 'u2'),
        ], currentItemId: 1, sessionId: 7);
        await pumpEventQueue();
        when(() => player.processingState)
            .thenReturn(ja.ProcessingState.loading);
        if (all) {
          await controller!.rebuildAllSources('low', const Duration(seconds: 9));
        } else {
          await controller!
              .rebuildCurrentSource('low', const Duration(seconds: 9));
        }
        await pumpEventQueue();
        expect(failures.single.command, EngineCommand.seek);
        expect(failures.single.reason, EngineCommandFailureReason.dropped);
        expect(failures.single.position, const Duration(seconds: 9));
        expect(failures.single.target?.itemId, 1);
      });
    }

    test('R2-01: after a failed pause the next seed resets the plugin first, '
        'with no stop observation', () async {
      final calls = <String>[];
      when(() => player.stop()).thenAnswer((_) async => calls.add('stop'));
      when(() => player.setAudioSources(any(),
              initialIndex: any(named: 'initialIndex'),
              initialPosition: any(named: 'initialPosition')))
          .thenAnswer((_) async {
        calls.add('load');
        return const Duration(minutes: 3);
      });
      final seen = <PlaybackObservation>[];
      final obs = controller!.observations.listen(seen.add);
      addTearDown(obs.cancel);
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, sessionId: 7);
      await pumpEventQueue();
      when(() => player.pause())
          .thenAnswer((_) async => throw StateError('stuck'));
      await controller!.pause();
      await pumpEventQueue();
      calls.clear();
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, sessionId: 7);
      await pumpEventQueue();
      expect(calls, ['stop', 'load']);
      expect(
          seen.where((o) => o.transitionCause == PlaybackTransitionCause.stop),
          isEmpty);
      calls.clear();
      await controller!.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, sessionId: 7);
      await pumpEventQueue();
      expect(calls, ['load'], reason: 'only once');
    });

    test('R2-01: the reset after a failed pause survives a later ready report',
        () async {
      final states = StreamController<ja.PlayerState>.broadcast();
      addTearDown(states.close);
      when(() => player.playerStateStream).thenAnswer((_) => states.stream);
      final engine = JustAudioEngine(player);
      addTearDown(engine.dispose);
      final calls = <String>[];
      when(() => player.stop()).thenAnswer((_) async => calls.add('stop'));
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, sessionId: 7);
      await pumpEventQueue();
      when(() => player.pause())
          .thenAnswer((_) async => throw StateError('stuck'));
      await engine.pause();
      await pumpEventQueue();
      // The plugin still reports a ready (possibly still audible) player.
      states.add(ja.PlayerState(true, ja.ProcessingState.ready));
      await pumpEventQueue();
      await engine.setSeed([_entry(itemId: 1, playPosition: 0)],
          currentItemId: 1, sessionId: 7);
      await pumpEventQueue();
      expect(calls, contains('stop'));
    });
  });

  // 7P.2 (SC-27 §6 "one local-vs-remote decision point"): the resolver
  // decides, the engine applies the target's source kind and never
  // second-guesses it from the recorded download.
  group('7P.2 the engine applies the target source kind', () {
    setUp(() => when(() => player.play()).thenAnswer((_) async {}));

    List<Uri> seededUris() {
      final sources = verify(
        () => player.setAudioSources(
          captureAny(),
          initialIndex: any(named: 'initialIndex'),
          initialPosition: any(named: 'initialPosition'),
        ),
      ).captured.last as List<ja.AudioSource>;
      return [for (final s in sources) (s as ja.UriAudioSource).uri];
    }

    test('a remote target with a recorded download streams; the window '
        'around it keeps the rule\'s plan', () async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1', filePath: '/dl/u1'),
        _entry(itemId: 2, playPosition: 1, uuidId: 'u2', filePath: '/dl/u2'),
      ], currentItemId: 1, currentSourceKind: PlaybackSourceKind.remote);
      await pumpEventQueue();

      final uris = seededUris();
      expect(uris[0].scheme, isNot('file'),
          reason: 'the target said remote: no file is read');
      expect(uris[0].path, endsWith('tracks/u1/stream'));
      expect(uris[1].scheme, 'file',
          reason: 'a neighbour nobody landed on is built by the rule');
      expect(uris[1].toFilePath(), '/dl/u2');
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.remote);
      expect(controller!.sourceKindOf(2), PlaybackSourceKind.local);
      expect(controller!.sourceKindOf(3), isNull, reason: 'not loaded');
    });

    test('a local target plays its recorded file', () async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1', filePath: '/dl/u1'),
      ], currentItemId: 1, currentSourceKind: PlaybackSourceKind.local);
      await pumpEventQueue();

      final uri = seededUris().single;
      expect(uri.scheme, 'file');
      expect(uri.toFilePath(), '/dl/u1');
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.local);
    });

    test('the source identity and a failure of it report the applied kind, '
        'not the recorded download', () async {
      final commandFailures = <EngineCommandFailure>[];
      final sourceFailures = <EngineSourceFailure>[];
      final subs = [
        controller!.commandFailures.listen(commandFailures.add),
        controller!.sourceFailures.listen(sourceFailures.add),
      ];
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1', filePath: '/dl/u1'),
      ], currentItemId: 1, sessionId: 3,
          currentSourceKind: PlaybackSourceKind.remote);
      await pumpEventQueue();

      errorController.add(ja.PlayerException(0, 'boom', 0));
      await pumpEventQueue();
      final source = sourceFailures.single.source!;
      expect(source.localPath, isNull);
      expect(source.sourceKind, PlaybackSourceKind.remote);

      when(() => player.pause())
          .thenAnswer((_) async => throw StateError('stuck'));
      await controller!.pause();
      await pumpEventQueue();
      expect(commandFailures.single.target,
          const EngineCommandTarget(
              itemId: 1,
              trackUuid: 'u1',
              sourceKind: PlaybackSourceKind.remote));
      for (final sub in subs) {
        await sub.cancel();
      }
    });

    // 5B.0d m6: a failed load is classified by the source the engine
    // built, so the load event names it.
    for (final (kind, path) in [
      (PlaybackSourceKind.remote, null),
      (null, '/dl/u1'),
    ]) {
      test('a failed load names the seeded current source '
          '(${kind?.name ?? 'rule'})', () async {
        when(() => player.setAudioSources(any(),
                initialIndex: any(named: 'initialIndex'),
                initialPosition: any(named: 'initialPosition')))
            .thenThrow(ja.PlayerException(0, 'cannot load', 0));
        final events = <EngineLoadEvent>[];
        final sub = controller!.loadEvents.listen(events.add);
        await controller!.setSeed([
          _entry(itemId: 1, playPosition: 0, uuidId: 'u1', filePath: '/dl/u1'),
          _entry(itemId: 2, playPosition: 1, uuidId: 'u2'),
        ], currentItemId: 1, sessionId: 3, currentSourceKind: kind);
        await pumpEventQueue();
        final failed = events
            .where((e) => e.outcome == EngineLoadOutcome.failed)
            .single;
        expect(failed.source?.itemId, 1);
        expect(failed.source?.trackUuid, 'u1');
        expect(failed.source?.sessionId, 3);
        expect(failed.source?.localPath, path);
        await sub.cancel();
      });
    }

    test('without a given kind the seed keeps the rule\'s plan', () async {
      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1', filePath: '/dl/u1'),
      ], currentItemId: 1);
      await pumpEventQueue();
      expect(seededUris().single.scheme, 'file');
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.local);
    });
  });

  // 7P.2: a rebuild re-decides nothing behind the resolver's back. A source
  // keeps the kind the engine applied unless the rule's own verdict for its
  // entry changed since it was built (a new download, a deletion, a suspect).
  group('7P.2 engine rebuilds keep the applied kind', () {
    late List<String> calls;
    late List<(int, Uri)> inserted;

    setUp(() async {
      when(() => player.play()).thenAnswer((_) async {});
      calls = [];
      inserted = [];
      when(() => player.removeAudioSourceAt(any())).thenAnswer((i) async {
        calls.add('remove@${i.positionalArguments[0]}');
      });
      when(() => player.insertAudioSource(any(), any())).thenAnswer((i) async {
        calls.add('insert@${i.positionalArguments[0]}');
        inserted.add((i.positionalArguments[0] as int,
            (i.positionalArguments[1] as ja.UriAudioSource).uri));
      });
    });

    final recorded =
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1', filePath: '/dl/u1');
    final streamed = _entry(itemId: 2, playPosition: 1, uuidId: 'u2');

    Future<void> seedRemote() async {
      await controller!.setSeed([recorded, streamed],
          currentItemId: 1, currentSourceKind: PlaybackSourceKind.remote);
      await pumpEventQueue();
    }

    test('an availability refresh with an unchanged verdict keeps a remote '
        'target streaming', () async {
      await seedRemote();
      await controller!
          .refreshLoadedSourcesForAvailabilityChanges([recorded, streamed]);
      await pumpEventQueue();
      expect(calls, isEmpty, reason: 'nothing changed for the rule');
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.remote);
    });

    test('a refresh after a new download is new evidence: it plays the file',
        () async {
      await seedRemote();
      await controller!.refreshLoadedSourcesForAvailabilityChanges([
        _entry(itemId: 1, playPosition: 0, uuidId: 'u1', filePath: '/dl/u1b'),
      ]);
      await pumpEventQueue();
      expect(inserted.single.$2.toFilePath(), '/dl/u1b');
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.local);
    });

    test('a quality rebuild of the current source keeps it a stream',
        () async {
      await seedRemote();
      await controller!.rebuildCurrentSource('320', Duration.zero);
      await pumpEventQueue();
      expect(inserted.single.$2.scheme, isNot('file'));
      expect(inserted.single.$2.queryParameters['quality'], '320');
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.remote);
    });

    // Review r1 R1-02: a changed verdict that needs no rebuild is still
    // remembered, so a later re-download to the same path is new evidence.
    test('a re-download to the same path after the claim was cleared plays '
        'the file', () async {
      await seedRemote();
      final cleared = _entry(itemId: 1, playPosition: 0, uuidId: 'u1');
      await controller!.refreshLoadedSourcesForAvailabilityChanges([cleared]);
      await pumpEventQueue();
      expect(calls, isEmpty, reason: 'still a stream: nothing to rebuild');
      await controller!.refreshLoadedSourcesForAvailabilityChanges([recorded]);
      await pumpEventQueue();
      expect(inserted.single.$2.toFilePath(), '/dl/u1');
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.local);
    });

    // Review r1 R1-01: a kept `local` never bypasses the rule: a download
    // suspected since is not reloaded by a reseed without a new decision.
    test('a local kind for a suspected download builds the stream', () async {
      final policy = LocalSourcePolicy();
      final engine = JustAudioEngine(player, localSources: policy);
      addTearDown(engine.dispose);
      await engine.setSeed([recorded],
          currentItemId: 1, currentSourceKind: PlaybackSourceKind.local);
      await pumpEventQueue();
      expect(engine.sourceKindOf(1), PlaybackSourceKind.local);
      policy.suspect('u1', '/dl/u1');
      await engine.setSeed([recorded],
          currentItemId: 1, currentSourceKind: PlaybackSourceKind.local);
      await pumpEventQueue();
      final sources = verify(() => player.setAudioSources(captureAny(),
              initialIndex: any(named: 'initialIndex'),
              initialPosition: any(named: 'initialPosition')))
          .captured
          .last as List<ja.AudioSource>;
      expect((sources.single as ja.UriAudioSource).uri.scheme, isNot('file'));
      expect(engine.sourceKindOf(1), PlaybackSourceKind.remote);
    });

    test('a full quality rebuild keeps every applied kind', () async {
      await seedRemote();
      await controller!.rebuildAllSources('320', Duration.zero);
      await pumpEventQueue();
      expect([for (final (_, uri) in inserted) uri.scheme != 'file'],
          [true, true]);
      expect(controller!.sourceKindOf(1), PlaybackSourceKind.remote);
    });
  });
}

QueuePlaybackEntry _entry({
  required int itemId,
  required int playPosition,
  String queueType = QueueItemTypes.main,
  int canonicalPosition = 0,
  String uuidId = 'track-1',
  String? filePath,
}) {
  return QueuePlaybackEntry(
    itemId: itemId,
    queueType: queueType,
    canonicalPosition: canonicalPosition,
    playPosition: playPosition,
    uuidId: uuidId,
    filePath: filePath,
  );
}
