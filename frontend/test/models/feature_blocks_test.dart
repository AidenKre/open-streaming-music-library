// Phase 7B.1a (D23, SC-03): the typed feature-block parser.
//  * one optional block per feature with an integer `version`; an absent
//    block means unsupported; `history` moves onto it (same rule as before:
//    an int version >= 1);
//  * `uploads: {version: 1, limits: {...}}` with the effective limits the
//    server advertises (names mirror backend `UploadLimitsInfo`);
//  * unknown blocks and unknown fields are tolerated;
//  * a block that is malformed where the client needs it (version missing,
//    not an int, < 1; uploads without a `limits` object) makes THAT feature
//    unavailable, never a crash, never another feature;
//  * a limit that is missing or not a non-negative int is unknown (null):
//    never 0, never unlimited; 0 itself is a known value.
//  * `auth` and `server` stay out of the parser (DEV-M-03).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/feature_blocks.dart';

/// The block as the 7A.1d backend sends it (`app/main.py` get_app_info,
/// `UploadLimitsInfo`), with independent sample values.
Map<String, Object?> _uploads({Object? version = 1, Object? limits}) => {
  'version': version,
  'limits': limits ??
      {
        'max_files_per_batch': 100,
        'max_file_bytes': 262144000,
        'max_batch_bytes': 2147483648,
        'max_expanded_bytes_per_batch': 2147483648,
        'max_expanded_member_bytes': 262144000,
        'max_audio_items_per_batch': 1000,
        'max_archive_members': 1000,
        'max_compression_ratio': 100,
        'receives': 2,
        'staged_quota_bytes': 10737418240,
        'receives_per_user': 1,
        'user_staged_quota_bytes': 5368709120,
      },
};

