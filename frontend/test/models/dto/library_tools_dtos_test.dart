// Phase 8B.1b: the deletion DTOs mirror the server as built (8A.2b,
// backend/app/models/deletions.py; snake_case, unix-second times) and spec
// §4. Parsing tolerates unknown fields; a required field missing or of the
// wrong type is a FormatException; a nullable field keeps null as unknown
// (never 0, never false); status and code strings are kept as sent (the
// model maps them; a value this client doesn't know is never coerced).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';

const _a = '11111111-1111-4111-8111-111111111111';
const _b = '22222222-2222-4222-8222-222222222222';
const _op = '33333333-3333-4333-8333-333333333333';

/// A preview target exactly as `DeletionPreviewTarget` serializes it.
Map<String, dynamic> _previewTarget({
  String uuid = _a,
  int baseRevision = 7,
  Object? revision = 7,
  Object? title = 'Song',
  Object? masterExists = true,
  Object? masterSize = 1234,
  bool unknown = false,
  bool alreadyDeleted = false,
  bool missingMaster = false,
  bool conflict = false,
  bool busy = false,
}) => {
  'uuid_id': uuid,
  'base_revision': baseRevision,
  'revision': revision,
  'title': title,
  'artist': 'Artist',
  'album': null,
  'master_exists': masterExists,
  'master_size': masterSize,
  'unknown': unknown,
  'already_deleted': alreadyDeleted,
  'missing_master': missingMaster,
  'conflict': conflict,
  'busy': busy,
};

Map<String, dynamic> _item({
  String uuid = _a,
  String status = 'pending',
  Object? error,
  Object? tombstoneRevision,
  List<Object?> details = const [],
}) => {
  'uuid_id': uuid,
  'base_revision': 7,
  'status': status,
  'error': error,
  'tombstone_revision': tombstoneRevision,
  'details': details,
};

Map<String, dynamic> _job({
  String status = 'pending',
  List<Map<String, dynamic>>? items,
}) => {
  'operation_uuid': _op,
  'created_at': 1762800000,
  'status': status,
  'item_count': (items ?? [_item()]).length,
  'items': items ?? [_item()],
};

Object? _wire(Object? value) => jsonDecode(jsonEncode(value));

