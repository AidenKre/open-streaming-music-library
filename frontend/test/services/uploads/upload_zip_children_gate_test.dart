// Other-issues row 72 (U31-B-10), as decided on 2026-11-18: "Files in this
// archive", and the review page's read of a batch, must not wait for the
// server check without a limit. Each behaves like a person's own action:
//  * a check in flight (returning to the app re-checks the server) is waited
//    for, within the gate's one bound, and the list loads when it passes;
//  * a different server, no session, signed out, or offline while the
//    server is still verified: the read fails at once, with the reason, and
//    sends nothing;
//  * a check that does not pass within the bound (also: offline after a
//    re-check has failed): the read fails at the bound
//    (upload_page_reads_bound_test, fake time).
// The page then shows its failure view instead of a spinner. Every other
// caller of `listItems` waits without a limit as before (uploads_api_test,
// "listItems sends nothing while the gate is unverified, then goes").
//
// The real API over a real gate and the real token client; an in-memory
// transport.
import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/api/token_permit.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/uploads/upload_duplicate_decisions.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review.dart';
import 'package:frontend/services/uploads/upload_zip_children.dart';
import 'package:http/http.dart' as http;

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/server_binding.dart';
import '../../helpers/stamped_server.dart';
import '../../helpers/test_credentials.dart';
import '../../helpers/upload_manager_harness.dart';

const _batch = '22222222-2222-4222-8222-222222222222';

/// Records what reaches the wire; answers one page: the archive and one of
/// its files.
class _Wire extends http.BaseClient {
  final requests = <http.BaseRequest>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({
        'items': [
          {...itemJson('zip', batchUuid: _batch, state: 'expanded')},
          {
            ...itemJson('c1', batchUuid: _batch, state: 'review_ready'),
            'parent_item_uuid': 'zip',
          },
        ],
        'next_after': null,
      }))),
      200,
      headers: {
        'content-type': 'application/json',
        'x-server-instance-id': boundInstance,
      },
    );
  }
}

/// The gate's answer, refused on demand after the gate's own check (a
/// verification lost between the check and the send).
class _Permit implements TokenPermit {
  _Permit(this.gate);
  final ServerBindingGate gate;
  bool refuse = false;
  @override
  bool allowsTokenTo(Uri url) => !refuse && gate.allowsTokenTo(url);
  @override
  Future<void> verdictSettled() => gate.verdictSettled();
}

/// The review model's duplicate decisions; the snapshot never asks them.
class _NoDecisions extends Fake implements UploadDuplicateDecisions {}

