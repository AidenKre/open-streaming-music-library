// Phase 8B.1b (for 8B.3): the Possible duplicates DTOs mirror the server as
// built by 8A.4 (backend/app/models/duplicates.py, its hand-over in
// phase-8/8A.4-progress.md). Unknown fields are tolerated; a required field
// missing or of the wrong type is a FormatException; a null track fact is
// unknown (never 0, never a difference); a float may arrive as a JSON
// integer. Summary counts: a count that is missing or not an int is
// unknown (null), never 0, so a header can never claim "No duplicates" from
// a count it did not receive.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';

const _a = '11111111-1111-4111-8111-111111111111';
const _b = '22222222-2222-4222-8222-222222222222';

Map<String, dynamic> _track(String uuid, {Map<String, Object?> over = const {}}) => {
  'uuid_id': uuid,
  'revision': 12,
  'title': 'Song',
  'artist': 'Artist',
  'album': null,
  'codec': 'flac',
  'bitrate_kbps': 912.5,
  'sample_rate_hz': 44100,
  'channels': 2,
  'duration_s': 201.25,
  'added_at': 1762800000,
  'master_present': true,
  ...over,
};

Map<String, dynamic> _pair({Map<String, Object?> over = const {}}) => {
  'uuid_a': _a,
  'uuid_b': _b,
  'kind': 'fingerprint',
  'band': 'strong',
  'score': 0.93,
  'status': 'open',
  'detected_at': 1762800100,
  'track_a': _track(_a),
  'track_b': _track(_b, over: {'codec': null, 'bitrate_kbps': 320}),
  ...over,
};

Map<String, dynamic> _summary() => {
  'bands': {
    'exact': {'open': 2, 'dismissed': 0},
    'strong': {'open': 1, 'dismissed': 3},
    'possible': {'open': 0, 'dismissed': 0},
  },
  'coverage': {
    'exact': {'pending': 0, 'current': 10, 'failed': 1, 'unsupported': 2},
    'fingerprint': {
      'pending': 4,
      'current': 5,
      'unavailable': 0,
      'too_short': 1,
      'low_information': 2,
      'failed': 0,
    },
    'match': {'pending': 3, 'current': 7},
  },
  'fingerprinter': 'fpcalc',
};

Object? _wire(Object? value) => jsonDecode(jsonEncode(value));

