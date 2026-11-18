// 8B.1c S2: the words a user reads about server deletion, from one place
// (as `upload_status_text.dart` does for uploads). Plain language: no error
// codes, ids, paths or raw server text.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/deletion/deletion_text.dart';

const _uuid = '6f1c2a9e-0000-4000-8000-00000000abcd';

DeleteJobItem _item(
  String status, {
  String? error,
  List<String> details = const [],
}) => DeleteJobItem.fromDto(
  DeletionJobItemDto(
    uuidId: _uuid,
    baseRevision: 3,
    status: status,
    error: error,
    tombstoneRevision: status == 'deleted' ? 4 : null,
    details: details,
  ),
);

/// Every server code the client may meet (O12's closed list, the outcome
/// states and the error envelope codes the page can see).
const _codes = [
  'not_found',
  'conflict',
  'busy',
  'path_rejected',
  'rename',
  'recovery_required',
  'internal_error',
  'master_missing',
  'storage_cleanup_pending',
  'track_pending_deletion',
  'library_delete_disabled',
  'operation_conflict',
  'deletion_job_not_found',
  'validation_error',
  'already_deleted',
  'http_500',
];

void _plain(String text) {
  expect(text.trim(), isNotEmpty);
  expect(text, isNot(contains('_')), reason: 'no code in "$text"');
  expect(text, isNot(contains(_uuid)), reason: 'no id in "$text"');
  expect(text, isNot(contains('/')), reason: 'no path in "$text"');
  for (final code in _codes) {
    expect(text.toLowerCase(), isNot(contains(code)));
  }
}

