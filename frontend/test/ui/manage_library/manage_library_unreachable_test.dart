// Refactor APP-DUP (section 6 #11; the owner, 2026-11-17): while Deletion
// history cannot read from the server it says the real reason. A different
// server or a 401 sign-out turns the app offline (the session's block); a
// read refused while online carries its own reason. Plain offline, or a
// connection not verified yet, still "needs a connection".
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/library_tools_api.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/delete_jobs_wiring.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/library_tools_pages.dart';
import 'package:frontend/ui/manage_library/deletion_review_controller.dart';
import 'package:frontend/ui/manage_library/manage_library_controller.dart';
import 'package:frontend/ui/selection/track_selection_controller.dart';

import '../../helpers/fake_library_tools_api.dart';
import 'fake_manage_library_controls.dart';
import '../../helpers/test_offline.dart';

/// Waits for verification never end on their own.
class _HeldWaits extends FakeLibraryToolsApi {
  @override
  Future<void> whenVerified() => Completer<void>().future;
}

/// Only the manager's job map (no job here).
class _NoJobs implements DeleteJobsManager {
  @override
  final ValueListenable<Map<String, DeleteJob>> jobs = ValueNotifier(const {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _needs = 'Deletion history needs a connection.';
const _different =
    'Deletion history is not available: a different server answers at this '
    'address.';
const _signedOut = 'Deletion history is not available: you are signed out.';

void main() {
  late _HeldWaits api;
  late ValueNotifier<ServerBlockedReason> blocked;
  late ProviderContainer c;
  late ManageLibraryControls m;
  late TestOffline offlineNotifier;

  setUp(() {
    api = _HeldWaits();
    blocked = ValueNotifier(ServerBlockedReason.none);
  });

  tearDown(() {
    m.dispose();
    c.dispose();
  });

  Future<void> open({bool offline = false}) async {
    c = ProviderContainer(
      overrides: [
        libraryToolsApiProvider.overrideWithValue(api),
        deleteJobsManagerProvider.overrideWithValue(_NoJobs()),
        offlineModeProvider.overrideWith(
          () => offlineNotifier = TestOffline(offline),
        ),
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
        libraryToolsServerBlockedProvider.overrideWith((ref) {
          void changed() => ref.invalidateSelf();
          blocked.addListener(changed);
          ref.onDispose(() => blocked.removeListener(changed));
          return blocked.value;
        }),
      ],
    );
    c.listen(offlineModeProvider, (_, _) {});
    m = c.read(manageLibraryControllerFactoryProvider)();
    await m.loadReceipts();
    await pumpEventQueue();
  }

  void refuseWith(BindingRefusal reason) =>
      api.onListJobs = (_, _) => throw BindingNotVerified(reason);

  test('plain offline: needs a connection', () async {
    await open(offline: true);
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    expect(m.receiptsUnreachableText, _needs);
  });

  test('offline because a different server answers: says so', () async {
    blocked.value = ServerBlockedReason.differentServer;
    await open(offline: true);
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    expect(m.receiptsUnreachableText, _different);
  });

  test('offline because signed out: says so', () async {
    blocked.value = ServerBlockedReason.signedOut;
    await open(offline: true);
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    expect(m.receiptsUnreachableText, _signedOut);
  });

  test('the block arriving while the page shows its notice: the page is '
      'told', () async {
    await open(offline: true);
    var notified = 0;
    m.addListener(() => notified++);
    blocked.value = ServerBlockedReason.signedOut;
    await pumpEventQueue();
    expect(notified, greaterThan(0));
    expect(m.receiptsUnreachableText, _signedOut);
  });

  test('refused, not verified yet: needs a connection', () async {
    refuseWith(BindingRefusal.notYet);
    await open();
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    expect(m.receiptsUnreachableText, _needs);
  });

  test('refused, a different server: says so', () async {
    refuseWith(BindingRefusal.differentServer);
    await open();
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    expect(m.receiptsUnreachableText, _different);
  });

  test('refused, no session: signed out', () async {
    refuseWith(BindingRefusal.noSession);
    await open();
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    expect(m.receiptsUnreachableText, _signedOut);
  });

  test('a refusal\'s reason does not outlive the app going offline, even '
      'before any reload (review B1)', () async {
    refuseWith(BindingRefusal.noSession);
    await open();
    expect(m.receiptsUnreachableText, _signedOut);
    offlineNotifier.set(true);
    await pumpEventQueue();
    expect(m.receiptsLoad, ReceiptsLoad.needsConnection);
    expect(m.receiptsUnreachableText, _needs);
  });

  test('a refusal\'s reason does not outlive a later refusal for another '
      'reason', () async {
    refuseWith(BindingRefusal.differentServer);
    await open();
    refuseWith(BindingRefusal.notYet);
    await m.retryReceipts();
    await pumpEventQueue();
    expect(m.receiptsUnreachableText, _needs);
  });
}
