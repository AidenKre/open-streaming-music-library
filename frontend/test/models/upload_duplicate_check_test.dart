// Phase 7B.1c: an item's `duplicate_check` (spec §4 GET item; SC-25
// DuplicateReport), in the wire shape 7A.2c builds at read time
// (phase-7a2c `backend/app/models/uploads.py` DuplicateCheckOut, commit
// 6bfeb1f; review r1 #1 realigned the client to it):
//   {version, status: complete|failed, no_duplicates_found,
//    exact|fingerprint: {subject_state, library_pending, library_failed,
//                        library_not_comparable} | null,
//    matches: [{subject_kind, track_uuid?, item_uuid?, kind, band, score?,
//               available, track: {...}?, staged_item: {...}?}]}
// Null means "not checked yet"; "none found" may be said only for a
// complete check with no matches and full coverage on the asked layers;
// anything else (pending/failed counts, unknown counts, a non-current
// subject, a failed or unreadable check) is partial. A malformed
// duplicate_check never makes the item itself unreadable.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';

Map<String, dynamic> _layer({
  String state = 'current',
  Object? pending = 0,
  Object? failed = 0,
  Object? notComparable = 0,
}) => {
  'subject_state': state,
  'library_pending': pending,
  'library_failed': failed,
  'library_not_comparable': notComparable,
};

Map<String, dynamic> _report({
  Object? exact = const {},
  Object? fingerprint = const {},
  List<Object?> matches = const [],
  String status = 'complete',
  bool? serverSays,
}) => {
  'version': 1,
  'status': status,
  'no_duplicates_found': serverSays ?? matches.isEmpty,
  'exact': exact is Map && exact.isEmpty ? _layer() : exact,
  'fingerprint':
      fingerprint is Map && fingerprint.isEmpty ? _layer() : fingerprint,
  'matches': matches,
};

Map<String, dynamic> _libraryMatch({
  bool available = true,
  Map<String, dynamic>? track,
}) => {
  'subject_kind': 'library_track',
  'track_uuid': '44444444-4444-4444-8444-444444444444',
  'item_uuid': null,
  'kind': 'exact',
  'band': 'exact',
  'score': null,
  'available': available,
  'track': available
      ? (track ??
          {
            'title': 'Song',
            'artist': 'Band',
            'album': 'Record',
            'codec': 'mp3',
            'bitrate_kbps': 320.0,
            'sample_rate_hz': 44100,
            'duration_s': 201.5,
          })
      : null,
  'staged_item': null,
};

Map<String, dynamic> _stagedMatch() => {
  'subject_kind': 'staged_item',
  'track_uuid': null,
  'item_uuid': '55555555-5555-4555-8555-555555555555',
  'kind': 'fingerprint',
  'band': 'strong',
  'score': 0.93,
  'available': true,
  'track': null,
  'staged_item': {
    'filename': 'other.flac',
    'batch_uuid': '22222222-2222-4222-8222-222222222222',
    'batch_created_at': 1762800000,
  },
};

const _both = {DuplicateLayer.exact, DuplicateLayer.fingerprint};

DuplicateCheck _parse(Object? json) => DuplicateCheck.fromJson(json);

Map<String, dynamic> _item(Object? check, {bool present = true}) => {
  'item_uuid': '11111111-1111-4111-8111-111111111111',
  'batch_uuid': '22222222-2222-4222-8222-222222222222',
  'parent_item_uuid': null,
  'filename': 'Song.flac',
  'selection_index': 0,
  'member_order_key': '',
  'state': 'review_ready',
  'expected_bytes': 3,
  'expected_sha256': null,
  'received_bytes': 3,
  'review_version': 1,
  'error': null,
  'created_at': 1,
  'updated_at': 2,
  'detected_metadata': {'title': 'x'},
  if (present) 'duplicate_check': check,
};

