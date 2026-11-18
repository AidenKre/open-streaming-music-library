// 7B.1d S4: the upload runner's pass and the allocation (spec §7 para 2;
// SC-13, SC-14; plan §6 OPEN-M-11). A pass waits for the verified gate
// before building any request, never acts on an absent or cached uploads
// block or while offline, and sends each batch's frozen allocation through
// DurableSubmission: accepted → the batch's intents are `allocated`;
// rejected → `rejected` with the code; a lost answer → the batch status is
// asked first and the same frozen body is sent again only when the server
// never saw it. A 401 is a wait (rows untouched, runner parked, SC-13
// Phase M note); an answer from another server leaves the rows exactly as
// they were and nothing more is sent (DEV-7-09).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

/// After an allocation, a later step may already have started a transfer.
const _allocatedOrLater = {'allocated', 'transferring'};

List<String> _allocations(FakeUploadsApi api) => [
  for (final c in api.calls)
    if (c.startsWith('allocate') || c.startsWith('getBatch')) c,
];

void main() {
  late UploadHarness h;

  setUp(() async => h = await UploadHarness.create());
  tearDown(() => h.dispose());

  test('nothing is built or sent before the gate verifies; then the batch '
      'is allocated once and its intents leave `allocating`', () async {
    final a = await h.file('a.flac', 'abc');
    final b = await h.file('b.flac', 'abcd');
    await h.manager.addFiles([a, b]);
    await h.pump();
    expect(h.api.calls, isEmpty);

    await h.verify();

    expect(_allocations(h.api), ['allocate u-1']);
    expect(h.api.callsBeforeVerified, 0);
    final states = await h.states();
    expect(states.keys, ['u-2', 'u-3']);
    expect(states.values, everyElement(isIn(_allocatedOrLater)));
    final sub = (await h.submissions()).firstWhere(
      (s) => s['operation_uuid'] == 'u-1',
    );
    expect(sub['kind'], 'upload_allocation');
    expect(sub['state'], 'accepted');
  });

  test('a definitive refusal marks the batch rejected with its code and is '
      'never sent again', () async {
    h.api.onAllocate = (_) async =>
        throw apiError(413, 'upload_limit_exceeded', retryable: false);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    final rows = await h.intents();
    expect(rows.single['last_state'], UploadIntentState.rejected);
    expect(rows.single['last_error_code'], 'upload_limit_exceeded');
    expect((await h.submissions()).single['state'], 'rejected');

    h.timers.fire();
    h.manager.start();
    await h.pump();
    expect(_allocations(h.api), ['allocate u-1']);
  });

  test('a lost answer: the intents stay allocating; the next pass asks for '
      'the batch first and resends the same body only when the server '
      'never saw it', () async {
    var first = true;
    final defaultAllocate = h.api.onAllocate;
    h.api.onAllocate = (body) async {
      if (first) {
        first = false;
        throw NetworkException('lost', attemptsMade: 1);
      }
      return defaultAllocate(body);
    };
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect((await h.intents()).single['last_state'], 'allocating');
    expect((await h.submissions()).single['state'], 'ambiguous');

    h.timers.fire(); // the runner's backoff retry
    await h.pump();

    expect(_allocations(h.api), [
      'allocate u-1',
      'getBatch u-1',
      'allocate u-1',
    ]);
    expect(h.api.allocations[1], h.api.allocations[0]);
    expect((await h.intents()).single['last_state'], isIn(_allocatedOrLater));
  });

  test('a lost answer the server did receive: resolved by the batch status, '
      'never allocated twice', () async {
    h.api.onAllocate = (_) async =>
        throw NetworkException('lost', attemptsMade: 1);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    h.api.onGetBatch = (batch) async => UploadBatch.fromJson(batchJson(batch));
    h.timers.fire();
    await h.pump();

    expect(_allocations(h.api), ['allocate u-1', 'getBatch u-1']);
    expect(
      (await h.submissions())
          .singleWhere((s) => s['kind'] == 'upload_allocation')['state'],
      'accepted',
    );
    expect((await h.intents()).single['last_state'], isIn(_allocatedOrLater));
  });

  test('a 401 is a wait: rows are not failed, nothing is retried, later work '
      'sends nothing in this scope', () async {
    h.api.onAllocate = (_) async =>
        throw apiError(401, 'auth_required', retryable: false);
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    final row = (await h.intents()).single;
    expect(row['last_state'], 'allocating');
    expect(row['last_error_code'], isNull);
    expect((await h.submissions()).single['state'], 'ambiguous');

    h.timers.fire();
    await h.manager.addFiles([await h.file('b.flac', 'abcd')]);
    h.manager.start();
    await h.pump();
    expect(_allocations(h.api), ['allocate u-1']);
  });

  // Sign-off OPEN-M-11 (E8): a withheld token means nothing was sent: the
  // rows stay as they were (not "ambiguous"), and the next pass allocates
  // with no status query first.
  test('the token withheld on the allocation: nothing was sent, the rows '
      'stay as they were, and the next pass allocates', () async {
    var first = true;
    final defaultAllocate = h.api.onAllocate;
    h.api.onAllocate = (body) async {
      if (first) {
        first = false;
        throw const TokenWithheldException();
      }
      return defaultAllocate(body);
    };
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();

    expect((await h.submissions()).single['state'], isNot('ambiguous'));

    h.timers.fire();
    await h.pump();
    expect(_allocations(h.api), ['allocate u-1', 'allocate u-1'],
        reason: 'no batch status query: nothing had been sent');
    expect((await h.intents()).single['last_state'], isIn(_allocatedOrLater));
  });

  test('an answer from another server leaves the rows exactly as they were '
      'and nothing more is sent', () async {
    h.feature = const AdvertisedFeature(
      UploadsFeature(
        version: 1,
        limits: UploadLimits(maxFilesPerBatch: 1, receivesPerUser: 2),
      ),
      fromCache: false,
    );
    await h.manager.addFiles([
      await h.file('a.flac', 'abc'),
      await h.file('b.flac', 'abcd'),
    ]);
    final intentsBefore = await h.intents();
    final submissionsBefore = await h.submissions();
    h.clock.advance(const Duration(seconds: 30));
    h.api.onAllocate = (_) async {
      // As the real UploadsApi does: report to the gate, then rethrow.
      final e = ServerInstanceChangedException(
        boundInstanceId: 'inst-1',
        servedBy: 'inst-2',
      );
      h.gate.gate.reportDifferentInstance(h.gate.gate.verifiedConnection!, e);
      throw e;
    };

    await h.verify();
    h.timers.fire();
    await h.pump();

    expect(_allocations(h.api), hasLength(1));
    expect(await h.intents(), intentsBefore);
    expect(await h.submissions(), submissionsBefore);
  });

  test('an absent or cached uploads block starts no request; a live one '
      'does', () async {
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    h.feature = null;
    await h.verify();
    await h.pump();
    expect(h.api.calls, isEmpty);

    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 2)),
      fromCache: true,
    );
    h.timers.fire();
    await h.pump();
    expect(h.api.calls, isEmpty);

    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 2)),
      fromCache: false,
    );
    h.timers.fire();
    await h.pump();
    expect(_allocations(h.api), ['allocate u-1']);
  });

  test('offline sends nothing; back online the pass allocates', () async {
    h.offline = true;
    await h.verify();
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
    expect(h.api.calls, isEmpty);

    h.offline = false;
    h.timers.fire();
    await h.pump();
    expect(_allocations(h.api), ['allocate u-1']);
  });

  test('intents written but the allocation never prepared (killed in '
      'between): the pass freezes the same body from the intents and sends '
      'it', () async {
    final store = UploadIntentStore(
      db: h.db,
      binding: h.binding,
      clock: h.clock,
    );
    await store.insertAll(h.token, [
      for (final (i, (name, len, sha)) in [
        ('a.flac', 3, 'aa' * 32),
        ('b.flac', 4, 'bb' * 32),
      ].indexed)
        NewUploadIntent(
          itemUuid: 'i-$i',
          batchUuid: 'b-9',
          selectionIndex: i,
          displayName: name,
          descriptor: UploadSourceDescriptor(
            path: '${h.dir.path}/$name',
            length: len,
            sha256: sha,
          ),
        ),
    ], state: UploadIntentState.allocating);

    await h.verify();
    h.manager.start();
    await h.pump();

    expect(h.api.allocations, [
      '{"batch_uuid":"b-9","items":['
          '{"item_uuid":"i-0","filename":"a.flac","byte_length":3,'
          '"sha256":"${'aa' * 32}"},'
          '{"item_uuid":"i-1","filename":"b.flac","byte_length":4,'
          '"sha256":"${'bb' * 32}"}]}',
    ]);
    expect((await h.submissions()).single['state'], 'accepted');
  });
}