void main() {
  group('preview verdicts', () {
    test('every verdict has its own plain sentence', () {
      final texts = {
        for (final v in PreviewVerdict.values) v: previewVerdictText(v),
      };
      texts.values.forEach(_plain);
      expect(texts.values.toSet().length, PreviewVerdict.values.length);
    });

    test('a file the server could not check says so, in the owner\'s words '
        '(sign-off OPEN-8-07 row 2)', () {
      expect(
        previewVerdictText(PreviewVerdict.fileStatusUnknown),
        "The server can't check this file, so it may refuse to delete it.",
      );
    });

    test('a missing master is the spec\'s catalog-entry removal', () {
      expect(
        previewVerdictText(PreviewVerdict.missingMaster),
        contains('Remove missing-file catalog entry'),
      );
    });

    test('an unknown revision says to refresh; a conflict to refresh or '
        'remove; busy to remove or wait', () {
      expect(
        previewVerdictText(PreviewVerdict.revisionUnknown).toLowerCase(),
        contains('refresh'),
      );
      final conflict = previewVerdictText(
        PreviewVerdict.conflict,
      ).toLowerCase();
      expect(conflict, contains('changed'));
      expect(conflict, contains('refresh'));
      expect(conflict, contains('remove'));
      expect(
        previewVerdictText(PreviewVerdict.busy).toLowerCase(),
        contains('remove'),
      );
      expect(
        previewVerdictText(PreviewVerdict.unknownTrack).toLowerCase(),
        contains('not found'),
      );
      expect(
        previewVerdictText(PreviewVerdict.alreadyDeleted).toLowerCase(),
        contains('already deleted'),
      );
    });
  });

  group('per-target outcomes', () {
    test('deleted, with storage still to reclaim, says so', () {
      expect(
        deleteItemOutcomeText(
          _item('deleted', details: const ['storage_cleanup_pending']),
        ),
        'Deleted; storage cleanup pending',
      );
      expect(deleteItemOutcomeText(_item('deleted')), 'Deleted');
    });

    test('deleted with the file already missing says so', () {
      final t = deleteItemOutcomeText(
        _item('deleted', details: const ['master_missing']),
      );
      expect(t, startsWith('Deleted'));
      expect(t.toLowerCase(), contains('missing'));
    });

    test('a deletion that failed for a database error other than busy says '
        'nothing was removed (sign-off DEV-8-17 item 4)', () {
      expect(
        deleteItemOutcomeText(_item('failed', error: 'internal_error')),
        "Not deleted: the server couldn't finish the deletion, so nothing was "
        'removed',
      );
    });

    test('each failure reason reads differently, and none is a code', () {
      final texts = [
        deleteItemOutcomeText(_item('conflict', error: 'conflict')),
        deleteItemOutcomeText(_item('busy', error: 'busy')),
        deleteItemOutcomeText(_item('failed', error: 'not_found')),
        deleteItemOutcomeText(_item('failed', error: 'path_rejected')),
        deleteItemOutcomeText(_item('failed', error: 'rename')),
        deleteItemOutcomeText(_item('failed', error: 'recovery_required')),
        deleteItemOutcomeText(_item('failed', error: 'internal_error')),
        deleteItemOutcomeText(_item('failed')),
        deleteItemOutcomeText(_item('failed', error: 'something_new')),
      ];
      texts.forEach(_plain);
      // Every known reason is distinct; an unknown code reads like a bare
      // failure (never echoed).
      expect(texts.take(8).toSet().length, 8);
      expect(texts[8], texts[7]);
      for (final t in texts) {
        expect(t, startsWith('Not deleted'));
      }
    });

    test('in-flight, already deleted and unknown states', () {
      final pending = deleteItemOutcomeText(_item('pending'));
      final running = deleteItemOutcomeText(_item('running'));
      final already = deleteItemOutcomeText(_item('already_deleted'));
      final unknown = deleteItemOutcomeText(_item('quantum'));
      for (final t in [pending, running, already, unknown]) {
        _plain(t);
      }
      expect({pending, running, already, unknown}.length, 4);
      expect(already.toLowerCase(), contains('already deleted'));
      expect(unknown, isNot(contains('quantum')));
    });
  });

  group('job phases', () {
    test('every phase has its own plain text', () {
      final texts = [for (final p in DeleteJobPhase.values) jobPhaseText(p)];
      texts.forEach(_plain);
      expect(texts.toSet().length, DeleteJobPhase.values.length);
    });

    test('a lost answer says the app is checking and will not resend', () {
      final t = jobPhaseText(DeleteJobPhase.unconfirmed).toLowerCase();
      expect(t, contains('checking'));
      expect(t, contains('not be sent again'));
    });
  });

  group('server refusals and errors', () {
    test('the switch turned off explains itself and that nothing was '
        'deleted', () {
      final t = deletionErrorText('library_delete_disabled');
      _plain(t);
      expect(t, contains('turned off'));
      expect(t, contains('Nothing was deleted'));
    });

    test('a track already being deleted', () {
      final t = deletionErrorText('track_pending_deletion');
      _plain(t);
      expect(t.toLowerCase(), contains('already being deleted'));
    });

    test('anything else is a plain refusal that never echoes the code', () {
      for (final code in [
        'operation_conflict',
        'validation_error',
        'http_500',
        'brand_new_code',
        null,
      ]) {
        final t = deletionErrorText(code);
        _plain(t);
        expect(t, contains('Nothing was deleted'));
        if (code != null) expect(t, isNot(contains(code)));
      }
    });
  });

  group('why deletion is unavailable', () {
    test('every reason has its own plain text', () {
      final texts = [
        for (final r in DeleteJobsUnavailableReason.values)
          unavailableText(r),
      ];
      texts.forEach(_plain);
      expect(texts.toSet().length, DeleteJobsUnavailableReason.values.length);
    });

    test('"turned off on this server" differs from "not offered"', () {
      expect(
        unavailableText(DeleteJobsUnavailableReason.switchedOff),
        'Server deletion is turned off on this server.',
      );
      expect(
        unavailableText(DeleteJobsUnavailableReason.notAdvertised),
        isNot(contains('turned off')),
      );
    });
  });

  group('receipt status (server summary strings)', () {
    test('known statuses read plainly; an unknown one is never echoed', () {
      final texts = [
        for (final s in [
          'pending',
          'running',
          'succeeded',
          'partial',
          'failed',
          'mystery_state',
        ])
          receiptStatusText(s),
      ];
      texts.forEach(_plain);
      expect(texts.take(5).toSet().length, 5);
      expect(texts.last, isNot(contains('mystery')));
    });
  });
}
