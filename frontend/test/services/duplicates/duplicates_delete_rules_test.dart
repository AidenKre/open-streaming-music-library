// Refactor APP-DUP (guide A.9): the Possible duplicates delete rules as pure
// model functions, with no controller, manager or provider. The controller's
// answers over the same rules are in
// test/ui/duplicates/duplicates_delete_rules_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/duplicates/duplicates_delete_rules.dart';

import '../../helpers/duplicate_fixtures.dart';

DeleteJob _job(
  DeleteJobPhase phase,
  List<String> targets, {
  Map<String, DeleteItemStatus> items = const {},
  String op = 'op',
}) => DeleteJob(
  operationUuid: op,
  phase: phase,
  targets: [
    for (final t in targets) DeletionTargetDto(uuidId: t, baseRevision: 1),
  ],
  items: [
    for (final MapEntry(:key, :value) in items.entries)
      DeleteJobItem(
        uuid: key,
        baseRevision: 1,
        status: value,
        rawStatus: value.name,
        errorCode: null,
        tombstoneRevision: null,
        details: const [],
      ),
  ],
);

void main() {
  test('pairKey joins the two copies in the server\'s order', () {
    expect(pairKey('a1', 'b1'), 'a1|b1');
    expect(pairKey('b1', 'a1'), isNot(pairKey('a1', 'b1')));
  });

  group('jobFreesCopy: only a rejection or a positive "not deleted"', () {
    const notDeleted = {
      DeleteItemStatus.conflict,
      DeleteItemStatus.busy,
      DeleteItemStatus.failed,
    };
    for (final phase in DeleteJobPhase.values) {
      for (final status in DeleteItemStatus.values) {
        final frees = phase == DeleteJobPhase.rejected ||
            (phase.isTerminal && notDeleted.contains(status));
        test('${phase.name} / ${status.name}: ${frees ? 'frees' : 'blocks'}',
            () {
          expect(
            jobFreesCopy(_job(phase, ['b1'], items: {'b1': status}), 'b1'),
            frees,
          );
        });
      }
      final frees = phase == DeleteJobPhase.rejected;
      test('${phase.name} / no outcome for the copy: '
          '${frees ? 'frees' : 'blocks'}', () {
        expect(
          jobFreesCopy(
            _job(phase, ['b1'], items: {'x9': DeleteItemStatus.conflict}),
            'b1',
          ),
          frees,
        );
      });
    }
  });

  group('duplicateDeleteBlocked', () {
    final pair = dupPair('a1', 'b1');

    test('nothing known: not blocked', () {
      expect(duplicateDeleteBlocked(pair, jobs: {}, submitted: [],
          unfinishedKnown: true), isFalse);
    });

    test('the server\'s unfinished deletions not read yet: blocked', () {
      expect(duplicateDeleteBlocked(pair, jobs: {}, submitted: [],
          unfinishedKnown: false), isTrue);
    });

    test('a submitted deletion blocks until its job is listed', () {
      final submitted = [(operation: 'op', pairKey: 'b1|c1', uuid: 'b1')];
      expect(
        duplicateDeleteBlocked(pair, jobs: {}, submitted: submitted,
            unfinishedKnown: true),
        isTrue,
      );
      expect(
        duplicateDeleteBlocked(
          pair,
          jobs: {'op': _job(DeleteJobPhase.rejected, ['b1'])},
          submitted: submitted,
          unfinishedKnown: true,
        ),
        isFalse,
      );
    });

    test('a submitted deletion of another pair\'s other copy does not block',
        () {
      expect(
        duplicateDeleteBlocked(
          pair,
          jobs: {},
          submitted: [(operation: 'op', pairKey: 'b1|c1', uuid: 'c1')],
          unfinishedKnown: true,
        ),
        isFalse,
      );
    });

    test('any job on either copy that does not free it blocks', () {
      expect(
        duplicateDeleteBlocked(
          pair,
          jobs: {
            'op-1': _job(DeleteJobPhase.rejected, ['b1'], op: 'op-1'),
            'op-2': _job(DeleteJobPhase.running, ['a1'], op: 'op-2'),
          },
          submitted: [],
          unfinishedKnown: true,
        ),
        isTrue,
      );
    });
  });

  test('duplicateDeleteStatus: the newest job, the copy\'s outcome first', () {
    final pair = dupPair('a1', 'b1');
    final jobs = [
      _job(DeleteJobPhase.failed, ['b1'],
          items: {'b1': DeleteItemStatus.busy}, op: 'op-1'),
      _job(DeleteJobPhase.completed, ['a1'],
          items: {'a1': DeleteItemStatus.deleted}, op: 'op-2'),
    ];
    expect(duplicateDeleteStatus(pair, jobs), 'Deleted');
    expect(duplicateDeleteStatus(pair, jobs.take(1)),
        'Not deleted: the server was working on it');
    expect(duplicateDeleteStatus(pair, const []), isNull);
  });

  group('sameDuplicatePairSnapshot', () {
    DuplicatePairDto p({
      String a = 'a1',
      String b = 'b1',
      String status = 'open',
      int ra = 3,
      int rb = 7,
    }) => dupPair(a, b,
        status: status,
        trackA: dupTrack(a, revision: ra),
        trackB: dupTrack(b, revision: rb, codec: 'mp3'));

    final base = p();
    final rows = <(String, DuplicatePairDto, bool)>[
      ('same', p(), true),
      ('copy A revision', p(ra: 4), false),
      ('copy B revision', p(rb: 8), false),
      ('status', p(status: 'dismissed'), false),
      ('copy A', p(a: 'a9'), false),
      ('copy B', p(b: 'b9'), false),
    ];
    for (final (name, other, same) in rows) {
      test('$name: ${same ? 'same' : 'different'}', () {
        expect(sameDuplicatePairSnapshot(base, other), same);
        expect(sameDuplicatePairSnapshot(other, base), same);
      });
    }
  });
}
