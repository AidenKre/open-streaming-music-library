// Refactor APP-DUP (A.9 leftover, the owner: "follow the recommendation"):
// characterization of Deletion history's "reload when the connection is
// verified again", before the block it shares with Possible duplicates
// becomes one helper. A receipts read that fails fast as not connected waits
// once (no polling) for the binding to verify, then repeats the last
// request, only while the page still needs a connection. The rest of this
// behaviour is in manage_library_controller_test ("binding unverified").
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/dto/library_tools_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

import '../../helpers/fake_library_tools_api.dart';
import 'fake_manage_library_controls.dart';
import '../../helpers/test_offline.dart';

/// Counts the page's waits for verification; the test ends each one.
class _CountedWaits extends FakeLibraryToolsApi {
  final waits = <Completer<void>>[];

  @override
  Future<void> whenVerified() {
    final w = Completer<void>();
    waits.add(w);
    return w.future;
  }

  /// The binding verifies: fail-fast reads pass, and every wait ends.
  void verify() {
    bindingVerified = true;
    for (final w in waits) {
      if (!w.isCompleted) w.complete();
    }
  }
}

/// Only the manager's job map (no job here).
class _NoJobs implements DeleteJobsManager {
  @override
  final ValueListenable<Map<String, DeleteJob>> jobs = ValueNotifier(const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeletionJobSummaryDto _receipt(String op) => DeletionJobSummaryDto.fromJson({
  'operation_uuid': op,
  'created_at': 100,
  'status': 'succeeded',
  'item_count': 1,
  'state_counts': {'deleted': 1},
});

void main() {
  late _CountedWaits api;
  late TestOffline offline;
  late ProviderContainer c;
  late ManageLibraryControls m;

  setUp(() {
    api = _CountedWaits()
      ..onListJobs = (after, limit) async =>
          DeletionJobPageDto(jobs: [_receipt('r1')], nextAfter: null);
  });

  tearDown(() {
    m.dispose();
    c.dispose();
  });

  Future<void> open({bool verified = false}) async {
    api.bindingVerified = verified;
    offline = TestOffline(false);
    c = ProviderContainer(
      overrides: [
        libraryToolsApiProvider.overrideWithValue(api),
        deleteJobsManagerProvider.overrideWithValue(_NoJobs()),
        offlineModeProvider.overrideWith(() => offline),
        deletionReviewControllerFactoryProvider.overrideWithValue(
          (TrackSelectionControls _) => FakeDeletionReviewControls(),
        ),
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
    c.listen(offlineModeProvider, (_, _) {});
    m = c.read(manageLibraryControllerFactoryProvider)();
    await m.loadReceipts();
    await pumpEventQueue();
  }

  test('a refused read waits once, Retry adds no wait; once verified the '
      'request is repeated once', () async {
    await open();
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    await m.retryReceipts();
    await pumpEventQueue();
    expect(api.waits, hasLength(1));
    expect(api.callsOf('listJobs'), isEmpty);

    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('listJobs'), ['listJobs null']);
    expect(m.receiptsLoad, ReceiptsLoad.loaded);
    expect(m.receipts.map((r) => r.operationUuid), ['r1']);
  });

  test('the page no longer needs a connection when the binding verifies: '
      'nothing is read again', () async {
    await open();
    // The binding verified and Retry loaded before the wait ended.
    api.bindingVerified = true;
    await m.retryReceipts();
    await pumpEventQueue();
    expect(m.receiptsLoad, ReceiptsLoad.loaded);
    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('listJobs'), ['listJobs null']);
  });

  test('offline when the binding verifies: the repeat asks nothing', () async {
    await open();
    offline.set(true);
    await pumpEventQueue();
    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('listJobs'), isEmpty);
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
  });

  test('a page left before the binding verifies asks nothing', () async {
    await open();
    m.dispose();
    api.verify();
    await pumpEventQueue();
    expect(api.calls, isEmpty);
    // tearDown disposes again: a second dispose is a no-op.
  });

  test('a wait that ends in an error (the gate closed) reloads nothing; the '
      'next refused read waits again', () async {
    await open();
    api.waits.single.completeError(StateError('gate closed'));
    await pumpEventQueue();
    expect(api.calls, isEmpty);

    await m.retryReceipts();
    await pumpEventQueue();
    expect(api.waits, hasLength(2));
    api.verify();
    await pumpEventQueue();
    expect(api.callsOf('listJobs'), ['listJobs null']);
  });
}
