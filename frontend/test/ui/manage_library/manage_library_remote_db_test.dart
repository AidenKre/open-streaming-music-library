// Manage library over a database reached through drift's isolate protocol,
// as the app opens it (`NativeDatabase.createInBackground`): a job update
// the delete-jobs model checks against its binding fence (a transaction)
// still reaches the job card: the card's local-library read must not run on
// that transaction after it closed. (The card's title here comes from the
// preview.)
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/isolate.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';

import '../../helpers/delete_jobs_harness.dart';
import '../../helpers/library_seed.dart' show SeedTrack, seedLibrary;
import '../../helpers/stub_track_sync.dart';
import '../../helpers/test_offline.dart';

void main() {
  late DriftIsolate isolate;
  late DeleteJobsHarness h;
  late ProviderContainer c;
  late ManageLibraryControls m;

  setUp(() async {
    isolate = DriftIsolate.inCurrent(
      () => DatabaseConnection(NativeDatabase.memory()),
    );
    final db = AppDatabase(await isolate.connect());
    h = await DeleteJobsHarness.create(database: db);
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
    ]);
    c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(h.db),
        deleteJobsManagerProvider.overrideWithValue(h.manager),
        libraryToolsApiProvider.overrideWithValue(h.api),
        trackSyncProvider.overrideWith(StubTrackSync.new),
        offlineModeProvider.overrideWith(() => TestOffline(false)),
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
    m = c.read(manageLibraryControllerFactoryProvider)();
    await h.pump();
  });

  tearDown(() async {
    m.dispose();
    c.dispose();
    await h.dispose();
    await isolate.shutdownAll();
  });

  /// Runs event-loop turns (the database's port messages are events in this
  /// isolate) until [done] holds, at most a bounded number; no wall clock.
  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await pumpEventQueue(times: 5);
    }
  }

  test('each answer the server gives reaches the job card', () async {
    final track = (await c
            .read(browseRepositoryProvider)
            .getTracksByUuids(['s1']))
        .single;
    m.selection.toggle(track);
    await until(() => m.selectedItems.isNotEmpty);
    await m.review.requestPreview();
    await until(() => m.review.stage == ReviewStage.ready);
    final shown = m.review.preview!;
    expect(await m.review.confirm(shown, confirmedCount: 1), isTrue);
    await until(
      () => m.jobs.isNotEmpty && m.jobs.single.phase == DeleteJobPhase.accepted,
    );
    final op = m.review.submittedOperation!;
    expect(m.jobs.single.phase, DeleteJobPhase.accepted);

    h.api.serverJobs[op] = deletionJobJson(op, [
      deletionItemJson('s1', baseRevision: 4, status: 'deleted',
          tombstoneRevision: 5),
    ], status: 'succeeded');
    h.timers.fire();
    await until(() => m.jobs.single.phase == DeleteJobPhase.completed);
    final done = m.jobs.single;
    expect(done.phase, DeleteJobPhase.completed);
    expect(done.targets.single.title, 'Title s1');
    expect(done.targets.single.outcome, 'Deleted');
  });
}
