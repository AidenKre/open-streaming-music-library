// 8B.1c S6: the Manage library controller over the real delete-jobs model
// and a real in-memory library.
//  * Spec §3: the action only with `server_delete`; "turned off" differs
//    from "not offered"; a cached block or offline never enables it.
//  * Spec §6 para 3: a selected-items panel with explicit Clear; "Leaving
//    Manage library clears an unsubmitted selection"; rows show title /
//    artist / album (no ID: the owner's rule replaces "UUID disambiguation if
//    needed"); a selected track that sync has since removed still counts
//    and can be removed.
//  * Spec §4 para 4 / §6 para 4: the job view shows partial success and
//    each reason; "deleted; storage cleanup pending"; receipts are
//    recoverable through `GET /tracks/deletions` (keyset) and hydrate
//    titles for still-resolvable UUIDs.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/browse_repository.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/deletion/deletion_text.dart';
import 'package:frontend/services/deletion/server_delete_availability.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/library_seed.dart' show SeedTrack, seedLibrary;
import '../../helpers/stub_track_sync.dart';
import '../../helpers/test_offline.dart';

const _on = AdvertisedFeature(
  LibraryToolsFeature(version: 1, serverDelete: true, duplicateReview: false),
  fromCache: false,
);

/// Only the manager's job map, set by the test.
class _JobsOnly implements DeleteJobsManager {
  final map = ValueNotifier<Map<String, DeleteJob>>(const {});

  @override
  ValueListenable<Map<String, DeleteJob>> get jobs => map;

  void publish(DeleteJob job) =>
      map.value = {...map.value, job.operationUuid: job};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A local library whose reads fail.
class _FailingBrowse implements BrowseRepository {
  @override
  Future<List<TrackUI>> getTracksByUuids(List<String> uuids) async =>
      throw StateError('hydrate boom');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late DeleteJobsHarness h;
  late ProviderContainer c;
  late ManageLibraryControls m;
  late TestOffline offline;

