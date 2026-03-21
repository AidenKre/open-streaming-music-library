import 'dart:math';

import 'package:frontend/repositories/queue_repository.dart';

class QueueOrderManager {
  final QueueRepository _queueRepo;

  QueueOrderManager(this._queueRepo);

  static List<int> shuffleItems(List<int> itemIds, [Random? random]) {
    final shuffled = List<int>.from(itemIds);
    shuffled.shuffle(random ?? Random());
    return shuffled;
  }

  Future<void> rebuildEffectiveOrder(
    int sessionId, {
    required int currentItemId,
    required bool preserveShuffledMainFuture,
    bool? shuffleMainFuture,
    required bool isShuffleOn,
  }) async {
    final snapshot = await _queueRepo.getSessionSnapshot(sessionId);
    if (snapshot == null) return;

    final entries = await _queueRepo.getPlaybackEntries(sessionId);
    if (entries.isEmpty) return;

    final currentIndex = entries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (currentIndex < 0) return;

    final currentEntry = entries[currentIndex];
    final canonicalMainIds = await _queueRepo.getCanonicalItemIds(sessionId);
    final manualIds = await _queueRepo.getQueueTypeItemIds(
      sessionId,
      QueueItemTypes.manual,
    );

    if (preserveShuffledMainFuture) {
      final preservedPrefixIds = entries
          .take(currentIndex + 1)
          .map((entry) => entry.itemId)
          .toList(growable: false);
      final excludedIds = preservedPrefixIds.toSet();
      final futureManualIds = manualIds
          .where((itemId) => !excludedIds.contains(itemId))
          .toList(growable: false);
      final futureMainItemIds = entries
          .skip(currentIndex + 1)
          .where(
            (entry) =>
                entry.queueType == QueueItemTypes.main &&
                !excludedIds.contains(entry.itemId),
          )
          .map((entry) => entry.itemId)
          .toList(growable: false);

      await _queueRepo.replacePlayOrder(sessionId, [
        ...preservedPrefixIds,
        ...futureManualIds,
        ...futureMainItemIds,
      ]);
      return;
    }

    final pastManualGroups = <int?, List<int>>{};
    final pastManualIds = <int>{};
    int? lastSeenMainId;

    for (final entry in entries.take(currentIndex)) {
      if (entry.queueType == QueueItemTypes.main) {
        lastSeenMainId = entry.itemId;
        continue;
      }

      pastManualGroups
          .putIfAbsent(lastSeenMainId, () => <int>[])
          .add(entry.itemId);
      pastManualIds.add(entry.itemId);
    }

    final currentIsMain = currentEntry.queueType == QueueItemTypes.main;
    final anchorMainId = currentIsMain
        ? currentItemId
        : snapshot.session.resumeMainItemId ?? lastSeenMainId;
    final anchorMainIndex = anchorMainId == null
        ? -1
        : canonicalMainIds.indexOf(anchorMainId);

    final prefixMainIds = currentIsMain
        ? canonicalMainIds.take(anchorMainIndex).toList(growable: false)
        : anchorMainIndex < 0
        ? const <int>[]
        : canonicalMainIds.take(anchorMainIndex + 1).toList(growable: false);

    var futureMainItemIds = preserveShuffledMainFuture
        ? entries
              .skip(currentIndex + 1)
              .where((entry) => entry.queueType == QueueItemTypes.main)
              .map((entry) => entry.itemId)
              .toList(growable: false)
        : anchorMainIndex < 0
        ? List<int>.from(canonicalMainIds)
        : canonicalMainIds.skip(anchorMainIndex + 1).toList(growable: false);

    final excludedManualIds = <int>{...pastManualIds};
    if (!currentIsMain) {
      excludedManualIds.add(currentItemId);
    }

    final futureManualIds = manualIds
        .where((itemId) => !excludedManualIds.contains(itemId))
        .toList(growable: false);

    final shouldShuffle = shuffleMainFuture ?? isShuffleOn;
    if (!preserveShuffledMainFuture && shouldShuffle) {
      futureMainItemIds = shuffleItems(futureMainItemIds);
    }

    final rebuiltPlayOrder = <int>[
      ...?pastManualGroups[null],
      for (final mainId in prefixMainIds) ...[
        mainId,
        ...?pastManualGroups[mainId],
      ],
      currentItemId,
      ...futureManualIds,
      ...futureMainItemIds,
    ];

    await _queueRepo.replacePlayOrder(sessionId, rebuiltPlayOrder);
  }
}
