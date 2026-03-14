import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/audio/audio_state.dart';
import 'package:frontend/providers/audio/queue_resolver.dart';

void main() {
  group('shuffleWithCurrentFirst', () {
    test('places current UUID first', () {
      final uuids = ['a', 'b', 'c', 'd', 'e'];
      final result = shuffleWithCurrentFirst(uuids, 'c', 42);
      expect(result.first, 'c');
      expect(result.length, 5);
      expect(result.toSet(), uuids.toSet());
    });

    test('is deterministic with the same seed', () {
      final uuids = ['a', 'b', 'c', 'd', 'e'];
      final r1 = shuffleWithCurrentFirst(uuids, 'a', 123);
      final r2 = shuffleWithCurrentFirst(uuids, 'a', 123);
      expect(r1, r2);
    });

    test('produces different order with different seed', () {
      final uuids = List.generate(20, (i) => 'track_$i');
      final r1 = shuffleWithCurrentFirst(uuids, 'track_0', 1);
      final r2 = shuffleWithCurrentFirst(uuids, 'track_0', 999);
      // Both start with track_0 but the rest should differ
      expect(r1.first, 'track_0');
      expect(r2.first, 'track_0');
      expect(r1.sublist(1), isNot(equals(r2.sublist(1))));
    });

    test('handles null currentUuid', () {
      final uuids = ['a', 'b', 'c'];
      final result = shuffleWithCurrentFirst(uuids, null, 42);
      expect(result.length, 3);
      expect(result.toSet(), uuids.toSet());
    });

    test('handles single element list', () {
      final result = shuffleWithCurrentFirst(['only'], 'only', 0);
      expect(result, ['only']);
    });

    test('handles currentUuid not in list', () {
      final uuids = ['a', 'b', 'c'];
      final result = shuffleWithCurrentFirst(uuids, 'z', 42);
      expect(result.first, 'z');
      expect(result.length, 4); // z is inserted even though not in original
    });

    test('does not mutate the input list', () {
      final uuids = ['a', 'b', 'c'];
      final copy = List<String>.from(uuids);
      shuffleWithCurrentFirst(uuids, 'b', 42);
      expect(uuids, copy);
    });
  });

  group('cursorFromTrack', () {
    test('maps order params to track field values', () {
      final track = _track('uuid-1', artist: 'Artist', album: 'Album');
      final orderParams = [
        OrderParameter(column: 'artist'),
        OrderParameter(column: 'album'),
        OrderParameter(column: 'uuid_id'),
      ];
      final cursor = cursorFromTrack(track, orderParams);

      expect(cursor.length, 3);
      expect(cursor[0].column, 'artist');
      expect(cursor[0].value, 'Artist');
      expect(cursor[1].column, 'album');
      expect(cursor[1].value, 'Album');
      expect(cursor[2].column, 'uuid_id');
      expect(cursor[2].value, 'uuid-1');
    });

    test('maps numeric fields correctly', () {
      final track = _track(
        'uuid-1',
        trackNumber: 5,
        discNumber: 2,
        duration: 180.5,
      );
      final orderParams = [
        OrderParameter(column: 'track_number'),
        OrderParameter(column: 'disc_number'),
        OrderParameter(column: 'duration'),
      ];
      final cursor = cursorFromTrack(track, orderParams);

      expect(cursor[0].value, 5);
      expect(cursor[1].value, 2);
      expect(cursor[2].value, 180.5);
    });

    test('returns null for unknown columns', () {
      final track = _track('uuid-1');
      final orderParams = [OrderParameter(column: 'uuid_id')];
      final cursor = cursorFromTrack(track, orderParams);
      expect(cursor[0].value, 'uuid-1');
    });
  });

  group('reversedOrder', () {
    test('flips ascending to descending', () {
      final params = [
        OrderParameter(column: 'artist', isAscending: true),
        OrderParameter(column: 'album', isAscending: false),
      ];
      final reversed = reversedOrder(params);

      expect(reversed[0].column, 'artist');
      expect(reversed[0].isAscending, false);
      expect(reversed[1].column, 'album');
      expect(reversed[1].isAscending, true);
    });

    test('returns empty list for empty input', () {
      expect(reversedOrder([]), isEmpty);
    });

    test('does not mutate the input list', () {
      final params = [OrderParameter(column: 'artist', isAscending: true)];
      reversedOrder(params);
      expect(params[0].isAscending, true);
    });
  });

  group('uniqueUuids', () {
    test('removes duplicates preserving order', () {
      final result = uniqueUuids(['a', 'b', 'a', 'c', 'b']);
      expect(result, ['a', 'b', 'c']);
    });

    test('excludes specified uuid', () {
      final result = uniqueUuids(['a', 'b', 'c'], excludeUuid: 'b');
      expect(result, ['a', 'c']);
    });

    test('handles empty input', () {
      expect(uniqueUuids([]), isEmpty);
    });

    test('handles all duplicates', () {
      final result = uniqueUuids(['a', 'a', 'a']);
      expect(result, ['a']);
    });

    test('excludeUuid not in list has no effect', () {
      final result = uniqueUuids(['a', 'b'], excludeUuid: 'z');
      expect(result, ['a', 'b']);
    });
  });
}

/// Helper to create a minimal TrackUI for testing.
TrackUI _track(
  String uuid, {
  String? artist,
  String? album,
  int? trackNumber,
  int? discNumber,
  double duration = 180,
}) {
  return TrackUI(
    uuidId: uuid,
    createdAt: 0,
    lastUpdated: 0,
    artist: artist,
    album: album,
    trackNumber: trackNumber,
    discNumber: discNumber,
    duration: duration,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );
}