void main() {
  group('DuplicatePairPageDto', () {
    test('parses each pair and both track summaries', () {
      final page = DuplicatePairPageDto.fromJson(_wire({
        'pairs': [_pair()],
        'next_after': 'cursor-1',
      }));
      expect(page.nextAfter, 'cursor-1');
      final p = page.pairs.single;
      expect(p.uuidA, _a);
      expect(p.uuidB, _b);
      expect(p.kind, 'fingerprint');
      expect(p.band, 'strong');
      expect(p.score, 0.93);
      expect(p.status, 'open');
      expect(p.detectedAt, 1762800100);

      final a = p.trackA;
      expect(a.uuidId, _a);
      expect(a.revision, 12);
      expect(a.title, 'Song');
      expect(a.artist, 'Artist');
      expect(a.album, isNull);
      expect(a.codec, 'flac');
      expect(a.bitrateKbps, 912.5);
      expect(a.sampleRateHz, 44100);
      expect(a.channels, 2);
      expect(a.durationS, 201.25);
      expect(a.addedAt, 1762800000);
      expect(a.masterPresent, isTrue);

      final b = p.trackB;
      expect(b.uuidId, _b);
      expect(b.codec, isNull, reason: 'unknown stays unknown');
      expect(b.bitrateKbps, 320.0, reason: 'a whole float arrives as an int');
    });

    test('master_present: true, false, or null for a file the server '
        'could not check (sign-off OPEN-A-11)', () {
      final page = DuplicatePairPageDto.fromJson(_wire({
        'pairs': [
          _pair(over: {
            'track_a': _track(_a, over: {'master_present': null}),
            'track_b': _track(_b, over: {'master_present': false}),
          }),
        ],
        'next_after': null,
      }));
      expect(page.pairs.single.trackA.masterPresent, isNull,
          reason: 'unknown stays unknown, never "missing"');
      expect(page.pairs.single.trackB.masterPresent, isFalse);
    });

    test('an exact pair has a null score; a last page a null cursor', () {
      final page = DuplicatePairPageDto.fromJson(_wire({
        'pairs': [
          _pair(over: {'kind': 'exact', 'band': 'exact', 'score': null}),
        ],
        'next_after': null,
      }));
      expect(page.pairs.single.score, isNull);
      expect(page.pairs.single.band, 'exact');
      expect(page.nextAfter, isNull);
    });

    test('unknown fields are tolerated', () {
      final page = DuplicatePairPageDto.fromJson(_wire({
        'pairs': [
          _pair(over: {'future': 1, 'track_a': {..._track(_a), 'x': 2}}),
        ],
        'next_after': null,
        'future': true,
      }));
      expect(page.pairs.single.trackA.uuidId, _a);
    });

    test('a required field missing or of the wrong type is a FormatException',
        () {
      for (final bad in <Object?>[
        null,
        {'pairs': null, 'next_after': null},
        {'pairs': [], 'next_after': 1},
        {'pairs': [{..._pair()}..remove('uuid_a')], 'next_after': null},
        {'pairs': [_pair(over: {'score': '0.9'})], 'next_after': null},
        {'pairs': [_pair(over: {'detected_at': 1.5})], 'next_after': null},
        {'pairs': [_pair(over: {'track_b': null})], 'next_after': null},
        {
          'pairs': [_pair(over: {'track_a': {..._track(_a)}..remove('revision')})],
          'next_after': null,
        },
        {
          'pairs': [_pair(over: {'track_a': _track(_a, over: {'master_present': 'yes'})})],
          'next_after': null,
        },
        {
          'pairs': [_pair(over: {'track_a': _track(_a, over: {'channels': 2.0})})],
          'next_after': null,
        },
      ]) {
        expect(
          () => DuplicatePairPageDto.fromJson(_wire(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('DuplicateSummaryDto', () {
    test('parses band counts, every coverage layer and the fingerprinter', () {
      final s = DuplicateSummaryDto.fromJson(_wire(_summary()));
      expect(s.exact.open, 2);
      expect(s.exact.dismissed, 0);
      expect(s.strong.open, 1);
      expect(s.strong.dismissed, 3);
      expect(s.possible.open, 0);
      expect(s.possible.dismissed, 0);

      expect(s.exactCoverage.pending, 0);
      expect(s.exactCoverage.current, 10);
      expect(s.exactCoverage.failed, 1);
      expect(s.exactCoverage.unsupported, 2);

      expect(s.fingerprintCoverage.pending, 4);
      expect(s.fingerprintCoverage.current, 5);
      expect(s.fingerprintCoverage.unavailable, 0);
      expect(s.fingerprintCoverage.tooShort, 1);
      expect(s.fingerprintCoverage.lowInformation, 2);
      expect(s.fingerprintCoverage.failed, 0);

      expect(s.matchCoverage.pending, 3);
      expect(s.matchCoverage.current, 7);
      expect(s.fingerprinter, 'fpcalc');
    });

    test('no fingerprint tool is a null fingerprinter', () {
      final s = DuplicateSummaryDto.fromJson(
        _wire({..._summary(), 'fingerprinter': null}),
      );
      expect(s.fingerprinter, isNull);
    });

    test('a count missing or not an int is unknown (null), never 0', () {
      final json = _wire(_summary()) as Map<String, dynamic>;
      (json['bands'] as Map)['strong'] = {'open': '1'};
      (json['coverage'] as Map)['exact'] = {'pending': null, 'current': 2.0};
      (json['coverage'] as Map).remove('match');
      final s = DuplicateSummaryDto.fromJson(_wire(json));

      expect(s.strong.open, isNull);
      expect(s.strong.dismissed, isNull);
      expect(s.exactCoverage.pending, isNull);
      expect(s.exactCoverage.current, isNull);
      expect(s.exactCoverage.failed, isNull);
      expect(s.matchCoverage.pending, isNull);
      expect(s.matchCoverage.current, isNull);
      expect(s.exact.open, 2, reason: 'other counts are unaffected');
      expect(s.fingerprintCoverage.pending, 4);
    });

    test('a summary that is not an object, or a fingerprinter that is not a '
        'string, is a FormatException', () {
      for (final bad in <Object?>[
        null,
        [],
        {..._summary(), 'fingerprinter': 1},
      ]) {
        expect(
          () => DuplicateSummaryDto.fromJson(_wire(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('DuplicatePairStatusDto (dismiss / restore answer)', () {
    test('parses the canonical pair and its status', () {
      final s = DuplicatePairStatusDto.fromJson(
        _wire({'uuid_a': _a, 'uuid_b': _b, 'status': 'dismissed'}),
      );
      expect(s.uuidA, _a);
      expect(s.uuidB, _b);
      expect(s.status, 'dismissed');
    });

    test('a missing field is a FormatException', () {
      expect(
        () => DuplicatePairStatusDto.fromJson(_wire({'uuid_a': _a, 'uuid_b': _b})),
        throwsFormatException,
      );
    });
  });
}
