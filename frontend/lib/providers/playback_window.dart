import 'dart:math';

import 'package:frontend/models/ui/track_ui.dart';

class PlaybackWindowPlan {
  final List<TrackUI> tracks;
  final int currentIndex;

  const PlaybackWindowPlan({required this.tracks, required this.currentIndex});
}

PlaybackWindowPlan buildPlaybackWindowPlan({
  required TrackUI current,
  required List<TrackUI> previousCandidates,
  required List<TrackUI> nextCandidates,
  int windowSize = 5,
  int preferredNeighborsPerSide = 2,
}) {
  if (windowSize < 1) {
    throw ArgumentError.value(windowSize, 'windowSize', 'Must be positive.');
  }
  if (preferredNeighborsPerSide < 0) {
    throw ArgumentError.value(
      preferredNeighborsPerSide,
      'preferredNeighborsPerSide',
      'Cannot be negative.',
    );
  }

  var previousCount = min(preferredNeighborsPerSide, previousCandidates.length);
  var nextCount = min(preferredNeighborsPerSide, nextCandidates.length);
  var remainingSlots = windowSize - 1 - previousCount - nextCount;

  if (remainingSlots > 0) {
    final extraNext = min(remainingSlots, nextCandidates.length - nextCount);
    nextCount += extraNext;
    remainingSlots -= extraNext;
  }

  if (remainingSlots > 0) {
    final extraPrevious = min(
      remainingSlots,
      previousCandidates.length - previousCount,
    );
    previousCount += extraPrevious;
  }

  final previousTracks = previousCandidates
      .take(previousCount)
      .toList()
      .reversed
      .toList(growable: false);
  final nextTracks = nextCandidates.take(nextCount).toList(growable: false);

  return PlaybackWindowPlan(
    tracks: [...previousTracks, current, ...nextTracks],
    currentIndex: previousTracks.length,
  );
}
