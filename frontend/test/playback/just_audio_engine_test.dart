import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/playback/just_audio_engine.dart';
import 'package:frontend/playback/playback_engine.dart';
import 'package:frontend/repositories/queue_repository.dart';

class MockAudioPlayer extends Mock implements ja.AudioPlayer {}

class FakeAudioSource extends Fake implements ja.AudioSource {}

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
    ApiClient.init('http://test:8080');
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
      currentIndex = 2;
      currentIndexController.add(2);
      await pumpEventQueue();
      expect(items, [12], reason: 'indices map onto the new seed only');
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
