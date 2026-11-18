// Phase 7B.2c S1: the item fields the review flow reads (server as built:
// backend/app/models/uploads.py `UploadItemOut`; 7A.2c detected metadata v1,
// 7A.2d kind / skipped_members, 7A.3a tag_write_supported, 7A.3b result and
// conflict fields) and the request bodies of commit and resolve-duplicate
// (spec §4). Null means unknown, never false and never 0; an absent field
// (an older server) reads as null. The bodies are canonical JSON, so the same
// request always freezes to the same text (SC-14: a changed body under one
// operation id is a conflict).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';

Map<String, dynamic> _base() => {
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
  'created_at': 1762800000,
  'updated_at': 1762800001,
  'duplicate_check': null,
};

Map<String, dynamic> _detected() => {
  'v': 1,
  'container': 'flac',
  'codec': 'flac',
  'mime': 'audio/flac',
  'duration_s': 287.5,
  'bitrate_kbps': 920.0,
  'sample_rate_hz': 48000,
  'channels': 2,
  'has_album_art': true,
  'tags': {
    'title': 'Airbag',
    'artist': 'Radiohead',
    'album': 'OK Computer',
    'album_artist': null,
    'date': '1997-05-21',
    'year': 1997,
    'genre': null,
    'track_number': 1,
    'disc_number': null,
  },
};

Map<String, dynamic> _conflictMatch() => {
  'subject_kind': 'library_track',
  'track_uuid': '33333333-3333-4333-8333-333333333333',
  'item_uuid': null,
  'kind': 'exact',
  'band': 'exact',
  'score': null,
  'available': true,
  'track': {
    'title': 'Airbag',
    'artist': 'Radiohead',
    'album': 'OK Computer',
    'codec': 'flac',
    'bitrate_kbps': 920.0,
    'sample_rate_hz': 48000,
    'duration_s': 287.5,
  },
  'staged_item': null,
};

UploadItem _wire(Map<String, dynamic> json) =>
    UploadItem.fromJson(jsonDecode(jsonEncode(json)));

