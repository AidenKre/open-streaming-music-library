// Phase 8B.1b S10: the delete-jobs model in the app's shared lifecycles.
//  * SC-13 / plan D29: a recovery member requests a pass on every trigger
//    (cold start, network recovery, app resume), gated on the binding; a
//    cold start resumes an unresolved submission without visiting any page.
//  * SC-15 / plan D30: a quiesce participant after uploads and before the
//    shared submissions helper; it never builds the manager just to stop it.
//  * SC-15 Disconnect copy: a loss reporter counts the deletions frozen on
//    this binding but not yet answered ("N deletions not yet confirmed": some may already have been accepted, 8-R1-26).
//  * One manager per scope over the scope's DurableSubmission; quiesced
//    when the scope is disposed.
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_library_tools_api.dart';
import '../../helpers/server_binding.dart';

String _frozen(String op, List<String> uuids) =>
    '{"operation_uuid":"$op","targets":['
    '${uuids.map((u) => '{"uuid_id":"$u","base_revision":1}').join(',')}'
    '],"confirmed_count":${uuids.length}}';

void main() {
  late AppDatabase db;
  late ProviderContainer c;
  late FakeLibraryToolsApi api;
  late String token;
  late _RecordingSync syncs;
  final clock = FakeClock();

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db, reconciled: true);
    api = FakeLibraryToolsApi();
    syncs = _RecordingSync();
    c = ProviderContainer(
      overrides: [
        trackSyncProvider.overrideWith(() => syncs),
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(clock),
        autoVerifiedGateOverride(),
        libraryToolsApiProvider.overrideWithValue(api),
        libraryToolsFeatureProvider.overrideWith(
          (ref) async => const AdvertisedFeature(
            LibraryToolsFeature(
              version: 1,
              serverDelete: true,
              duplicateReview: false,
            ),
            fromCache: false,
          ),
        ),
      ],
    );
  });
  tearDown(() async {
    c.dispose();
    await db.close();
  });

  DurableSubmission submissions() =>
      DurableSubmission(db: db, binding: ServerBindingRepository(db), clock: clock);

  Future<void> prepare(String op, List<String> uuids, {String? bindingToken}) =>
      submissions().prepare(
        kind: 'track_deletion',
        operationUuid: op,
        frozenBodyJson: _frozen(op, uuids),
        bindingToken: bindingToken ?? token,
      );

  Future<void> setState(String op, String state) => db.customStatement(
    "UPDATE durable_submissions SET state = '$state' WHERE operation_uuid = '$op'",
  );

  RecoverableService member() => c
      .read(recoverablesProvider)
      .singleWhere((m) => m.recoveryPriority == RecoveryPriority.deleteJobs);

  group('recovery member', () {
    test('requests a pass on every trigger, gated on the binding, after '
        'capabilities are fresh', () {
      final m = member();
      expect(m.requiresBinding, isTrue);
      expect(m.triggers, RecoveryTrigger.values.toSet());
      expect(RecoveryPriority.deleteJobs, lessThan(RecoveryPriority.appInfo));
    });

    test('a cold start resumes an unresolved submission', () async {
      await prepare('op-1', ['a']);

      await member().recover(RecoveryTrigger.coldStart);
      for (var i = 0; i < 10; i++) {
        await pumpEventQueue();
        await c.read(deleteJobsManagerProvider).idle();
      }

      expect(api.callsOf('createJob'), ['createJob op-1']);
      expect(api.createBodies.single, _frozen('op-1', ['a']));
    });
  });

  // 8-fix-r1 TR-DELETE-02: the post-deletion sync is a fresh pull (it waits
  // out a sync already in flight, whose pull may predate the tombstone) and
  // its outcome reaches the manager.
  group('post-deletion sync', () {
    for (final ran in [true, false]) {
      test('is a fresh pull, never the plain sync (fresh pull ran: $ran)',
          () async {
        syncs.freshResult = ran;
        api.onCreateJob = (body) async {
          api.serverJobs['op-1'] = deletionJobJson('op-1', [
            deletionItemJson('a',
                status: 'already_deleted', tombstoneRevision: 3),
          ], status: 'succeeded');
          return api.onGetJob('op-1');
        };
        await prepare('op-1', ['a']);

        c.read(deleteJobsManagerProvider).request('test', bypassBackoff: true);
        for (var i = 0; i < 10; i++) {
          await pumpEventQueue();
          await c.read(deleteJobsManagerProvider).idle();
        }

        expect(syncs.calls, ['syncFresh'],
            reason: 'never the plain sync, a no-op while one runs');
      });
    }
  });

  group('quiesce participant', () {
    test('runs after uploads and before the shared submissions helper', () {
      final names = [
        for (final q in c.read(localQuiescablesProvider)) q.quiesceName,
      ];
      final at = names.indexOf('delete-jobs');
      expect(at, greaterThan(names.indexOf('uploads')));
      expect(at, lessThan(names.indexOf('submissions')));
    });

    test('never builds the manager just to stop it; stops a built one',
        () async {
      final q = c
          .read(localQuiescablesProvider)
          .singleWhere((q) => q.quiesceName == 'delete-jobs');
      await q.quiesce();
      expect(c.exists(deleteJobsManagerProvider), isFalse);

      final manager = c.read(deleteJobsManagerProvider);
      await q.quiesce();
      expect(manager.isClosed, isTrue);
    });

    test('the scope dispose quiesces the manager', () {
      final manager = c.read(deleteJobsManagerProvider);
      c.dispose();
      expect(manager.isClosed, isTrue);
    });
  });

  group('loss reporter', () {
    LossReporter reporter() => c
        .read(lossReportersProvider)
        .whereType<DeleteJobsLossReporter>()
        .single;

    test('nothing pending: no line', () async {
      expect(await reporter().pendingLossSummary(), isNull);
    });

    test('counts the tracks of this binding\'s unanswered deletions', () async {
      await prepare('op-1', ['a', 'b']);
      await prepare('op-2', ['c']);
      await setState('op-2', 'ambiguous');
      await prepare('op-3', ['d']);
      await setState('op-3', 'sent');
      await prepare('op-4', ['e', 'f']);
      await setState('op-4', 'accepted');
      await prepare('op-5', ['g']);
      await setState('op-5', 'rejected');
      await submissions().prepare(
        kind: 'upload_allocation',
        operationUuid: 'up-1',
        frozenBodyJson: '{}',
        bindingToken: token,
      );

      expect(await reporter().pendingLossSummary(), '4 deletions not yet confirmed');
    });

    test('one deletion is singular', () async {
      await prepare('op-1', ['a']);
      expect(await reporter().pendingLossSummary(), '1 deletion not yet confirmed');
    });

    // Round 3: records kept from an ended sign-in (a same-user log-out
    // rotated the token) count, since a reset removes them; with no binding
    // at all there is nothing.
    test('an earlier sign-in\'s kept rows count; no binding at all reports '
        'nothing',
        () async {
      await prepare('op-1', ['a']);
      await ServerBindingRepository(db).rotate();
      expect(await reporter().pendingLossSummary(), '1 deletion not yet confirmed');

      await ServerBindingRepository(db).fence();
      expect(await reporter().pendingLossSummary(), isNull);
    });
  });
}

class _RecordingSync extends TrackSyncNotifier {
  final calls = <String>[];
  bool freshResult = true;

  @override
  Future<void> sync() async => calls.add('sync');

  @override
  Future<bool> syncFresh() async {
    calls.add('syncFresh');
    return freshResult;
  }
}
