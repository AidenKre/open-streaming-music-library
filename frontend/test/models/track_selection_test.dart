import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/track_selection.dart';

/// SC-17: the selection is an ordered set of (uuid, base revision) pairs.
void main() {
  List<(String, int?)> pairs(TrackSelection s) =>
      [for (final e in s.entries) (e.uuid, e.baseRevision)];

  test('empty selection has nothing in it', () {
    const s = TrackSelection.empty();
    expect(s.isEmpty, isTrue);
    expect(s.count, 0);
    expect(s.entries, isEmpty);
    expect(s.contains('a'), isFalse);
  });

  test('toggling adds pairs in selection order with their revision', () {
    final s = const TrackSelection.empty()
        .toggled(uuid: 'b', baseRevision: 7)
        .toggled(uuid: 'a', baseRevision: 3)
        .toggled(uuid: 'c', baseRevision: 12);
    expect(pairs(s), [('b', 7), ('a', 3), ('c', 12)]);
    expect(s.count, 3);
    expect(s.isEmpty, isFalse);
    expect(s.contains('a'), isTrue);
    expect(s.contains('z'), isFalse);
  });

  test('toggling a selected uuid removes it, whatever revision is passed', () {
    final s = const TrackSelection.empty()
        .toggled(uuid: 'a', baseRevision: 1)
        .toggled(uuid: 'b', baseRevision: 2)
        .toggled(uuid: 'a', baseRevision: 99);
    expect(pairs(s), [('b', 2)]);
    expect(s.count, 1);
    expect(s.contains('a'), isFalse);
  });

  test('re-selecting appends at the end with the newly seen revision', () {
    final s = const TrackSelection.empty()
        .toggled(uuid: 'a', baseRevision: 1)
        .toggled(uuid: 'b', baseRevision: 2)
        .toggled(uuid: 'a', baseRevision: 1)
        .toggled(uuid: 'a', baseRevision: 5);
    expect(pairs(s), [('b', 2), ('a', 5)]);
  });

  test('an unknown revision stays unknown (null), never 0', () {
    final s = const TrackSelection.empty().toggled(uuid: 'a', baseRevision: null);
    expect(s.contains('a'), isTrue);
    expect(s.entries.single.baseRevision, isNull);
  });

  test('toggling returns a new value and leaves the original untouched', () {
    const empty = TrackSelection.empty();
    final one = empty.toggled(uuid: 'a', baseRevision: 1);
    final none = one.toggled(uuid: 'a', baseRevision: 1);
    expect(empty.isEmpty, isTrue);
    expect(pairs(one), [('a', 1)]);
    expect(none.isEmpty, isTrue);
  });

  test('entries cannot be modified from outside', () {
    final s = const TrackSelection.empty().toggled(uuid: 'a', baseRevision: 1);
    expect(
      () => s.entries.add(const SelectedTrack(uuid: 'x', baseRevision: 1)),
      throwsUnsupportedError,
    );
    expect(s.count, 1);
  });

  test('SelectedTrack has value equality', () {
    // Not const: canonicalised const instances would compare identical.
    final uuid = 'a';
    expect(
      SelectedTrack(uuid: uuid, baseRevision: 1),
      SelectedTrack(uuid: uuid, baseRevision: 1),
    );
    expect(
      SelectedTrack(uuid: uuid, baseRevision: 1).hashCode,
      SelectedTrack(uuid: uuid, baseRevision: 1).hashCode,
    );
    expect(
      SelectedTrack(uuid: uuid, baseRevision: 1),
      isNot(SelectedTrack(uuid: uuid, baseRevision: null)),
    );
  });

  group('8B.1c: deselect and explicit refresh', () {
    TrackSelection abc() => const TrackSelection.empty()
        .toggled(uuid: 'a', baseRevision: 1)
        .toggled(uuid: 'b', baseRevision: null)
        .toggled(uuid: 'c', baseRevision: 3);

    test('without drops one uuid by id alone and keeps the order', () {
      expect(pairs(abc().without('b')), [('a', 1), ('c', 3)]);
    });

    test('without an unselected uuid changes nothing', () {
      expect(pairs(abc().without('zz')), [('a', 1), ('b', null), ('c', 3)]);
    });

    test('withRevision replaces one revision in place, keeping position', () {
      expect(pairs(abc().withRevision('b', 9)), [('a', 1), ('b', 9), ('c', 3)]);
      expect(pairs(abc().withRevision('a', 2)), [('a', 2), ('b', null), ('c', 3)]);
    });

    test('withRevision never selects an unselected uuid', () {
      expect(pairs(abc().withRevision('zz', 4)), [('a', 1), ('b', null), ('c', 3)]);
    });
  });
}
