// 7B.1d S6: how a content PUT's answer settles the intent (7A.2b's table of
// PUT answers; SC-13; SC-14; DEV-7-02 / O13; DEV-7-09).
// - 503 `upload_slots_busy` (retryable, retry_after_s): the file waits for
//   the server ("Waiting for the server", never an error) and is not sent
//   again before the server's retry_after, paced by a BackoffSchedule.
// - Other retryable answers: back to `allocated` with the code, paced, then
//   sent again under the same operation id after the status GET.
// - A lost answer: the status is asked first; a file the server completed
//   is never sent again; one it never finished is sent under the same id.
// - A 401 waits (row not failed, nothing more sent in this scope).
// - Another server's answer: rows as they were before the send, nothing
//   more sent.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';

import '../../helpers/fake_uploads_api.dart';
import '../../helpers/upload_manager_harness.dart';

void main() {
  late UploadHarness h;

  setUp(() async {
    h = await UploadHarness.create();
    h.feature = const AdvertisedFeature(
      UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 1)),
      fromCache: false,
    );
    await h.verify();
  });
  tearDown(() => h.dispose());

  Future<void> addOne() async {
    await h.manager.addFiles([await h.file('a.flac', 'abc')]);
    await h.pump();
  }

  Future<Map<String, Object?>> intent() async => (await h.intents()).single;

  Future<Map<String, Object?>> contentSubmission() async =>
      (await h.submissions()).firstWhere((s) => s['kind'] == 'upload_content');

  int puts() => h.api.puts.length;

  test('busy: the file waits for the server, is not sent again before '
      'retry_after, then goes out under the same operation id', () async {
    await addOne();
    final op = (await intent())['transfer_operation_uuid'];
    h.api.openPuts.single.fail(
      apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 5),
    );
    await h.pump();

    final row = await intent();
    expect(row['last_state'], 'allocated');
    expect(row['last_error_code'], 'upload_slots_busy');
    expect((await contentSubmission())['state'], 'ambiguous');
    expect(puts(), 1);

    // Any request before the wait is over sends nothing.
    h.manager.start();
    await h.pump();
    expect(puts(), 1);
    final waits = [for (final t in h.timers.active) t.duration];
    expect(waits, isNotEmpty);
    expect(waits.every((d) => d >= const Duration(seconds: 5)), isTrue);

    h.clock.advance(const Duration(seconds: 5));
    h.timers.fire();
    await h.pump();

    expect(puts(), 2);
    expect((await intent())['transfer_operation_uuid'], op);
    expect(h.api.calls.where((c) => c == 'getItem u-2').length,
        greaterThanOrEqualTo(2));
  });

  test('a busy answer repeated waits at least retry_after every time',
      () async {
    await addOne();
    for (var round = 0; round < 3; round++) {
      h.api.openPuts.single.fail(
        apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 5),
      );
      await h.pump();
      final waits = [for (final t in h.timers.active) t.duration];
      expect(waits.every((d) => d >= const Duration(seconds: 5)), isTrue,
          reason: 'round $round: $waits');
      h.clock.advance(waits.reduce((a, b) => a > b ? a : b));
      h.timers.fire();
      await h.pump();
    }
    expect(puts(), 4);
  });

  test('a retryable refusal (507) is retried after a backoff under the same '
      'operation id', () async {
    await addOne();
    final op = (await intent())['transfer_operation_uuid'];
    h.api.openPuts.single.fail(
      apiError(507, 'insufficient_storage', retryable: true),
    );
    await h.pump();
    expect((await intent())['last_state'], 'allocated');
    expect((await intent())['last_error_code'], 'insufficient_storage');
    expect(puts(), 1);

    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();
    expect(puts(), 2);
    expect((await intent())['transfer_operation_uuid'], op);
  });

  test('a lost answer for a file the server completed: the status GET '
      'settles it and the file is not sent again', () async {
    await addOne();
    h.api.openPuts.single.fail(NetworkException('lost', attemptsMade: 1));
    await h.pump();
    expect((await contentSubmission())['state'], 'ambiguous');

    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'validating'));
    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();

    expect(puts(), 1);
    expect((await intent())['last_state'], 'validating');
    expect((await contentSubmission())['state'], 'accepted');
  });

  test('a lost answer for a file the server never finished: sent again '
      'under the same operation id after the status GET', () async {
    await addOne();
    final op = (await intent())['transfer_operation_uuid'];
    h.api.openPuts.single.fail(NetworkException('lost', attemptsMade: 1));
    await h.pump();

    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();

    expect(puts(), 2);
    expect((await intent())['transfer_operation_uuid'], op);
    final calls = h.api.calls;
    final second = calls.lastIndexOf('putContent u-2');
    expect(calls.sublist(calls.indexOf('putContent u-2') + 1, second),
        contains('getItem u-2'));
  });

  test('another transfer of the item still running on the server (409, '
      'retryable): nothing is sent while it is receiving', () async {
    await addOne();
    h.api.onGetItem = (item) async =>
        UploadItem.fromJson(itemJson(item, state: 'receiving'));
    h.api.openPuts.single.fail(
      apiError(409, 'upload_transfer_in_progress', retryable: true),
    );
    await h.pump();
    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();
    expect(puts(), 1);

    h.api.onGetItem = (item) async => UploadItem.fromJson(itemJson(item));
    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    await h.pump();
    expect(puts(), 2);
  });

  test('a 401 is a wait: the row is not failed and nothing more is sent',
      () async {
    await addOne();
    h.api.openPuts.single.fail(
      apiError(401, 'auth_required', retryable: false),
    );
    await h.pump();

    final row = await intent();
    expect(row['last_state'], isNot(anyOf('failed', 'rejected')));
    expect(row['last_error_code'], isNull);
    h.clock.advance(const Duration(hours: 1));
    h.timers.fire();
    h.manager.start();
    await h.pump();
    expect(puts(), 1);
  });

  test('an answer from another server leaves both rows as they were before '
      'the send, and nothing more is sent', () async {
    await addOne();
    final intentBefore = await intent();
    final opBefore = await contentSubmission();
    expect(opBefore['state'], 'sent');
    final e = ServerInstanceChangedException(
      boundInstanceId: 'inst-1',
      servedBy: 'inst-2',
    );
    h.gate.gate.reportDifferentInstance(h.gate.gate.verifiedConnection!, e);
    h.clock.advance(const Duration(seconds: 3));
    h.api.openPuts.single.fail(e);
    await h.pump();

    expect(await intent(), intentBefore);
    final after = await contentSubmission();
    // The row as it was before the send (prepared, not 'sent').
    expect(after['state'], 'prepared');
    h.clock.advance(const Duration(hours: 1));
    h.timers.fire();
    await h.pump();
    expect(puts(), 1);
  });

  // U31-B-01 (U31-FE-UPL-MGR-B-01): an error none of the answers above
  // explains (here the status GET's item cannot be read) ends the detached
  // transfer with an exception. The next attempt waits for the transfer
  // backoff like any other failed send; it never starts again at once.
  test('U31-B-01 an unexpected transfer error waits for the backoff before '
      'the next attempt', () async {
    await addOne();
    h.api.openPuts.single.fail(NetworkException('lost', attemptsMade: 1));
    await h.pump();
    // The first five reads fail (then the item reads as allocated), so an
    // unpaced loop ends instead of hanging the test.
    var bad = 5;
    // The first send read the status once before the override.
    final before = h.api.calls.where((c) => c == 'getItem u-2').length;
    h.api.onGetItem = (item) async {
      if (bad-- > 0) throw const FormatException('bad item');
      return UploadItem.fromJson(itemJson(item));
    };
    h.clock.advance(const Duration(minutes: 1));
    h.timers.fire();
    // Bounded turns of the event queue (no idle(): an unpaced loop never
    // goes idle).
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    int gets() =>
        h.api.calls.where((c) => c == 'getItem u-2').length - before;
    expect(gets(), 1);
    expect(puts(), 1);
    final waits = [for (final t in h.timers.active) t.duration];
    expect(waits, isNotEmpty);
    expect(waits.every((d) => d > Duration.zero), isTrue, reason: '$waits');

    // Once the wait is over: one more attempt, and again a wait after it.
    h.clock.advance(waits.reduce((a, b) => a > b ? a : b));
    h.timers.fire();
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(gets(), 2);
    expect([for (final t in h.timers.active) t.duration], isNotEmpty);
  });

  test('a success resets the transfer backoff', () async {
    await h.manager.addFiles([
      await h.file('a.flac', 'abc'),
      await h.file('b.flac', 'abcd'),
    ]);
    await h.pump();
    h.api.openPuts.single.fail(
      apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 1),
    );
    await h.pump();
    h.clock.advance(const Duration(seconds: 1));
    h.timers.fire();
    await h.pump();
    h.api.openPuts.single.complete();
    await h.pump();
    // The next file starts at once: no wait left from the busy answer.
    expect([for (final p in h.api.openPuts) p.itemUuid], ['u-3']);
  });
}
