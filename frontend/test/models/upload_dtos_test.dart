// Phase 7B.1c: upload API DTOs mirror the server as built
// (backend/app/models/uploads.py: snake_case, unix-second times) and spec §4.
// Parsing tolerates unknown fields; a required field missing or of the wrong
// type is a FormatException; a nullable field keeps null as unknown, never 0.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';

const _sha = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

/// An item exactly as the server's `UploadItemOut` serializes it.
Map<String, dynamic> _itemJson() => {
  'item_uuid': '11111111-1111-4111-8111-111111111111',
  'batch_uuid': '22222222-2222-4222-8222-222222222222',
  'parent_item_uuid': null,
  'filename': 'Song.flac',
  'selection_index': 0,
  'member_order_key': '',
  'state': 'allocated',
  'expected_bytes': 3,
  'expected_sha256': _sha,
  'received_bytes': 0,
  'review_version': 0,
  'error': null,
  'created_at': 1762800000,
  'updated_at': 1762800001,
};

Map<String, dynamic> _batchJson() => {
  'batch_uuid': '22222222-2222-4222-8222-222222222222',
  'label': null,
  'created_at': 1762800000,
  'updated_at': 1762800001,
  'item_count': 2,
  'state_counts': {'allocated': 1, 'receiving': 1},
  'items_path': '/tracks/uploads/22222222-2222-4222-8222-222222222222/items',
};

/// A JSON round trip, as a value would come off the wire.
Object? _wire(Object? value) => jsonDecode(jsonEncode(value));