void main() {
  group('item fields of the review flow', () {
    test('an older server without the fields reads every one as unknown', () {
      final item = _wire(_base());
      expect(item.kind, isNull);
      expect(item.skippedMembers, isNull);
      expect(item.detectedMetadata, isNull);
      expect(item.tagWriteSupported, isNull);
      expect(item.resultTrackUuid, isNull);
      expect(item.resultRevision, isNull);
      expect(item.duplicateKind, isNull);
      expect(item.conflictMatches, isNull);
    });

    test('explicit nulls stay unknown: tag writing is neither supported nor '
        'unsupported, skipped is not 0', () {
      final item = _wire({
        ..._base(),
        'kind': null,
        'skipped_members': null,
        'detected_metadata': null,
        'tag_write_supported': null,
        'result_track_uuid': null,
        'result_revision': null,
        'duplicate_kind': null,
        'conflict_matches': null,
      });
      expect(item.tagWriteSupported, isNull);
      expect(item.skippedMembers, isNull);
      expect(item.conflictMatches, isNull);
    });

    test('a ZIP parent carries its kind and skipped count, including 0', () {
      final parent = _wire({
        ..._base(),
        'state': 'expanded',
        'kind': 'zip',
        'skipped_members': 0,
      });
      expect(parent.kind, 'zip');
      expect(parent.skippedMembers, 0);
    });

    test('tag_write_supported keeps false distinct from true', () {
      expect(_wire({..._base(), 'tag_write_supported': false})
          .tagWriteSupported, isFalse);
      expect(_wire({..._base(), 'tag_write_supported': true})
          .tagWriteSupported, isTrue);
    });

    test('detected metadata: the audio facts and each tag, unknown tags null',
        () {
      final m = _wire({..._base(), 'detected_metadata': _detected()})
          .detectedMetadata!;
      expect(m.codec, 'flac');
      expect(m.container, 'flac');
      expect(m.durationS, 287.5);
      expect(m.bitrateKbps, 920.0);
      expect(m.sampleRateHz, 48000);
      expect(m.channels, 2);
      expect(m.tags.title, 'Airbag');
      expect(m.tags.artist, 'Radiohead');
      expect(m.tags.album, 'OK Computer');
      expect(m.tags.albumArtist, isNull);
      expect(m.tags.date, '1997-05-21');
      expect(m.tags.year, 1997);
      expect(m.tags.genre, isNull);
      expect(m.tags.trackNumber, 1);
      expect(m.tags.discNumber, isNull);
    });

    test('a detected tag is read by its editable field key', () {
      final tags = _wire({..._base(), 'detected_metadata': _detected()})
          .detectedMetadata!
          .tags;
      expect(tags.valueOf('title'), 'Airbag');
      expect(tags.valueOf('year'), 1997);
      expect(tags.valueOf('track_number'), 1);
      expect(tags.valueOf('album_artist'), isNull);
      expect(tags.valueOf('not_a_field'), isNull);
    });

    test('detected metadata without audio facts keeps them unknown, never 0',
        () {
      final m = _wire({
        ..._base(),
        'detected_metadata': {
          'v': 1,
          'container': 'mp3',
          'codec': 'mp3',
          'mime': 'audio/mpeg',
          'duration_s': null,
          'bitrate_kbps': null,
          'sample_rate_hz': null,
          'channels': null,
          'has_album_art': false,
          'tags': {'title': null},
        },
      }).detectedMetadata!;
      expect(m.durationS, isNull);
      expect(m.bitrateKbps, isNull);
      expect(m.sampleRateHz, isNull);
      expect(m.channels, isNull);
      expect(m.tags.title, isNull);
      expect(m.tags.year, isNull);
    });

    test('a wrong type in a detected tag is a FormatException', () {
      final bad = _detected();
      (bad['tags'] as Map)['year'] = 'nineteen';
      expect(
        () => _wire({..._base(), 'detected_metadata': bad}),
        throwsFormatException,
      );
    });

    test('an imported item carries its result track and revision', () {
      final item = _wire({
        ..._base(),
        'state': 'imported',
        'result_track_uuid': '44444444-4444-4444-8444-444444444444',
        'result_revision': 7,
      });
      expect(item.resultTrackUuid, '44444444-4444-4444-8444-444444444444');
      expect(item.resultRevision, 7);
    });

    test('a duplicate item says which kind of match it was closed against',
        () {
      final item = _wire({
        ..._base(),
        'state': 'duplicate',
        'result_track_uuid': '33333333-3333-4333-8333-333333333333',
        'duplicate_kind': 'fingerprint',
      });
      expect(item.duplicateKind, 'fingerprint');
    });

    test('a duplicate_conflict item lists its conflicting library tracks', () {
      final item = _wire({
        ..._base(),
        'state': 'duplicate_conflict',
        'conflict_matches': [_conflictMatch()],
      });
      final match = item.conflictMatches!.single;
      expect(match.kind, 'exact');
      final subject = match.subject as LibraryTrackSubject;
      expect(subject.trackUuid, '33333333-3333-4333-8333-333333333333');
      expect(subject.title, 'Airbag');
    });

    test('the new fields survive a toJson round trip', () {
      final json = {
        ..._base(),
        'kind': 'audio',
        'skipped_members': null,
        'detected_metadata': _detected(),
        'tag_write_supported': false,
        'result_track_uuid': null,
        'result_revision': null,
        'duplicate_kind': null,
        'conflict_matches': [_conflictMatch()],
      };
      final again = _wire(_wire(json).toJson());
      expect(again.kind, 'audio');
      expect(again.tagWriteSupported, isFalse);
      expect(again.detectedMetadata!.tags.title, 'Airbag');
      expect(again.detectedMetadata!.tags.year, 1997);
      expect(again.detectedMetadata!.durationS, 287.5);
      expect(again.conflictMatches!.single.kind, 'exact');
    });
  });

  group('commit and resolve-duplicate bodies', () {
    test('a commit body has every field the server requires', () {
      final body = CommitBody(
        baseReviewVersion: 3,
        edits: const {'title': 'New', 'album': null},
        writeTags: true,
        acknowledged: AcknowledgedDuplicates.none,
      ).toJson();
      expect(body, {
        'base_review_version': 3,
        'edits': {'album': null, 'title': 'New'},
        'write_tags': true,
        'acknowledged_duplicates': {'library_tracks': [], 'staged_items': []},
      });
    });

    test('an explicit null in the edits is sent (it clears the field); an '
        'untouched field is absent', () {
      final edits = CommitBody(
        baseReviewVersion: 1,
        edits: const {'genre': null},
        writeTags: false,
        acknowledged: AcknowledgedDuplicates.none,
      ).toJson()['edits'] as Map;
      expect(edits.containsKey('genre'), isTrue);
      expect(edits['genre'], isNull);
      expect(edits.containsKey('title'), isFalse);
    });

    test('the same request freezes to the same text whatever the order of '
        'edits and acknowledgements', () {
      String frozen(Map<String, Object?> edits, AcknowledgedDuplicates acks) =>
          jsonEncode(CommitBody(
            baseReviewVersion: 2,
            edits: edits,
            writeTags: false,
            acknowledged: acks,
          ).toJson());
      expect(
        frozen(
          {'title': 'A', 'album': 'B', 'year': 2001},
          AcknowledgedDuplicates(
            libraryTracks: {'t-2', 't-1'},
            stagedItems: {'s-9', 's-3'},
          ),
        ),
        frozen(
          {'year': 2001, 'album': 'B', 'title': 'A'},
          AcknowledgedDuplicates(
            libraryTracks: {'t-1', 't-2'},
            stagedItems: {'s-3', 's-9'},
          ),
        ),
      );
    });

    test('acknowledgements are sent as sorted lists, every one of them', () {
      final acks = AcknowledgedDuplicates(
        libraryTracks: {for (var i = 7; i >= 1; i--) 't-$i'},
        stagedItems: {'s-2', 's-1'},
      ).toJson();
      expect(acks['library_tracks'], [for (var i = 1; i <= 7; i++) 't-$i']);
      expect(acks['staged_items'], ['s-1', 's-2']);
    });

    test('no acknowledgement is empty, and says so', () {
      expect(AcknowledgedDuplicates.none.isEmpty, isTrue);
      expect(
        AcknowledgedDuplicates(libraryTracks: {'t-1'}).isEmpty,
        isFalse,
      );
    });

    test('a resolve-duplicate body names the version and the existing track',
        () {
      expect(
        const ResolveDuplicateBody(
          expectedReviewVersion: 4,
          existingTrackUuid: '33333333-3333-4333-8333-333333333333',
        ).toJson(),
        {
          'expected_review_version': 4,
          'existing_track_uuid': '33333333-3333-4333-8333-333333333333',
        },
      );
    });
  });
}
