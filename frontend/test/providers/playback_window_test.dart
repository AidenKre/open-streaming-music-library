import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/window_manager.dart';

TrackUI _track(String uuid) {
  return TrackUI(
    uuidId: uuid,
    createdAt: 0,
    lastUpdated: 0,
    duration: 180,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );
}

void main() {
  group('buildPlaybackWindowPlan', () {
    test('keeps the current track centered when both sides have neighbors', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('c'),
        previousCandidates: [_track('p1'), _track('p2'), _track('p3')],
        nextCandidates: [_track('n1'), _track('n2'), _track('n3')],
        windowSize: 5,
        preferredNeighbors: 2,
      );

      expect(plan.tracks.map((track) => track.uuidId).toList(), [
        'p2',
        'p1',
        'c',
        'n1',
        'n2',
      ]);
      expect(plan.currentIndex, 2);
    });

    test('keeps a wrapped first album track centered in the window', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('a'),
        previousCandidates: [_track('e'), _track('d'), _track('c')],
        nextCandidates: [_track('b'), _track('c'), _track('d')],
        windowSize: 5,
        preferredNeighbors: 2,
      );

      expect(plan.tracks.map((track) => track.uuidId).toList(), [
        'd',
        'e',
        'a',
        'b',
        'c',
      ]);
      expect(plan.currentIndex, 2);
    });

    test('fills extra slots from the next side near the queue start', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('c'),
        previousCandidates: const [],
        nextCandidates: [
          _track('n1'),
          _track('n2'),
          _track('n3'),
          _track('n4'),
        ],
        windowSize: 5,
        preferredNeighbors: 2,
      );

      expect(plan.tracks.map((track) => track.uuidId).toList(), [
        'c',
        'n1',
        'n2',
        'n3',
        'n4',
      ]);
      expect(plan.currentIndex, 0);
    });

    test('fills extra slots from the previous side near the queue end', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('c'),
        previousCandidates: [
          _track('p1'),
          _track('p2'),
          _track('p3'),
          _track('p4'),
        ],
        nextCandidates: const [],
        windowSize: 5,
        preferredNeighbors: 2,
      );

      expect(plan.tracks.map((track) => track.uuidId).toList(), [
        'p4',
        'p3',
        'p2',
        'p1',
        'c',
      ]);
      expect(plan.currentIndex, 4);
    });

    test(
      'returns the available neighbors when there are fewer than five tracks',
      () {
        final plan = buildPlaybackWindowPlan(
          current: _track('c'),
          previousCandidates: [_track('p1')],
          nextCandidates: [_track('n1')],
        );

        expect(plan.tracks.map((track) => track.uuidId).toList(), [
          'p1',
          'c',
          'n1',
        ]);
        expect(plan.currentIndex, 1);
      },
    );

    test('window size 3 with balanced neighbors', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('c'),
        previousCandidates: [_track('p1'), _track('p2')],
        nextCandidates: [_track('n1'), _track('n2')],
      );

      expect(plan.tracks.map((track) => track.uuidId).toList(), [
        'p1',
        'c',
        'n1',
      ]);
      expect(plan.currentIndex, 1);
    });

    test('window size 3 fills next when no previous', () {
      final plan = buildPlaybackWindowPlan(
        current: _track('c'),
        previousCandidates: const [],
        nextCandidates: [_track('n1'), _track('n2'), _track('n3')],
      );

      expect(plan.tracks.map((track) => track.uuidId).toList(), [
        'c',
        'n1',
        'n2',
      ]);
      expect(plan.currentIndex, 0);
    });
  });
}
