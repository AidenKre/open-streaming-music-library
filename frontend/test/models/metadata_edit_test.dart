import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/metadata_edit.dart';

void main() {
  group('MetadataEdit', () {
    test('empty has no touched fields', () {
      const e = MetadataEdit.empty();
      expect(e.isEmpty, isTrue);
      expect(e.touched, isEmpty);
    });

    test('set marks a field touched and stores the value', () {
      final e = const MetadataEdit.empty().set('title', 'New');
      expect(e.isTouched('title'), isTrue);
      expect(e.effective('title', 'Old'), 'New');
      expect(e.isNotEmpty, isTrue);
    });

    test('untouched field falls back to the current value', () {
      const e = MetadataEdit.empty();
      expect(e.isTouched('artist'), isFalse);
      expect(e.effective('artist', 'Current'), 'Current');
    });

    test('explicit null is a clear — touched but null, distinct from untouched',
        () {
      final e = const MetadataEdit.empty().set('album', null);
      expect(e.isTouched('album'), isTrue);
      expect(e.effective('album', 'Old'), isNull);
      expect(e.toPayload(), {'album': null});
    });

    test('clearTouched reverts a field to untouched', () {
      final e = const MetadataEdit.empty().set('genre', 'Rock');
      final reverted = e.clearTouched('genre');
      expect(reverted.isTouched('genre'), isFalse);
      expect(reverted.effective('genre', 'Jazz'), 'Jazz');
    });

    test('toPayload contains only touched fields, including explicit clears', () {
      final e = const MetadataEdit.empty()
          .set('title', 'T')
          .set('artist', null);
      expect(e.toPayload(), {'title': 'T', 'artist': null});
    });

    test('value equality by touched set and values', () {
      final a = const MetadataEdit.empty().set('title', 'X');
      final b = const MetadataEdit.empty().set('title', 'X');
      final c = const MetadataEdit.empty().set('title', 'Y');
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });

    test('EditWriteMode wire values', () {
      expect(EditWriteMode.dbOnly.wire, 'db_only');
      expect(EditWriteMode.dbAndMaster.wire, 'db_and_master');
    });
  });
}