void main() {
  group('history block', () {
    test('version 1 is the history feature', () {
      final f = FeatureBlocks.fromJson({'history': {'version': 1}});
      expect(f.history, isNotNull);
      expect(f.history!.version, 1);
    });

    test('absent, malformed or below 1 is unsupported', () {
      for (final json in <Map<String, Object?>>[
        {},
        {'history': null},
        {'history': true},
        {'history': 1},
        {'history': {}},
        {'history': {'version': '1'}},
        {'history': {'version': 1.0}},
        {'history': {'version': 0}},
        {'history': {'version': -1}},
      ]) {
        expect(FeatureBlocks.fromJson(json).history, isNull, reason: '$json');
      }
    });

    test('unknown fields in the block are tolerated', () {
      final f = FeatureBlocks.fromJson({
        'history': {'version': 2, 'future_field': {'x': 1}},
      });
      expect(f.history!.version, 2);
    });
  });

  group('uploads block', () {
    test('parses version and every advertised limit', () {
      final f = FeatureBlocks.fromJson({'uploads': _uploads()});
      final u = f.uploads!;
      expect(u.version, 1);
      final l = u.limits;
      expect(l.maxFilesPerBatch, 100);
      expect(l.maxFileBytes, 262144000);
      expect(l.maxBatchBytes, 2147483648);
      expect(l.maxExpandedBytesPerBatch, 2147483648);
      expect(l.maxExpandedMemberBytes, 262144000);
      expect(l.maxAudioItemsPerBatch, 1000);
      expect(l.maxArchiveMembers, 1000);
      expect(l.maxCompressionRatio, 100);
      expect(l.receives, 2);
      expect(l.stagedQuotaBytes, 10737418240);
      expect(l.receivesPerUser, 1);
      expect(l.userStagedQuotaBytes, 5368709120);
    });

    test('a missing limit is unknown (null), not 0 and not unlimited', () {
      final f = FeatureBlocks.fromJson({
        'uploads': _uploads(limits: {'max_files_per_batch': 100}),
      });
      final l = f.uploads!.limits;
      expect(l.maxFilesPerBatch, 100);
      expect(l.maxFileBytes, isNull);
      expect(l.receivesPerUser, isNull);
      expect(l.userStagedQuotaBytes, isNull);
    });

    test('a limit of the wrong type or negative is unknown; 0 is known', () {
      final f = FeatureBlocks.fromJson({
        'uploads': _uploads(limits: {
          'max_files_per_batch': '100',
          'max_file_bytes': 1.5,
          'max_batch_bytes': -1,
          'receives': null,
          'receives_per_user': 0,
          'max_archive_members': true,
        }),
      });
      final l = f.uploads!.limits;
      expect(l.maxFilesPerBatch, isNull);
      expect(l.maxFileBytes, isNull);
      expect(l.maxBatchBytes, isNull);
      expect(l.receives, isNull);
      expect(l.receivesPerUser, 0);
      expect(l.maxArchiveMembers, isNull);
    });

    test('unknown limits and fields are tolerated', () {
      final f = FeatureBlocks.fromJson({
        'uploads': {
          'version': 1,
          'something_new': [1, 2],
          'limits': {'max_files_per_batch': 7, 'future_limit': 3},
        },
      });
      expect(f.uploads!.limits.maxFilesPerBatch, 7);
    });

    test('malformed where the client needs it: that feature is unavailable',
        () {
      for (final json in <Map<String, Object?>>[
        {},
        {'uploads': true},
        {'uploads': null},
        {'uploads': {'limits': _uploads()['limits']}}, // no version
        {'uploads': _uploads(version: '1')},
        {'uploads': _uploads(version: 0)},
        {'uploads': {'version': 1}}, // no limits object
        {'uploads': {'version': 1, 'limits': []}},
        {'uploads': {'version': 1, 'limits': 5}},
      ]) {
        expect(FeatureBlocks.fromJson(json).uploads, isNull, reason: '$json');
      }
    });

    test('a broken uploads block does not take history with it', () {
      final f = FeatureBlocks.fromJson({
        'history': {'version': 1},
        'uploads': {'version': 'x'},
      });
      expect(f.uploads, isNull);
      expect(f.history, isNotNull);
    });
  });

  // Phase 8B.1b (SC-03, D32, O6): `library_tools: {version, server_delete,
  // duplicate_review}`, always sent by an 8A.1 server. A flag that is
  // missing or not a bool is unknown: the block is malformed and only this
  // feature is unavailable (unknown is never read as false).
  group('library_tools block', () {
    test('the 8A.1 block parses with both flags', () {
      final f = FeatureBlocks.fromJson({
        'library_tools': {
          'version': 1,
          'server_delete': true,
          'duplicate_review': false,
        },
      });
      final t = f.libraryTools!;
      expect(t.version, 1);
      expect(t.serverDelete, isTrue);
      expect(t.duplicateReview, isFalse);
    });

    test('the switch turned off is a present block with serverDelete false',
        () {
      final t = FeatureBlocks.fromJson({
        'library_tools': {
          'version': 1,
          'server_delete': false,
          'duplicate_review': true,
        },
      }).libraryTools!;
      expect(t.serverDelete, isFalse);
      expect(t.duplicateReview, isTrue);
    });

    test('unknown fields are tolerated; a later version is kept', () {
      final t = FeatureBlocks.fromJson({
        'library_tools': {
          'version': 3,
          'server_delete': true,
          'duplicate_review': true,
          'bulk_edit': {'x': 1},
        },
      }).libraryTools!;
      expect(t.version, 3);
    });

    test('absent or malformed: only library tools is unavailable', () {
      for (final block in <Object?>[
        null,
        true,
        1,
        <String, Object?>{},
        {'server_delete': true, 'duplicate_review': true}, // no version
        {'version': '1', 'server_delete': true, 'duplicate_review': true},
        {'version': 0, 'server_delete': true, 'duplicate_review': true},
        {'version': 1, 'duplicate_review': true}, // flag missing
        {'version': 1, 'server_delete': true}, // flag missing
        {'version': 1, 'server_delete': 'true', 'duplicate_review': false},
        {'version': 1, 'server_delete': 1, 'duplicate_review': false},
        {'version': 1, 'server_delete': false, 'duplicate_review': null},
      ]) {
        final f = FeatureBlocks.fromJson({
          'history': {'version': 1},
          'library_tools': block,
        });
        expect(f.libraryTools, isNull, reason: '$block');
        expect(f.history, isNotNull, reason: 'history survives $block');
      }
    });

    test('toJson round-trips through the cache', () {
      final info = AppInfo.fromJson({
        'library_tools': {
          'version': 1,
          'server_delete': true,
          'duplicate_review': false,
        },
      });
      final back = AppInfo.fromJson(info.toJson()).features.libraryTools!;
      expect(back.version, 1);
      expect(back.serverDelete, isTrue);
      expect(back.duplicateReview, isFalse);
    });
  });

  group('AppInfo', () {
    test('carries the parsed blocks; unknown blocks are ignored', () {
      final info = AppInfo.fromJson({
        'entities': {},
        'history': {'version': 1},
        'uploads': _uploads(),
        'library_tools': {'version': 1, 'server_delete': true},
        'auth': {'version': 1, 'signup_enabled': false},
        'server': {'instance_id': 'x'},
      });
      expect(info.features.history!.version, 1);
      expect(info.features.uploads!.limits.receivesPerUser, 1);
      expect(info.supportsHistory, isTrue);
    });

    test('an old server without the blocks has no features', () {
      final info = AppInfo.fromJson({'entities': {}});
      expect(info.features.history, isNull);
      expect(info.features.uploads, isNull);
      expect(info.supportsHistory, isFalse);
    });

    test('toJson round-trips the blocks', () {
      final info = AppInfo.fromJson({
        'history': {'version': 1},
        'uploads': _uploads(limits: {'receives_per_user': 1}),
      });
      final back = AppInfo.fromJson(info.toJson());
      expect(back.features.history!.version, 1);
      expect(back.features.uploads!.version, 1);
      expect(back.features.uploads!.limits.receivesPerUser, 1);
      expect(back.features.uploads!.limits.maxFileBytes, isNull,
          reason: 'an unknown limit stays unknown through the cache');
    });
  });
}