void main() {
  group('the frozen job body', () {
    test('is the exact server request, targets in confirmation order', () {
      final body = DeletionJobRequestDto(
        operationUuid: _op,
        targets: const [
          DeletionTargetDto(uuidId: _b, baseRevision: 12),
          DeletionTargetDto(uuidId: _a, baseRevision: 0),
        ],
        confirmedCount: 2,
      );

      expect(
        body.toFrozenJson(),
        '{"operation_uuid":"$_op",'
        '"targets":[{"uuid_id":"$_b","base_revision":12},'
        '{"uuid_id":"$_a","base_revision":0}],'
        '"confirmed_count":2}',
      );
    });

    test('is stable: the same request freezes to the same text', () {
      DeletionJobRequestDto build() => DeletionJobRequestDto(
        operationUuid: _op,
        targets: const [DeletionTargetDto(uuidId: _a, baseRevision: 3)],
        confirmedCount: 1,
      );
      expect(build().toFrozenJson(), build().toFrozenJson());
    });

    test('the preview request carries only the targets', () {
      expect(
        _wire(const DeletionPreviewRequestDto(
          targets: [DeletionTargetDto(uuidId: _a, baseRevision: 5)],
        ).toJson()),
        {
          'targets': [
            {'uuid_id': _a, 'base_revision': 5},
          ],
        },
      );
    });
  });

  group('DeletionPreviewDto', () {
    test('parses every field of each target, in the order sent', () {
      final p = DeletionPreviewDto.fromJson(_wire({
        'targets': [
          _previewTarget(),
          _previewTarget(
            uuid: _b,
            revision: 9,
            conflict: true,
            busy: true,
            missingMaster: true,
            masterExists: false,
            masterSize: null,
          ),
        ],
      }));

      expect(p.targets, hasLength(2));
      final t = p.targets.first;
      expect(t.uuidId, _a);
      expect(t.baseRevision, 7);
      expect(t.revision, 7);
      expect(t.title, 'Song');
      expect(t.artist, 'Artist');
      expect(t.album, isNull);
      expect(t.masterExists, isTrue);
      expect(t.masterSize, 1234);
      expect(t.unknown, isFalse);
      expect(t.alreadyDeleted, isFalse);
      expect(t.missingMaster, isFalse);
      expect(t.conflict, isFalse);
      expect(t.busy, isFalse);

      final u = p.targets.last;
      expect(u.uuidId, _b);
      expect(u.revision, 9);
      expect(u.conflict, isTrue);
      expect(u.busy, isTrue);
      expect(u.missingMaster, isTrue);
      expect(u.masterExists, isFalse);
      expect(u.masterSize, isNull);
    });

    test('an unknown track keeps its identity and facts unknown (null)', () {
      final t = DeletionPreviewDto.fromJson(_wire({
        'targets': [
          _previewTarget(
            revision: null,
            title: null,
            masterExists: null,
            masterSize: null,
            unknown: true,
          ),
        ],
      })).targets.single;
      expect(t.unknown, isTrue);
      expect(t.revision, isNull);
      expect(t.title, isNull);
      expect(t.masterExists, isNull);
      expect(t.masterSize, isNull);
    });

    test('unknown fields are tolerated', () {
      final t = DeletionPreviewDto.fromJson(_wire({
        'targets': [
          {..._previewTarget(), 'future': 1},
        ],
        'future': true,
      })).targets.single;
      expect(t.uuidId, _a);
    });

    test('a required field missing or of the wrong type is a FormatException',
        () {
      for (final bad in <Object?>[
        null,
        [],
        {'targets': 1},
        {'targets': [1]},
        {'targets': [{..._previewTarget()}..remove('uuid_id')]},
        {'targets': [{..._previewTarget()}..remove('conflict')]},
        {'targets': [{..._previewTarget(), 'busy': 'no'}]},
        {'targets': [{..._previewTarget(), 'base_revision': '7'}]},
        {'targets': [{..._previewTarget(), 'revision': 7.5}]},
        {'targets': [{..._previewTarget(), 'master_exists': 1}]},
        {'targets': [{..._previewTarget(), 'title': 3}]},
      ]) {
        expect(
          () => DeletionPreviewDto.fromJson(_wire(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });

  group('DeletionJobDto', () {
    test('parses the job and each item in order', () {
      final job = DeletionJobDto.fromJson(_wire(_job(
        status: 'partial',
        items: [
          _item(
            status: 'deleted',
            tombstoneRevision: 41,
            details: ['master_missing', 'storage_cleanup_pending'],
          ),
          _item(uuid: _b, status: 'failed', error: 'path_rejected'),
        ],
      )));

      expect(job.operationUuid, _op);
      expect(job.createdAt, 1762800000);
      expect(job.status, 'partial');
      expect(job.itemCount, 2);
      expect(job.items.map((i) => i.uuidId), [_a, _b]);
      final first = job.items.first;
      expect(first.baseRevision, 7);
      expect(first.status, 'deleted');
      expect(first.error, isNull);
      expect(first.tombstoneRevision, 41);
      expect(first.details, ['master_missing', 'storage_cleanup_pending']);
      final second = job.items.last;
      expect(second.status, 'failed');
      expect(second.error, 'path_rejected');
      expect(second.tombstoneRevision, isNull);
      expect(second.details, isEmpty);
    });

    test('a status or code this client does not know is kept as sent', () {
      final job = DeletionJobDto.fromJson(_wire(_job(
        status: 'archived',
        items: [_item(status: 'quarantined', error: 'new_code')],
      )));
      expect(job.status, 'archived');
      expect(job.items.single.status, 'quarantined');
      expect(job.items.single.error, 'new_code');
    });

    test('a required field missing or of the wrong type is a FormatException',
        () {
      for (final bad in <Object?>[
        null,
        {..._job()}..remove('operation_uuid'),
        {..._job()}..remove('status'),
        {..._job(), 'created_at': '1'},
        {..._job(), 'item_count': null},
        {..._job(), 'items': {}},
        _job(items: [{..._item()}..remove('status')]),
        _job(items: [{..._item(), 'details': 'master_missing'}]),
        _job(items: [_item(details: [1])]),
        _job(items: [{..._item(), 'tombstone_revision': '4'}]),
        _job(items: [{..._item(), 'error': 5}]),
      ]) {
        expect(
          () => DeletionJobDto.fromJson(_wire(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('toJson round-trips the server shape', () {
      final json = _job(
        status: 'running',
        items: [
          _item(status: 'deleted', tombstoneRevision: 3, details: ['x']),
          _item(uuid: _b, status: 'running'),
        ],
      );
      expect(_wire(DeletionJobDto.fromJson(_wire(json)).toJson()), _wire(json));
    });
  });

  group('DeletionJobPageDto (the receipts list)', () {
    test('parses summaries and the cursor; a last page has a null cursor', () {
      final page = DeletionJobPageDto.fromJson(_wire({
        'jobs': [
          {
            'operation_uuid': _op,
            'created_at': 1762800000,
            'status': 'succeeded',
            'item_count': 3,
            'state_counts': {'deleted': 2, 'already_deleted': 1},
          },
        ],
        'next_after': 'opaque-cursor',
      }));
      final s = page.jobs.single;
      expect(s.operationUuid, _op);
      expect(s.createdAt, 1762800000);
      expect(s.status, 'succeeded');
      expect(s.itemCount, 3);
      expect(s.stateCounts, {'deleted': 2, 'already_deleted': 1});
      expect(page.nextAfter, 'opaque-cursor');

      final last = DeletionJobPageDto.fromJson(
        _wire({'jobs': [], 'next_after': null}),
      );
      expect(last.jobs, isEmpty);
      expect(last.nextAfter, isNull);
    });

    test('malformed pages are a FormatException', () {
      final summary = {
        'operation_uuid': _op,
        'created_at': 1,
        'status': 'pending',
        'item_count': 1,
        'state_counts': {'pending': 1},
      };
      for (final bad in <Object?>[
        {'jobs': null, 'next_after': null},
        {'jobs': [], 'next_after': 3},
        {'jobs': [{...summary, 'state_counts': []}]},
        {'jobs': [{...summary, 'state_counts': {'pending': '1'}}]},
        {'jobs': [{...summary}..remove('item_count')]},
      ]) {
        expect(
          () => DeletionJobPageDto.fromJson(_wire(bad)),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });
  });
}