void main() {
  group('UploadItem', () {
    test('parses every field of the server item', () {
      final item = UploadItem.fromJson(_itemJson());

      expect(item.itemUuid, '11111111-1111-4111-8111-111111111111');
      expect(item.batchUuid, '22222222-2222-4222-8222-222222222222');
      expect(item.parentItemUuid, isNull);
      expect(item.filename, 'Song.flac');
      expect(item.selectionIndex, 0);
      expect(item.memberOrderKey, '');
      expect(item.state, UploadItemState.allocated);
      expect(item.rawState, 'allocated');
      expect(item.expectedBytes, 3);
      expect(item.expectedSha256, _sha);
      expect(item.receivedBytes, 0);
      expect(item.reviewVersion, 0);
      expect(item.error, isNull);
      expect(item.createdAt, 1762800000);
      expect(item.updatedAt, 1762800001);
      expect(item.duplicateCheck, isNull);
    });

    test('round-trips through toJson', () {
      final json = {
        ..._itemJson(),
        'state': 'failed',
        'parent_item_uuid': '33333333-3333-4333-8333-333333333333',
        'error': {
          'code': 'upload_digest_mismatch',
          'message': 'bytes differ',
          'retryable': false,
        },
      };

      final back = UploadItem.fromJson(_wire(UploadItem.fromJson(json).toJson()));

      expect(back.toJson(), UploadItem.fromJson(json).toJson());
      expect(back.parentItemUuid, '33333333-3333-4333-8333-333333333333');
      expect(back.error!.code, 'upload_digest_mismatch');
      expect(back.error!.message, 'bytes differ');
      expect(back.error!.retryable, isFalse);
    });

    test('unknown fields are ignored', () {
      final item = UploadItem.fromJson({
        ..._itemJson(),
        'detected_metadata': {'title': 'x'},
        'tag_write_supported': true,
        'something_new': [1, 2],
      });

      expect(item.filename, 'Song.flac');
      expect(item.toJson().containsKey('something_new'), isFalse);
    });

    test('every state of spec §3 parses; an unknown one is kept raw', () {
      const states = {
        'allocated': UploadItemState.allocated,
        'receiving': UploadItemState.receiving,
        'validating': UploadItemState.validating,
        'review_ready': UploadItemState.reviewReady,
        'committing': UploadItemState.committing,
        'imported': UploadItemState.imported,
        'duplicate': UploadItemState.duplicate,
        'expanded': UploadItemState.expanded,
        'failed': UploadItemState.failed,
        'duplicate_conflict': UploadItemState.duplicateConflict,
        'expired': UploadItemState.expired,
        'cancelled': UploadItemState.cancelled,
      };
      for (final MapEntry(:key, :value) in states.entries) {
        expect(UploadItem.fromJson({..._itemJson(), 'state': key}).state, value,
            reason: key);
      }

      final future = UploadItem.fromJson({..._itemJson(), 'state': 'paused'});
      expect(future.state, UploadItemState.unknown);
      expect(future.rawState, 'paused');
      expect(future.toJson()['state'], 'paused');
    });

    test('null expected bytes and digest stay null (unknown, never 0)', () {
      final item = UploadItem.fromJson({
        ..._itemJson(),
        'expected_bytes': null,
        'expected_sha256': null,
      });

      expect(item.expectedBytes, isNull);
      expect(item.expectedSha256, isNull);
      expect(item.toJson()['expected_bytes'], isNull);
    });

    test('an error with null message and retryable keeps both null', () {
      final item = UploadItem.fromJson({
        ..._itemJson(),
        'error': {'code': 'upload_interrupted', 'message': null, 'retryable': null},
      });

      expect(item.error!.code, 'upload_interrupted');
      expect(item.error!.message, isNull);
      expect(item.error!.retryable, isNull);
    });

    test('a required field missing is a FormatException', () {
      for (final key in [
        'item_uuid',
        'batch_uuid',
        'filename',
        'selection_index',
        'member_order_key',
        'state',
        'received_bytes',
        'review_version',
        'created_at',
        'updated_at',
      ]) {
        final json = _itemJson()..remove(key);
        expect(() => UploadItem.fromJson(json), throwsFormatException,
            reason: key);
      }
    });

    test('a required field null is a FormatException', () {
      for (final key in ['item_uuid', 'state', 'received_bytes', 'review_version']) {
        final json = {..._itemJson(), key: null};
        expect(() => UploadItem.fromJson(json), throwsFormatException,
            reason: key);
      }
    });

    test('a field of the wrong type is a FormatException', () {
      final cases = <String, Object?>{
        'item_uuid': 7,
        'filename': ['x'],
        'selection_index': '0',
        'received_bytes': 1.5,
        'review_version': true,
        'expected_bytes': '3',
        'expected_sha256': 3,
        'parent_item_uuid': 5,
        'created_at': '2026-11-11',
        'error': 'boom',
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        expect(() => UploadItem.fromJson({..._itemJson(), key: value}),
            throwsFormatException, reason: key);
      }
    });

    test('an error object without a string code is a FormatException', () {
      expect(
        () => UploadItem.fromJson({..._itemJson(), 'error': {'message': 'm'}}),
        throwsFormatException,
      );
      expect(
        () => UploadItem.fromJson({
          ..._itemJson(),
          'error': {'code': 'c', 'retryable': 'yes'},
        }),
        throwsFormatException,
      );
    });

    test('a non-object is a FormatException', () {
      expect(() => UploadItem.fromJson('item'), throwsFormatException);
      expect(() => UploadItem.fromJson(null), throwsFormatException);
    });
  });

  group('UploadBatch', () {
    test('parses and round-trips', () {
      final batch = UploadBatch.fromJson({..._batchJson(), 'label': 'Friday'});

      expect(batch.batchUuid, '22222222-2222-4222-8222-222222222222');
      expect(batch.label, 'Friday');
      expect(batch.itemCount, 2);
      expect(batch.stateCounts, {'allocated': 1, 'receiving': 1});
      expect(batch.itemsPath, endsWith('/items'));
      expect(UploadBatch.fromJson(_wire(batch.toJson())).toJson(), batch.toJson());
    });

    test('a state the client does not know is still counted', () {
      final batch = UploadBatch.fromJson({
        ..._batchJson(),
        'state_counts': {'allocated': 1, 'paused': 4},
      });

      expect(batch.stateCounts['paused'], 4);
    });

    test('a state count that is not an int is a FormatException', () {
      expect(
        () => UploadBatch.fromJson({
          ..._batchJson(),
          'state_counts': {'allocated': '1'},
        }),
        throwsFormatException,
      );
      expect(
        () => UploadBatch.fromJson({..._batchJson(), 'state_counts': [1]}),
        throwsFormatException,
      );
    });

    test('null label stays null; missing item_count is a FormatException', () {
      expect(UploadBatch.fromJson(_batchJson()).label, isNull);
      expect(
        () => UploadBatch.fromJson(_batchJson()..remove('item_count')),
        throwsFormatException,
      );
    });
  });

  group('pages and allocation', () {
    test('a batch page carries the opaque cursor; null on the last page', () {
      final page = UploadBatchPage.fromJson({
        'batches': [_batchJson()],
        'next_after': 'eyJrIjpbMV19',
      });
      expect(page.batches, hasLength(1));
      expect(page.nextAfter, 'eyJrIjpbMV19');

      final last = UploadBatchPage.fromJson({'batches': [], 'next_after': null});
      expect(last.batches, isEmpty);
      expect(last.nextAfter, isNull);
    });

    test('an item page parses each item; a bad list is a FormatException', () {
      final page = UploadItemPage.fromJson({
        'items': [_itemJson(), {..._itemJson(), 'selection_index': 1}],
        'next_after': null,
      });
      expect(page.items.map((i) => i.selectionIndex), [0, 1]);

      expect(() => UploadItemPage.fromJson({'items': 'x', 'next_after': null}),
          throwsFormatException);
      expect(() => UploadItemPage.fromJson({'next_after': null}),
          throwsFormatException);
      expect(
        () => UploadItemPage.fromJson({'items': [], 'next_after': 5}),
        throwsFormatException,
      );
    });

    test('the allocation answer carries batch, items and effective limits', () {
      final result = AllocationResult.fromJson({
        'batch': _batchJson(),
        'items': [_itemJson()],
        'limits': {'max_files_per_batch': 100, 'receives_per_user': 1},
      });

      expect(result.batch.itemCount, 2);
      expect(result.items.single.filename, 'Song.flac');
      expect(result.limits.maxFilesPerBatch, 100);
      expect(result.limits.receivesPerUser, 1);
      // A limit the server didn't send is unknown, not zero.
      expect(result.limits.maxFileBytes, isNull);
    });

    test('an allocation answer without limits is a FormatException', () {
      expect(
        () => AllocationResult.fromJson({
          'batch': _batchJson(),
          'items': [_itemJson()],
        }),
        throwsFormatException,
      );
    });
  });

  group('AllocationRequest', () {
    test('serializes snake_case; a null label is left out', () {
      final request = AllocationRequest(
        batchUuid: '22222222-2222-4222-8222-222222222222',
        items: const [
          AllocationItem(
            itemUuid: '11111111-1111-4111-8111-111111111111',
            filename: 'Song.flac',
            byteLength: 3,
            sha256: _sha,
          ),
        ],
      );

      expect(request.toJson(), {
        'batch_uuid': '22222222-2222-4222-8222-222222222222',
        'items': [
          {
            'item_uuid': '11111111-1111-4111-8111-111111111111',
            'filename': 'Song.flac',
            'byte_length': 3,
            'sha256': _sha,
          },
        ],
      });
    });

    test('a label is sent when present', () {
      final request = AllocationRequest(
        batchUuid: 'b',
        label: 'Friday',
        items: const [
          AllocationItem(itemUuid: 'i', filename: 'f', byteLength: 1, sha256: _sha),
        ],
      );

      expect(request.toJson()['label'], 'Friday');
    });

    test('the frozen body is stable: same request, same bytes', () {
      AllocationRequest make() => AllocationRequest(
        batchUuid: 'b',
        label: 'L',
        items: const [
          AllocationItem(itemUuid: 'i1', filename: 'a', byteLength: 1, sha256: _sha),
          AllocationItem(itemUuid: 'i2', filename: 'b', byteLength: 2, sha256: _sha),
        ],
      );

      expect(make().toFrozenJson(), make().toFrozenJson());
      expect(jsonDecode(make().toFrozenJson()), make().toJson());
    });

    test('the request never carries a local path', () {
      final request = AllocationRequest(
        batchUuid: 'b',
        items: const [
          AllocationItem(itemUuid: 'i', filename: 'Song.flac', byteLength: 1, sha256: _sha),
        ],
      );

      expect(request.toFrozenJson(), isNot(contains('/')));
    });
  });
}
