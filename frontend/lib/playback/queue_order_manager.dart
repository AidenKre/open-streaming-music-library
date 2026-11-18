import 'dart:math';

import 'package:frontend/repositories/queue_repository.dart';

class QueueOrderManager {
  final QueueRepository _queueRepo;
  final Random _random;

  QueueOrderManager(this._queueRepo, [Random? random])
      : _random = random ?? Random();

  static List<int> shuffleItems(List<int> itemIds, [Random? random]) {
    final shuffled = List<int>.from(itemIds);
    shuffled.shuffle(random ?? Random());
    return shuffled;
  }

  /// The full initial shuffled order of [canonical]: a uniformly random member
  /// first (the injected generator's first draw), then a random permutation of
  /// all the others. Duplicates are kept; [canonical] is never mutated.
  List<T> initializeShuffled<T>(List<T> canonical) {
    if (canonical.isEmpty) return <T>[];
    final firstIndex = _random.nextInt(canonical.length);
    final rest = <T>[
      for (var i = 0; i < canonical.length; i++)
        if (i != firstIndex) canonical[i],
    ]..shuffle(_random);
    return [canonical[firstIndex], ...rest];
  }

  /// Whether the main items of [entries] are in canonical order (manual items
  /// are ignored).
  static bool _mainOrderIsCanonical(
      List<QueuePlaybackEntry> entries, List<int> canonicalMainIds) {
    final mainIds = [
      for (final e in entries)
        if (e.queueType == QueueItemTypes.main) e.itemId,
    ];
    if (mainIds.length != canonicalMainIds.length) return false;
    for (var i = 0; i < mainIds.length; i++) {
      if (mainIds[i] != canonicalMainIds[i]) return false;
    }
    return true;
  }

  /// The shuffle-off order (sign-off DEV-6-01, owner 2026-11-17): the whole
  /// play order of [sessionId] returns to its original (canonical) order,
  /// behind and ahead of the current item. The current item keeps playing and
  /// simply sits at its original position, so Previous walks back through the
  /// original order. The canonical order is the source's order: album/artist
  /// track order, the track list or search result order, the query's sort
  /// order, and a future playlist's order (`queue_session_items.position` of
  /// the `main` items).
  ///
  /// Queued items (Play next / Add to queue, `manual` items, not part of the
  /// canonical order): each stays right after the main item it followed in
  /// the play order, whether already played, current, or still ahead; manual
  /// items before any main item stay first. Item ids are the identity, so
  /// duplicated tracks go back to their own positions. No item is ever
  /// dropped.
  ///
  /// Returns false, writing nothing, when the main items are already
  /// canonical (the manual placement is then already right).
  ///
  /// Cases (album a b c d e; queued items x, y):
  ///
  ///   play order before (situation)         | after          | current
  ///   --------------------------------------+----------------+-------------
  ///   a c e b d (heard a then c)            | a b c d e      | c (index 2)
  ///   c a e b d                             | a b c d e      | a (index 0)
  ///   c x ... (x via Play next at c)        | a b c x d e    | c or x
  ///   x, y via Add to queue at c            | a b c x y d e  | -
  ///   d x b y e a c (x after d, y after b)  | a b y c d x e  | b (index 1)
  ///   e a c x d b (x queued at c, then      | a b c x d e    | e (index 5)
  ///     went back to e)                     |                |
  ///   d b x y e a c (x followed b)          | a b x y c d e  | x (index 2)
  Future<bool> restoreCanonicalOrder(int sessionId) async {
    final entries = await _queueRepo.getPlaybackEntries(sessionId);
    final canonicalMainIds = await _queueRepo.getCanonicalItemIds(sessionId);
    if (_mainOrderIsCanonical(entries, canonicalMainIds)) return false;

    final leading = <int>[];
    final groups = <int, List<int>>{};
    int? lastMain;
    for (final entry in entries) {
      if (entry.queueType == QueueItemTypes.main) {
        lastMain = entry.itemId;
      } else if (lastMain == null) {
        leading.add(entry.itemId);
      } else {
        groups.putIfAbsent(lastMain, () => <int>[]).add(entry.itemId);
      }
    }

    await _queueRepo.replacePlayOrder(sessionId, [
      ...leading,
      for (final id in canonicalMainIds) ...[id, ...?groups[id]],
    ]);
    return true;
  }

  /// Rebuilds the play order of [sessionId] around [currentItemId], for every
  /// queue: the played prefix (entries up to and including the current item)
  /// is kept as played, the future manual items come next, then the unplayed
  /// main items. Those are kept in their current order when preserving a
  /// shuffled future, else put in canonical order, or reshuffled with the
  /// injected generator when shuffle is on. Item ids are the identity, so a
  /// duplicated track is two items.
  Future<void> rebuildEffectiveOrder(
    int sessionId, {
    required int currentItemId,
    required bool preserveShuffledMainFuture,
    bool? shuffleMainFuture,
    required bool isShuffleOn,
  }) async {
    final entries = await _queueRepo.getPlaybackEntries(sessionId);
    if (entries.isEmpty) return;

    final currentIndex = entries.indexWhere(
      (entry) => entry.itemId == currentItemId,
    );
    if (currentIndex < 0) return;

    final prefixIds = entries
        .take(currentIndex + 1)
        .map((entry) => entry.itemId)
        .toList(growable: false);
    final playedIds = prefixIds.toSet();
    final manualIds = await _queueRepo.getQueueTypeItemIds(
      sessionId,
      QueueItemTypes.manual,
    );
    final futureManualIds = manualIds
        .where((itemId) => !playedIds.contains(itemId))
        .toList(growable: false);

    final List<int> futureMainItemIds;
    if (preserveShuffledMainFuture) {
      futureMainItemIds = entries
          .skip(currentIndex + 1)
          .where(
            (entry) =>
                entry.queueType == QueueItemTypes.main &&
                !playedIds.contains(entry.itemId),
          )
          .map((entry) => entry.itemId)
          .toList(growable: false);
    } else {
      final canonicalMainIds = await _queueRepo.getCanonicalItemIds(sessionId);
      final unplayed = canonicalMainIds
          .where((itemId) => !playedIds.contains(itemId))
          .toList(growable: false);
      futureMainItemIds = (shuffleMainFuture ?? isShuffleOn)
          ? shuffleItems(unplayed, _random)
          : unplayed;
    }

    await _queueRepo.replacePlayOrder(sessionId, [
      ...prefixIds,
      ...futureManualIds,
      ...futureMainItemIds,
    ]);
  }
}
