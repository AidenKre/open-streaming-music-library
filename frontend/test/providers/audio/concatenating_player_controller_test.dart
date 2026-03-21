import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:mocktail/mocktail.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/audio/concatenating_player_controller.dart';
import 'package:frontend/repositories/queue_repository.dart';

class MockAudioPlayer extends Mock implements ja.AudioPlayer {}

class FakeAudioSource extends Fake implements ja.AudioSource {}

void main() {
  late MockAudioPlayer player;
  late StreamController<int?> currentIndexController;
  late int currentIndex;
  ConcatenatingPlayerController? controller;

  setUpAll(() {
    registerFallbackValue(FakeAudioSource());
    registerFallbackValue(Duration.zero);
    registerFallbackValue(ja.LoopMode.off);
    ApiClient.init('http://test:8080');
  });

  setUp(() {
    player = MockAudioPlayer();
    currentIndexController = StreamController<int?>.broadcast();
    currentIndex = 0;
    when(
      () => player.setAudioSources(
        any(),
        initialIndex: any(named: 'initialIndex'),
        initialPosition: any(named: 'initialPosition'),
      ),
    ).thenAnswer((_) async => const Duration(minutes: 3));
    when(
      () => player.seek(any(), index: any(named: 'index')),
    ).thenAnswer((_) async {});
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

    controller = ConcatenatingPlayerController(player);
  });

  tearDown(() {
    controller?.dispose();
    currentIndexController.close();
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

      when(() => player.removeAudioSourceAt(any())).thenAnswer((_) async {
        currentIndex = 0;
        currentIndexController.add(0);
      });
      when(() => player.insertAudioSource(any(), any())).thenAnswer((_) async {
        currentIndex = 1;
        currentIndexController.add(1);
      });

      await controller!.setSeed([
        _entry(itemId: 1, playPosition: 0),
        _entry(itemId: 2, playPosition: 1),
        _entry(itemId: 3, playPosition: 2),
      ], currentItemId: 2);

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

      expect(emittedItemIds, isEmpty);
      expect(controller!.currentItemId, 2);

      currentIndex = 3;
      currentIndexController.add(3);
      await Future<void>.delayed(Duration.zero);

      expect(emittedItemIds, [5]);
      await sub.cancel();
    },
  );
}

QueuePlaybackEntry _entry({
  required int itemId,
  required int playPosition,
  String queueType = QueueItemTypes.main,
  int canonicalPosition = 0,
  String uuidId = 'track-1',
}) {
  return QueuePlaybackEntry(
    itemId: itemId,
    queueType: queueType,
    canonicalPosition: canonicalPosition,
    playPosition: playPosition,
    uuidId: uuidId,
  );
}