  Future<void> build({
    Future<AdvertisedFeature<LibraryToolsFeature>?> Function()? feature,
    bool isOffline = false,
    DeleteJobsManager? manager,
    BrowseRepository? browse,
  }) async {
    offline = TestOffline(isOffline);
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(h.db),
        deleteJobsManagerProvider.overrideWithValue(manager ?? h.manager),
        if (browse != null) browseRepositoryProvider.overrideWithValue(browse),
        libraryToolsApiProvider.overrideWithValue(h.api),
        trackSyncProvider.overrideWith(StubTrackSync.new),
        offlineModeProvider.overrideWith(() => offline),
        libraryToolsFeatureProvider.overrideWith(
          (ref) => (feature ?? () async => _on)(),
        ),
      ],
    );
    m = c.read(manageLibraryControllerFactoryProvider)();
    await h.pump();
  }

  setUp(() async {
    h = await DeleteJobsHarness.create();
    await h.verify();
    await seedLibrary(h.db, const [
      SeedTrack(
        uuid: 's1',
        title: 'First Song',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        revision: 4,
      ),
      SeedTrack(
        uuid: 'twin-aaaa1111',
        title: 'Same Name',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        trackNumber: 2,
        revision: 2,
      ),
      SeedTrack(
        uuid: 'twin-bbbb2222',
        title: 'Same Name',
        artistId: 1,
        artist: 'Artist',
        albumId: 10,
        album: 'Album',
        trackNumber: 3,
        revision: 3,
      ),
    ]);
  });

  tearDown(() async {
    m.dispose();
    c.dispose();
    await h.dispose();
  });

  Future<TrackUI> local(String uuid) async =>
      (await c.read(browseRepositoryProvider).getTracksByUuids([uuid])).single;

  TrackUI ghost(String uuid) => TrackUI(
    uuidId: uuid,
    createdAt: 0,
    lastUpdated: 0,
    revision: 1,
    title: 'Ghost',
    duration: 60,
    bitrateKbps: 320,
    sampleRateHz: 44100,
    channels: 2,
    hasAlbumArt: false,
  );

  Future<void> select(List<TrackUI> tracks) async {
    for (final t in tracks) {
      m.selection.toggle(t);
    }
    await h.pump();
  }

  group('availability', () {
    test('enabled with a live block that has server_delete', () async {
      await build();
      expect(m.availability, ServerDeleteAvailability.enabled);
    });

    test('turned off, not offered, offline and loading are distinct',
        () async {
      await build(
        feature: () async => const AdvertisedFeature(
          LibraryToolsFeature(
            version: 1,
            serverDelete: false,
            duplicateReview: false,
          ),
          fromCache: false,
        ),
      );
      expect(m.availability, ServerDeleteAvailability.switchedOff);
      m.dispose();
      c.dispose();

      await build(feature: () async => null);
      expect(m.availability, ServerDeleteAvailability.notOffered);
      m.dispose();
      c.dispose();

      await build(isOffline: true);
      expect(m.availability, ServerDeleteAvailability.unreachable);
      m.dispose();
      c.dispose();

      final never = Completer<AdvertisedFeature<LibraryToolsFeature>?>();
      await build(feature: () => never.future);
      expect(m.availability, ServerDeleteAvailability.checking);
    });

    test('review r1: a failed server-info read is unknown (unreachable), '
        'never "not offered"', () async {
      await build(feature: () async => throw StateError('info failed'));
      expect(m.availability, ServerDeleteAvailability.unreachable);
    });

    test('going offline while on the page makes it unreachable and '
        'notifies', () async {
      await build();
      var notified = 0;
      m.addListener(() => notified++);
      offline.set(true);
      await h.pump();
      expect(m.availability, ServerDeleteAvailability.unreachable);
      expect(notified, greaterThan(0));
    });
  });

  group('selected items', () {
    test('hydrated from the local library, in selection order', () async {
      await build();
      await select([await local('twin-bbbb2222'), await local('s1')]);
      expect(m.selectedItems.map((i) => (i.uuid, i.title, i.artist, i.album)), [
        ('twin-bbbb2222', 'Same Name', 'Artist', 'Album'),
        ('s1', 'First Song', 'Artist', 'Album'),
      ]);
      expect(m.selectedItems.every((i) => i.inLocalLibrary), isTrue);
    });

    // No ID tells them apart (the page test shows none is shown);
    // each is its own item, by its own uuid.
    test('two tracks that would read the same are two items, each by its '
        'own uuid', () async {
      await build();
      await select([
        await local('twin-aaaa1111'),
        await local('twin-bbbb2222'),
        await local('s1'),
      ]);
      expect(m.selectedItems.map((i) => (i.uuid, i.title, i.artist, i.album)), [
        ('twin-aaaa1111', 'Same Name', 'Artist', 'Album'),
        ('twin-bbbb2222', 'Same Name', 'Artist', 'Album'),
        ('s1', 'First Song', 'Artist', 'Album'),
      ]);
    });

    test('a selected track no longer in the local library still counts, '
        'shows as unknown, and can be removed', () async {
      await build();
      await select([await local('s1'), ghost('gone-1')]);
      final gone = m.selectedItems.last;
      expect(gone.uuid, 'gone-1');
      expect(gone.inLocalLibrary, isFalse);
      expect(gone.title, isNull);
      expect(m.selection.count, 2);

      m.removeSelected('gone-1');
      await h.pump();
      expect(m.selectedItems.map((i) => i.uuid), ['s1']);
    });

    test('Clear empties the selection', () async {
      await build();
      await select([await local('s1')]);
      m.clearSelection();
      await h.pump();
      expect(m.selection.count, 0);
      expect(m.selectedItems, isEmpty);
    });

    test('leaving the page (dispose) drops an unsubmitted selection and '
        'sends nothing', () async {
      await build();
      await select([await local('s1')]);
      final old = m.selection;
      m.dispose();
      old.toggle(await local('twin-aaaa1111'));
      expect(old.count, 1, reason: 'the old selection is disposed');
      m = c.read(manageLibraryControllerFactoryProvider)();
      await h.pump();
      expect(m.selection.count, 0);
      expect(h.api.calls, isEmpty);
    });
  });

  group('jobs', () {
    Future<String> submitted(List<String> uuids) async {
      await select([for (final u in uuids) await local(u)]);
      await m.review.requestPreview();
      await h.pump();
      final shown = m.review.preview!;
      expect(await m.review.confirm(shown, confirmedCount: shown.count), isTrue);
      await h.pump();
      return m.review.submittedOperation!;
    }

    test('a submitted job shows each target with the previewed title, then '
        'each per-target result', () async {
      await build();
      final op = await submitted(['s1', 'twin-aaaa1111']);
      final job = m.jobs.single;
      expect(job.operationUuid, op);
      expect(job.phase, DeleteJobPhase.accepted);
      expect(job.phaseText, jobPhaseText(DeleteJobPhase.accepted));
      // The fake server's preview titles ("Title <uuid>").
      expect(job.targets.map((t) => t.title), ['Title s1', 'Title twin-aaaa1111']);

      h.api.serverJobs[op] = deletionJobJson(op, [
        deletionItemJson(
          's1',
          baseRevision: 4,
          status: 'deleted',
          tombstoneRevision: 5,
          details: const ['storage_cleanup_pending'],
        ),
        deletionItemJson(
          'twin-aaaa1111',
          baseRevision: 2,
          status: 'conflict',
          error: 'conflict',
        ),
      ], status: 'partial');
      h.timers.fire();
      await h.pump();

      final done = m.jobs.single;
      expect(done.phase, DeleteJobPhase.partial);
      expect(done.targets.map((t) => (t.outcome, t.deleted)), [
        ('Deleted; storage cleanup pending', true),
        (
          deleteItemOutcomeText(
            DeleteJobItem.fromDto(
              DeletionJobItemDto.fromJson(
                deletionItemJson(
                  'twin-aaaa1111',
                  baseRevision: 2,
                  status: 'conflict',
                  error: 'conflict',
                ),
              ),
            ),
          ),
          false,
        ),
      ]);
    });

    test('a job refused because the switch was turned off explains itself',
        () async {
      await build();
      h.api.onCreateJob = (_) async =>
          throw apiError(403, 'library_delete_disabled', retryable: false);
      await submitted(['s1']);
      final job = m.jobs.single;
      expect(job.phase, DeleteJobPhase.rejected);
      expect(job.refusal, deletionErrorText('library_delete_disabled'));
    });

    test('a lost answer shows as being checked', () async {
      await build();
      final store = h.api.onCreateJob;
      h.api.onCreateJob = (body) async {
        await store(body);
        throw TimeoutException('lost');
      };
      await submitted(['s1']);
      expect(m.jobs.single.phase, DeleteJobPhase.unconfirmed);
      expect(m.jobs.single.phaseText, jobPhaseText(DeleteJobPhase.unconfirmed));
    });

    // One total order, whatever order the jobs became known in.
    // Jobs still being sent or not yet confirmed come first; the others
    // follow newest first, by the server's date, else by when this device
    // submitted them.
    group('order', () {
      DeleteJob job(
        String op,
        int? createdAt, {
        DeleteJobPhase phase = DeleteJobPhase.accepted,
        int? submittedAtMs,
      }) => DeleteJob(
        operationUuid: op,
        phase: phase,
        targets: const [],
        createdAt: createdAt,
        submittedAtMs: submittedAtMs,
      );
      final a = job('A', 200),
          b = job('B', null, phase: DeleteJobPhase.submitting),
          cc = job('C', 100);
      const insertions = [
        ['A', 'B', 'C'],
        ['A', 'C', 'B'],
        ['B', 'A', 'C'],
        ['B', 'C', 'A'],
        ['C', 'A', 'B'],
        ['C', 'B', 'A'],
      ];
      for (final order in insertions) {
        test('undated first, then newest first: published ${order.join()}',
            () async {
          final jobs = _JobsOnly();
          await build(manager: jobs);
          for (final op in order) {
            jobs.publish({'A': a, 'B': b, 'C': cc}[op]!);
            await h.pump();
          }
          expect(m.jobs.map((j) => j.operationUuid), ['B', 'A', 'C']);
        });
      }

      test('same date: the one that became known later comes first',
          () async {
        final jobs = _JobsOnly();
        await build(manager: jobs);
        for (final j in [
          job('X', 100),
          job('Y', 100),
          job('U', null, phase: DeleteJobPhase.submitting),
          job('V', null, phase: DeleteJobPhase.unconfirmed),
        ]) {
          jobs.publish(j);
          await h.pump();
        }
        expect(m.jobs.map((j) => j.operationUuid), ['V', 'U', 'Y', 'X']);
      });

      test('a refused job stays below a later dated job', () async {
        final jobs = _JobsOnly();
        await build(manager: jobs);
        jobs.publish(job('R', null,
            phase: DeleteJobPhase.rejected, submittedAtMs: 150000));
        await h.pump();
        jobs.publish(job('A', 200));
        await h.pump();
        jobs.publish(job('C', 100));
        await h.pump();
        expect(m.jobs.map((j) => j.operationUuid), ['A', 'R', 'C']);
      });

      // A refused job and an accepted job whose receipt could not be read:
      // neither has a server date.
      final undated = {
        'R': job('R', null,
            phase: DeleteJobPhase.rejected, submittedAtMs: 250000),
        'Q': job('Q', null, submittedAtMs: 150000),
        'A': job('A', 200),
      };
      for (final order in const [
        ['R', 'Q', 'A'],
        ['A', 'Q', 'R'],
        ['Q', 'A', 'R'],
      ]) {
        test('a job the server has not dated takes its place by when this '
            'device submitted it: published ${order.join()}', () async {
          final jobs = _JobsOnly();
          await build(manager: jobs);
          for (final op in order) {
            jobs.publish(undated[op]!);
            await h.pump();
          }
          expect(m.jobs.map((j) => j.operationUuid), ['R', 'A', 'Q']);
        });
      }

      test('a job with neither date comes last', () async {
        final jobs = _JobsOnly();
        await build(manager: jobs);
        jobs.publish(job('N', null, phase: DeleteJobPhase.rejected));
        await h.pump();
        jobs.publish(job('C', 100));
        await h.pump();
        expect(m.jobs.map((j) => j.operationUuid), ['C', 'N']);
      });
    });

    // A failed local-library read logs the error itself, with
    // its type.
    group('a failed local-library read', () {
      late List<String> printed;

      void capture() {
        printed = [];
        final original = debugPrint;
        debugPrint = (String? message, {int? wrapWidth}) =>
            printed.add('$message');
        addTearDown(() => debugPrint = original);
      }

      test('for a job change logs the error', () async {
        capture();
        final jobs = _JobsOnly();
        await build(manager: jobs, browse: _FailingBrowse());
        jobs.publish(const DeleteJob(
          operationUuid: 'op1',
          phase: DeleteJobPhase.accepted,
          targets: [DeletionTargetDto(uuidId: 's1', baseRevision: 4)],
        ));
        await h.pump();
        expect(printed, [allOf(contains('StateError'), contains('hydrate boom'))]);
      });

      test('for a selection change logs the error', () async {
        capture();
        await build(browse: _FailingBrowse());
        await select([ghost('s1')]);
        expect(printed, [allOf(contains('StateError'), contains('hydrate boom'))]);
      });
    });
  });

  group('receipts', () {
    DeletionJobSummaryDto summary(String op, String status, int created) =>
        DeletionJobSummaryDto.fromJson({
          'operation_uuid': op,
          'created_at': created,
          'status': status,
          'item_count': 2,
          'state_counts': {'deleted': 1, 'conflict': 1},
        });

    test('pages through GET /tracks/deletions by its cursor', () async {
      h.api.onListJobs = (after, limit) async => after == null
          ? DeletionJobPageDto(
              jobs: [
                summary('r1', 'succeeded', 100),
                summary('r2', 'partial', 101),
              ],
              nextAfter: 'cur-1',
            )
          : DeletionJobPageDto(
              jobs: [summary('r3', 'failed', 102)],
              nextAfter: null,
            );
      await build();
      await m.loadReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.loaded);
      expect(m.receipts.map((r) => (r.operationUuid, r.statusText)), [
        ('r1', receiptStatusText('succeeded')),
        ('r2', receiptStatusText('partial')),
      ]);
      expect(m.hasMoreReceipts, isTrue);

      await m.loadMoreReceipts();
      await h.pump();
      expect(m.receipts.map((r) => r.operationUuid), ['r1', 'r2', 'r3']);
      expect(m.hasMoreReceipts, isFalse);
      expect(h.api.callsOf('listJobs'), ['listJobs null', 'listJobs cur-1']);

      await m.loadMoreReceipts(); // nothing more to load
      expect(h.api.callsOf('listJobs'), hasLength(2));
    });

    test('a failed load keeps what was loaded and says so', () async {
      var n = 0;
      h.api.onListJobs = (after, limit) async {
        if (n++ == 0) {
          return DeletionJobPageDto(
            jobs: [summary('r1', 'succeeded', 100)],
            nextAfter: 'cur-1',
          );
        }
        throw NetworkException('down', attemptsMade: 1);
      };
      await build();
      await m.loadReceipts();
      await m.loadMoreReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.failed);
      expect(m.receipts.map((r) => r.operationUuid), ['r1']);
      expect(m.hasMoreReceipts, isTrue);
    });

    test('opening a receipt shows its targets with local titles where they '
        'still resolve', () async {
      h.api.serverJobs['r1'] = deletionJobJson('r1', [
        deletionItemJson('s1', baseRevision: 4, status: 'conflict',
            error: 'conflict'),
        deletionItemJson('gone-2', baseRevision: 1, status: 'deleted',
            tombstoneRevision: 2),
      ], status: 'partial');
      h.api.onListJobs = (after, limit) async => DeletionJobPageDto(
        jobs: [summary('r1', 'partial', 100)],
        nextAfter: null,
      );
      await build();
      await m.loadReceipts();
      m.openReceipt('r1');
      await h.pump();
      expect(h.api.callsOf('getJob'), contains('getJob r1'));
      final job = m.jobs.singleWhere((j) => j.operationUuid == 'r1');
      expect(job.targets.map((t) => (t.uuid, t.title)), [
        ('s1', 'First Song'),
        ('gone-2', null),
      ]);
    });

    // 8-R1-22 / U33-B-02: Deletion history never spins for ever. Offline,
    // or with the binding unverified, it says it needs a connection at
    // once (as the preview does) and Retry works once connected.
    test('offline: needs a connection, nothing is asked of the server',
        () async {
      await build(isOffline: true);
      await m.loadReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
      expect(h.api.callsOf('listJobs'), isEmpty);
    });

    // Review r2 8-R2-04: opened offline, it reloads by itself once the app
    // is back online (no Retry tap), as it does when the binding verifies.
    test('offline then online: loads by itself', () async {
      h.api.onListJobs = (after, limit) async => DeletionJobPageDto(
        jobs: [summary('r1', 'succeeded', 100)],
        nextAfter: null,
      );
      await build(isOffline: true);
      await m.loadReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.needsConnection);

      offline.set(false);
      await h.pump();
      expect(h.api.callsOf('listJobs'), ['listJobs null']);
      expect(m.receiptsLoad, ReceiptsLoad.loaded);
      expect(m.receipts.map((r) => r.operationUuid), ['r1']);
    });

    test('online again before Deletion history was opened asks nothing',
        () async {
      await build(isOffline: true);
      offline.set(false);
      await h.pump();
      expect(h.api.callsOf('listJobs'), isEmpty);
      expect(m.receiptsLoad, ReceiptsLoad.idle);
    });

    test('binding unverified: needs a connection at once; Retry after '
        'verification loads', () async {
      h.api.onListJobs = (after, limit) async => DeletionJobPageDto(
        jobs: [summary('r1', 'succeeded', 100)],
        nextAfter: null,
      );
      await build();
      // A connection edge (resume, network recovery) clears the
      // verification; the probe has not answered.
      unawaited(h.gate.gate.startConnection('http://test'));
      await h.pump();
      await m.loadReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
      expect(m.receipts, isEmpty);

      h.gate.respond(h.instanceId);
      await h.pump();
      await m.retryReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.loaded);
      expect(m.receipts.map((r) => r.operationUuid), ['r1']);
    });

    // Review r1 RC-1 / R7: no Retry tap needed once the binding verifies.
    test('binding unverified: loads by itself once it verifies', () async {
      h.api.onListJobs = (after, limit) async => DeletionJobPageDto(
        jobs: [summary('r1', 'succeeded', 100)],
        nextAfter: null,
      );
      await build();
      unawaited(h.gate.gate.startConnection('http://test'));
      await h.pump();
      await m.loadReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
      h.gate.respond(h.instanceId);
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.loaded);
      expect(m.receipts.map((r) => r.operationUuid), ['r1']);
    });

    test('Retry after a failed reload of the first page reloads the first '
        'page, not the next one (B-06)', () async {
      var n = 0;
      h.api.onListJobs = (after, limit) async {
        n++;
        if (n == 2) throw NetworkException('down', attemptsMade: 1);
        return DeletionJobPageDto(
          jobs: [summary(n == 1 ? 'r1' : 'r9', 'succeeded', 100)],
          nextAfter: 'cur-1',
        );
      };
      await build();
      await m.loadReceipts();
      await h.pump();
      await m.loadReceipts(); // reopening the page: fails
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.failed);
      expect(m.receipts.map((r) => r.operationUuid), ['r1'], reason: 'kept');

      await m.retryReceipts();
      await h.pump();
      expect(h.api.callsOf('listJobs'), [
        'listJobs null',
        'listJobs null',
        'listJobs null',
      ]);
      expect(m.receipts.map((r) => r.operationUuid), ['r9']);
      expect(m.receiptsLoad, ReceiptsLoad.loaded);
    });

    test('Retry after a failed next page loads that page', () async {
      var n = 0;
      h.api.onListJobs = (after, limit) async {
        n++;
        if (n == 2) throw NetworkException('down', attemptsMade: 1);
        return DeletionJobPageDto(
          jobs: [summary('r$n', 'succeeded', 100)],
          nextAfter: after == null ? 'cur-1' : null,
        );
      };
      await build();
      await m.loadReceipts();
      await m.loadMoreReceipts();
      await h.pump();
      expect(m.receiptsLoad, ReceiptsLoad.failed);
      await m.retryReceipts();
      await h.pump();
      expect(h.api.callsOf('listJobs'), [
        'listJobs null',
        'listJobs cur-1',
        'listJobs cur-1',
      ]);
      expect(m.receipts.map((r) => r.operationUuid), ['r1', 'r3']);
    });
  });
}