void main() {
  late AppDatabase db;
  late ServerBindingGate gate;
  late List<Completer<ServerIdentity>> probes;
  late _Permit permit;
  late _Wire wire;
  late UploadsApi api;
  late UploadZipChildren children;
  late bool offline;

  Future<void> answerProbe(String instance) async {
    probes.removeAt(0).complete(ServerIdentity(instance));
    await pumpEventQueue();
  }

  Future<void> verify() async {
    unawaited(gate.startConnection('http://s'));
    await pumpEventQueue();
    await answerProbe(boundInstance);
    expect(gate.state, isA<BindingVerified>());
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db, baseUrl: 'http://s', instanceId: boundInstance);
    offline = false;
    probes = [];
    gate = ServerBindingGate(
      repository: ServerBindingRepository(db),
      signedInUserId: testUserId,
      probe: ({required String baseUrl, required bool reportOffline}) {
        final c = Completer<ServerIdentity>();
        probes.add(c);
        return c.future;
      },
      backoff: BackoffSchedule(jitter: 0),
      timer: (d, f) => Timer(const Duration(days: 1), f),
      isOffline: () => offline,
    );
    permit = _Permit(gate);
    wire = _Wire();
    final client = testApiClient(
      'http://s',
      AuthenticatedClient(wire, testCredentials, permit: permit),
    );
    api = UploadsApi(
      api: client.withInstanceCheck(ServerBindingRepository(db).checkServedBy),
      gate: gate,
    );
    children = UploadZipChildren(api);
  });

  tearDown(() async {
    gate.dispose();
    await db.close();
  });

  /// How a load ended, without waiting for it.
  ({bool Function() done, Object? Function() error}) load() {
    var done = false;
    Object? error;
    unawaited(children.load(_batch, 'zip').then<void>(
      (_) => done = true,
      onError: (Object e) {
        error = e;
        done = true;
      },
    ));
    return (done: () => done, error: () => error);
  }

  Matcher refused(BindingRefusal why) =>
      isA<BindingNotVerified>().having((e) => e.reason, 'reason', why);

  test('a server check in flight that passes: the list waits for it, then '
      'loads; no error', () async {
    unawaited(gate.startConnection('http://s'));
    await pumpEventQueue();
    expect(gate.state, isA<BindingVerifying>());

    final result = load();
    await pumpEventQueue();
    expect(result.done(), isFalse, reason: 'it waits for the check');
    expect(wire.requests, isEmpty, reason: 'nothing is sent meanwhile');

    await answerProbe(boundInstance);
    expect(gate.state, isA<BindingVerified>());
    expect(result.done(), isTrue);
    expect(result.error(), isNull);
    expect(wire.requests, hasLength(1));
  });

  test('a failed check: the list keeps waiting, and loads when a later '
      'check passes', () async {
    unawaited(gate.startConnection('http://s'));
    await pumpEventQueue();
    probes.removeAt(0).completeError(StateError('probe failed'));
    await pumpEventQueue();
    expect(gate.state, isA<BindingUnverified>());

    final result = load();
    await pumpEventQueue();
    expect(result.done(), isFalse, reason: 'a retry may still pass');
    expect(wire.requests, isEmpty);

    unawaited(gate.startConnection('http://s')); // a new check
    await pumpEventQueue();
    await answerProbe(boundInstance);
    expect(result.error(), isNull);
    expect(wire.requests, hasLength(1));
  });

  test('a check in flight that ends at a different server: the list fails '
      'the moment the verdict lands, nothing sent', () async {
    unawaited(gate.startConnection('http://s'));
    await pumpEventQueue();
    final result = load();
    await pumpEventQueue();
    expect(result.done(), isFalse);

    await answerProbe(otherInstance);
    expect(gate.state, isA<BindingDifferentServer>());
    expect(result.error(), refused(BindingRefusal.differentServer));
    expect(wire.requests, isEmpty);
  });

  test('offline (the server was verified): fails at once, nothing sent',
      () async {
    await verify();
    offline = true;

    final result = load();
    await pumpEventQueue();
    expect(result.error(), refused(BindingRefusal.notYet));
    expect(wire.requests, isEmpty);
  });

  test('a different server answers: fails at once and says so, nothing sent',
      () async {
    unawaited(gate.startConnection('http://s'));
    await pumpEventQueue();
    await answerProbe(otherInstance);
    expect(gate.state, isA<BindingDifferentServer>());

    final result = load();
    await pumpEventQueue();
    expect(result.error(), refused(BindingRefusal.differentServer));
    expect(wire.requests, isEmpty);
  });

  test('signed out: fails at once and says so, nothing sent', () async {
    await verify();
    gate.closeSignedOut();

    final result = load();
    await pumpEventQueue();
    expect(result.error(), refused(BindingRefusal.noSession));
    expect(wire.requests, isEmpty);
  });

  test('no session for this binding: fails at once and says so, nothing '
      'sent', () async {
    final noSession = ServerBindingGate(
      repository: ServerBindingRepository(db),
      signedInUserId: null,
      probe: ({required String baseUrl, required bool reportOffline}) async =>
          const ServerIdentity(boundInstance),
      backoff: BackoffSchedule(jitter: 0),
      timer: (d, f) => Timer(const Duration(days: 1), f),
    );
    addTearDown(noSession.dispose);
    await noSession.startConnection('http://s');
    expect(noSession.state, isA<BindingNoSession>());
    final client = testApiClient(
      'http://s',
      AuthenticatedClient(wire, testCredentials, permit: noSession),
    );

    await expectLater(
      UploadZipChildren(UploadsApi(api: client, gate: noSession))
          .load(_batch, 'zip'),
      throwsA(refused(BindingRefusal.noSession)),
    );
    expect(wire.requests, isEmpty);
  });

  // The calls that wait keep the token client's own error: the upload
  // manager reads it as "nothing was sent, leave the rows as they were".
  // Only the read that does not wait turns it into "not verified".
  test('a call that waits keeps the raw withheld-token error (verified but '
      'offline), nothing sent', () async {
    await verify();
    offline = true;

    await expectLater(
      api.getItem('c1'),
      throwsA(isA<TokenWithheldException>()),
    );
    await expectLater(
      api.listItems(_batch),
      throwsA(isA<TokenWithheldException>()),
    );
    expect(wire.requests, isEmpty);
  });

  test('the bounded read asked directly (the review page\'s form), offline: '
      'fails at once, nothing sent', () async {
    await verify();
    offline = true;

    await expectLater(
      api.listItems(_batch, wait: BindingWait.forPendingVerdict),
      throwsA(refused(BindingRefusal.notYet)),
    );
    expect(wire.requests, isEmpty);
  });

  test('the token withheld at the send (the check was lost in between) '
      'reads as not verified, nothing sent', () async {
    await verify();
    permit.refuse = true;

    final result = load();
    await pumpEventQueue();
    expect(result.error(), refused(BindingRefusal.notYet));
    expect(wire.requests, isEmpty);
  });

  test('control: verified and online, the pages are read with the token',
      () async {
    await verify();

    final zip = await children.load(_batch, 'zip');
    expect([for (final c in zip.children) c.itemUuid], ['c1']);
    expect(wire.requests, hasLength(1));
    expect(wire.requests.single.url.path, '/tracks/uploads/$_batch/items');
    expect(wire.requests.single.headers['Authorization'],
        'Bearer ${testCredentials.token}');
  });

  group("the review page's read of a batch", () {
    late UploadHarness h;
    late _Wire reviewWire;
    late UploadReview review;

    setUp(() async {
      h = await UploadHarness.create();
      reviewWire = _Wire();
      review = UploadReview(
        api: UploadsApi(
          api: testApiClient('http://test', reviewWire),
          gate: h.gate.gate,
        ),
        intents: h.store,
        binding: h.binding,
        manager: h.manager,
        decisions: _NoDecisions(),
      );
    });
    tearDown(() => h.dispose());

    ({bool Function() done, Object? Function() error}) snapshot() {
      var done = false;
      Object? error;
      unawaited(review.snapshot(_batch).then<void>(
        (_) => done = true,
        onError: (Object e) {
          error = e;
          done = true;
        },
      ));
      return (done: () => done, error: () => error);
    }

    test('a server check in flight that passes: it waits, then loads',
        () async {
      await h.verify();
      unawaited(h.gate.gate.startConnection('http://test')); // a resume
      await pumpEventQueue();

      final result = snapshot();
      await pumpEventQueue();
      expect(result.done(), isFalse, reason: 'it waits for the check');
      expect(reviewWire.requests, isEmpty);

      h.gate.respond(h.instanceId);
      await pumpEventQueue();
      expect(result.done(), isTrue);
      expect(result.error(), isNull);
      expect(reviewWire.requests, hasLength(1));
    });

    test('a different server answers: fails at once and says so, nothing '
        'sent', () async {
      await h.verify();
      unawaited(h.gate.gate.startConnection('http://test'));
      await pumpEventQueue();
      h.gate.respond(otherInstance);
      await pumpEventQueue();
      expect(h.gate.gate.state, isA<BindingDifferentServer>());

      final result = snapshot();
      await pumpEventQueue();
      expect(result.done(), isTrue, reason: 'no wait: no verdict is coming');
      expect(result.error(), refused(BindingRefusal.differentServer));
      expect(reviewWire.requests, isEmpty);
    });

    test('signed out: fails at once and says so, nothing sent', () async {
      await h.verify();
      h.gate.gate.closeSignedOut();

      final result = snapshot();
      await pumpEventQueue();
      expect(result.error(), refused(BindingRefusal.noSession));
      expect(reviewWire.requests, isEmpty);
    });
  });

  group('who asks how', () {
    test('the archive list asks for every page as a person\'s own action',
        () async {
      final api = FakeUploadsApi();
      api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': <Object>[],
        'next_after': after == null ? 'k1' : null,
      });
      await UploadZipChildren(api).load('b-1', 'zip');
      expect(api.listItemsWaits, [
        BindingWait.forPendingVerdict,
        BindingWait.forPendingVerdict,
      ]);
    });

    test("the review page's read asks for every page the same way", () async {
      final h = await UploadHarness.create();
      addTearDown(h.dispose);
      await h.verify();
      h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': <Object>[],
        'next_after': after == null ? 'k1' : null,
      });
      final review = UploadReview(
        api: h.api,
        intents: h.store,
        binding: h.binding,
        manager: h.manager,
        decisions: _NoDecisions(),
      );
      await review.snapshot('b-1');

      expect(h.api.calls.where((c) => c == 'listItems b-1'), hasLength(2));
      expect(h.api.listItemsWaits, [
        BindingWait.forPendingVerdict,
        BindingWait.forPendingVerdict,
      ]);
    });

    test("the upload manager's own reads of the item pages still wait "
        'without a limit', () async {
      final visible = ValueNotifier(false);
      final h = await UploadHarness.create(visible: visible);
      addTearDown(h.dispose);
      h.api.onListBatches = (after) async => UploadBatchPage.fromJson({
        'batches': [batchJson('b-9')],
        'next_after': null,
      });
      await h.verify();
      visible.value = true;
      await h.pump();

      expect(h.api.calls, contains('listItems b-9'));
      expect(h.api.listItemsWaits, everyElement(BindingWait.untilVerified));
    });

    test("the upload manager's status poll still waits without a limit",
        () async {
      final visible = ValueNotifier(false);
      final h = await UploadHarness.create(visible: visible);
      addTearDown(h.dispose);
      h.feature = const AdvertisedFeature(
        UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
        fromCache: false,
      );
      await h.verify();
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      h.api.openPuts.single.complete(state: 'validating', batchUuid: 'u-1');
      await h.pump();
      h.api.onListItems = (batch, after) async => UploadItemPage.fromJson({
        'items': [itemJson('u-2', batchUuid: batch, state: 'validating')],
        'next_after': null,
      });
      visible.value = true;
      await h.pump();
      h.timers.fire(UploadManager.pollInterval);
      await h.pump();

      expect(h.api.calls, contains('listItems u-1'));
      expect(h.api.listItemsWaits, everyElement(BindingWait.untilVerified));
    });
  });
}