void main() {
  group('on the item', () {
    test('null means not checked yet', () {
      expect(UploadItem.fromJson(_item(null)).duplicateCheck, isNull);
    });

    test('absent (a server without the field) also means not checked', () {
      expect(UploadItem.fromJson(_item(null, present: false)).duplicateCheck,
          isNull);
    });

    test('an empty complete report is a report, not null', () {
      final check = UploadItem.fromJson(_item(_report())).duplicateCheck;

      expect(check, isNotNull);
      expect(check!.isReadable, isTrue);
      expect(check.matches, isEmpty);
      expect(check.noDuplicatesFound(layers: _both), isTrue);
    });

    test('a malformed report does not make the item unreadable', () {
      for (final bad in <Object?>[
        'none',
        <Object?>[],
        {'version': 1, 'status': 'complete', 'matches': 'x'},
        _report(matches: [
          {'subject_kind': 'library_track', 'kind': 'exact'},
        ]),
      ]) {
        final item = UploadItem.fromJson(_item(bad));
        final check = item.duplicateCheck;
        expect(check, isNotNull, reason: '$bad');
        expect(check!.isReadable, isFalse, reason: '$bad');
        expect(check.noDuplicatesFound(layers: _both), isFalse,
            reason: '$bad');
        expect(item.filename, 'Song.flac');
      }
    });

    test('the report round-trips with the item', () {
      final json = _item(_report(matches: [_libraryMatch(), _stagedMatch()]));
      final first = UploadItem.fromJson(json);
      final back = UploadItem.fromJson(jsonDecode(jsonEncode(first.toJson())));

      expect(back.duplicateCheck!.matches, hasLength(2));
      expect(back.toJson(), first.toJson());
    });
  });

  group('coverage: empty vs partial', () {
    test('full coverage and no matches: none found', () {
      final check = _parse(_report());

      expect(check.status, 'complete');
      expect(check.version, 1);
      expect(check.noDuplicatesFound(layers: _both), isTrue);
    });

    test('not-comparable library tracks are disclosed but do not block', () {
      final check = _parse(_report(exact: _layer(notComparable: 3)));

      expect(check.exact.libraryNotComparable, 3);
      expect(check.noDuplicatesFound(layers: _both), isTrue);
    });

    test('pending library tracks make it partial', () {
      final check = _parse(_report(fingerprint: _layer(pending: 2)));

      expect(check.matches, isEmpty);
      expect(check.noDuplicatesFound(layers: _both), isFalse);
      expect(check.noDuplicatesFound(layers: {DuplicateLayer.exact}), isTrue);
      expect(check.fingerprint.isComplete, isFalse);
    });

    test('failed library tracks make it partial', () {
      final check = _parse(_report(exact: _layer(failed: 1)));

      expect(check.noDuplicatesFound(layers: {DuplicateLayer.exact}), isFalse);
    });

    test('a subject that is not current on a layer makes it partial', () {
      final check = _parse(_report(fingerprint: _layer(state: 'unavailable')));

      expect(check.fingerprint.subjectState, 'unavailable');
      expect(check.noDuplicatesFound(layers: _both), isFalse);
      expect(check.noDuplicatesFound(layers: {DuplicateLayer.exact}), isTrue);
    });

    test('a missing or wrong-typed count is unknown (null), never zero', () {
      final layer = _layer()
        ..remove('library_pending')
        ..['library_failed'] = '0';
      final check = _parse(_report(exact: layer));

      expect(check.exact.libraryPending, isNull);
      expect(check.exact.libraryFailed, isNull);
      expect(check.noDuplicatesFound(layers: {DuplicateLayer.exact}), isFalse);
    });

    test('a null layer (failed check) is unknown: never "none found"', () {
      final check = _parse(_report(fingerprint: null));

      expect(check.fingerprint.subjectState, isNull);
      expect(check.noDuplicatesFound(layers: _both), isFalse);
      expect(check.noDuplicatesFound(layers: {DuplicateLayer.exact}), isTrue);
    });

    test('a failed check is never "none found", whatever else it says', () {
      final check = _parse(
        _report(status: 'failed', exact: null, fingerprint: null),
      );

      expect(check.status, 'failed');
      expect(check.isReadable, isTrue);
      expect(check.noDuplicatesFound(layers: {DuplicateLayer.exact}), isFalse);
    });

    test('a status the client does not know is not "none found"', () {
      final check = _parse(_report(status: 'partial'));

      expect(check.noDuplicatesFound(layers: _both), isFalse);
    });

    test('the server flag cannot make a partial check "none found"', () {
      final check = _parse(
        _report(fingerprint: _layer(pending: 1), serverSays: true),
      );

      expect(check.noDuplicatesFound(layers: _both), isFalse);
    });

    test('any match means not "none found"', () {
      final check = _parse(_report(matches: [_stagedMatch()]));

      expect(check.noDuplicatesFound(layers: {DuplicateLayer.exact}), isFalse);
    });

    test('asking about no layer is a usage error', () {
      expect(() => _parse(_report()).noDuplicatesFound(layers: {}),
          throwsArgumentError);
    });
  });

  group('matches', () {
    test('a library match carries the track summary', () {
      final match = _parse(_report(matches: [_libraryMatch()])).matches.single;

      expect(match.kind, 'exact');
      expect(match.isExact, isTrue);
      expect(match.band, 'exact');
      expect(match.score, isNull);
      final subject = match.subject as LibraryTrackSubject;
      expect(subject.trackUuid, '44444444-4444-4444-8444-444444444444');
      expect(subject.available, isTrue);
      expect(subject.title, 'Song');
      expect(subject.artist, 'Band');
      expect(subject.album, 'Record');
      expect(subject.codec, 'mp3');
      expect(subject.bitrateKbps, 320.0);
      expect(subject.sampleRateHz, 44100);
      expect(subject.durationS, 201.5);
    });

    test('a staged match names the other item and its batch', () {
      final match = _parse(_report(matches: [_stagedMatch()])).matches.single;

      expect(match.isExact, isFalse);
      expect(match.score, closeTo(0.93, 1e-9));
      final subject = match.subject as StagedItemSubject;
      expect(subject.itemUuid, '55555555-5555-4555-8555-555555555555');
      expect(subject.available, isTrue);
      expect(subject.filename, 'other.flac');
      expect(subject.batchUuid, '22222222-2222-4222-8222-222222222222');
      expect(subject.batchCreatedAt, 1762800000);
    });

    test('a gone track reads as unavailable with no summary', () {
      final match =
          _parse(_report(matches: [_libraryMatch(available: false)]))
              .matches
              .single;

      final subject = match.subject as LibraryTrackSubject;
      expect(subject.available, isFalse);
      expect(subject.title, isNull);
      expect(subject.durationS, isNull);
    });

    test('integer numbers are accepted where the server sends floats', () {
      final json = _libraryMatch(track: {
        'title': null,
        'artist': null,
        'album': null,
        'codec': null,
        'bitrate_kbps': 320,
        'sample_rate_hz': null,
        'duration_s': 200,
      })..['score'] = 1;
      final match = _parse(_report(matches: [json])).matches.single;

      expect(match.score, 1.0);
      final subject = match.subject as LibraryTrackSubject;
      expect(subject.bitrateKbps, 320.0);
      expect(subject.durationS, 200.0);
      expect(subject.sampleRateHz, isNull);
    });

    test('a subject kind the client does not know is kept, not dropped', () {
      final check = _parse(_report(matches: [
        {
          'subject_kind': 'remote_track',
          'kind': 'exact',
          'band': 'exact',
          'score': null,
          'available': true,
        },
      ]));

      expect(check.matches, hasLength(1));
      expect(check.matches.single.subject, isA<UnknownDuplicateSubject>());
      expect(
        (check.matches.single.subject as UnknownDuplicateSubject).kind,
        'remote_track',
      );
      expect(check.noDuplicatesFound(layers: _both), isFalse);
    });

    test('matches are complete: more than five are all kept', () {
      final check = _parse(_report(matches: [
        for (var i = 0; i < 12; i++) _stagedMatch(),
      ]));

      expect(check.matches, hasLength(12));
    });

    test('malformed matches make the whole check unreadable', () {
      for (final bad in <Object?>[
        'x',
        {..._stagedMatch()}..remove('subject_kind'),
        {..._stagedMatch()}..remove('kind'),
        {..._stagedMatch(), 'score': 'high'},
        {..._libraryMatch(), 'track_uuid': null},
        {..._stagedMatch(), 'item_uuid': null},
        {..._libraryMatch(), 'track': 'summary'},
      ]) {
        final check = _parse(_report(matches: [bad]));
        expect(check.isReadable, isFalse, reason: '$bad');
        expect(check.noDuplicatesFound(layers: _both), isFalse,
            reason: '$bad');
      }
      expect(_parse({..._report(), 'matches': 'none'}).isReadable, isFalse);
      expect(_parse(_report()..remove('matches')).isReadable, isFalse);
      expect(_parse('report').isReadable, isFalse);
    });

    test('unknown fields in the report and its parts are ignored', () {
      final match = _libraryMatch()..['explain'] = {'x': 1};
      final check = _parse({
        ..._report(matches: [match]),
        'checked_at': 123,
      });

      expect(check.isReadable, isTrue);
      expect(check.matches, hasLength(1));
    });
  });
}
