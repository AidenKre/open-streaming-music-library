// Refactor A.3 slice 3, characterization: the upload manager's and the
// deletion manager's "wait for the server check unless we are closing", and
// what `idle()` means around it (the test harnesses' `pump()` rests on it).
//
//  * While a pass waits for the check, `idle()` completes at once; an
//    `idle()` asked while the pass was still on its way to the check
//    completes the moment the wait begins. Nothing is sent meanwhile.
//  * The wait is over once the check passes: `idle()` then follows the pass
//    again (the upload manager waits for a request's answer).
//  * A later pass that has to wait again behaves the same.
//  * `quiesce()` ends the wait: the pass ends and nothing is sent, not even
//    when the check passes afterwards.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/services/server_binding_gate.dart';

import '../helpers/delete_jobs_harness.dart';
import '../helpers/upload_manager_harness.dart';

/// Whether [future] completed, without waiting for it.
class _Done {
  _Done(Future<void> future) {
    unawaited(future.then<void>((_) => value = true));
  }
  bool value = false;
}

void main() {
  group('upload manager', () {
    late UploadHarness h;
    setUp(() async => h = await UploadHarness.create());
    tearDown(() => h.dispose());

    test('a pass waiting for the server check: idle() completes at once, '
        'nothing is sent', () async {
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await pumpEventQueue();
      final idle = _Done(h.manager.idle());
      await pumpEventQueue();
      expect(idle.value, isTrue);
      expect(h.api.calls, isEmpty);
    });

    test('an idle() asked while the pass is on its way to the check '
        'completes when the wait begins', () async {
      h.manager.start();
      final idle = _Done(h.manager.idle()); // the pass has not begun to wait
      await pumpEventQueue();
      expect(idle.value, isTrue);
      expect(h.api.calls, isEmpty);
    });

    test('once the check passes the wait is over: idle() waits for the '
        'request in flight', () async {
      final answer = Completer<AllocationResult>();
      final defaultAllocate = h.api.onAllocate;
      h.api.onAllocate = (_) => answer.future;
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await pumpEventQueue();

      unawaited(h.gate.gate.startConnection('http://test'));
      await pumpEventQueue();
      h.gate.respond(h.instanceId);
      await pumpEventQueue();
      expect(h.api.calls, ['allocate u-1'], reason: 'the allocation is open');

      final idle = _Done(h.manager.idle());
      await pumpEventQueue();
      expect(idle.value, isFalse, reason: 'no longer waiting for the check');

      h.api.onAllocate = defaultAllocate;
      answer.complete(await defaultAllocate(h.api.allocations.single));
      await h.pump();
      await pumpEventQueue();
      expect(idle.value, isTrue);
    });

    test('a later pass that has to wait again: idle() completes at once '
        'again', () async {
      await h.verify();
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      final sent = h.api.calls.length;
      expect(sent, greaterThan(0));

      // A new connection (an app resume): the check runs again.
      unawaited(h.gate.gate.startConnection('http://test'));
      await pumpEventQueue();
      expect(h.gate.gate.state, isA<BindingVerifying>());
      h.manager.request('again', bypassBackoff: true);
      final idle = _Done(h.manager.idle());
      await pumpEventQueue();
      expect(idle.value, isTrue);
      expect(h.api.calls.length, sent, reason: 'nothing sent while waiting');
    });

    test('quiesce() ends the wait: nothing is sent, not even when the check '
        'passes afterwards', () async {
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await pumpEventQueue();
      await h.manager.quiesce();

      unawaited(h.gate.gate.startConnection('http://test'));
      await pumpEventQueue();
      h.gate.respond(h.instanceId);
      await pumpEventQueue();
      expect(h.gate.gate.state, isA<BindingVerified>());
      expect(h.api.calls, isEmpty);
    });
  });

  group('deletion manager', () {
    late DeleteJobsHarness h;
    setUp(() async => h = await DeleteJobsHarness.create());
    tearDown(() => h.dispose());

    test('a pass waiting for the server check: idle() completes at once, '
        'nothing is sent', () async {
      h.manager.request('start');
      await pumpEventQueue();
      final idle = _Done(h.manager.idle());
      await pumpEventQueue();
      expect(idle.value, isTrue);
      expect(h.api.calls, isEmpty);
    });

    test('an idle() asked while the pass is on its way to the check '
        'completes when the wait begins', () async {
      h.manager.request('start');
      final idle = _Done(h.manager.idle()); // the pass has not begun to wait
      await pumpEventQueue();
      expect(idle.value, isTrue);
      expect(h.api.calls, isEmpty);
    });

    test('once the check passes the wait is over: the pass runs to its end '
        'and idle() follows it', () async {
      h.manager.follow('op-x');
      await pumpEventQueue();
      expect(h.api.calls, isEmpty);

      await h.verify();
      expect(h.api.callsOf('getJob'), ['getJob op-x']);
      final idle = _Done(h.manager.idle());
      await pumpEventQueue();
      expect(idle.value, isTrue);
    });

    test('a later pass that has to wait again: idle() completes at once '
        'again', () async {
      await h.verify();
      h.manager.follow('op-x');
      await h.pump();
      final sent = h.api.calls.length;
      expect(sent, greaterThan(0));

      unawaited(h.gate.gate.startConnection('http://test'));
      await pumpEventQueue();
      expect(h.gate.gate.state, isA<BindingVerifying>());
      h.manager.follow('op-y');
      final idle = _Done(h.manager.idle());
      await pumpEventQueue();
      expect(idle.value, isTrue);
      expect(h.api.calls.length, sent, reason: 'nothing sent while waiting');
    });

    test('quiesce() ends the wait: nothing is sent, not even when the check '
        'passes afterwards', () async {
      h.manager.follow('op-x');
      await pumpEventQueue();
      await h.manager.quiesce();

      unawaited(h.gate.gate.startConnection('http://test'));
      await pumpEventQueue();
      h.gate.respond(h.instanceId);
      await pumpEventQueue();
      expect(h.gate.gate.state, isA<BindingVerified>());
      expect(h.api.calls, isEmpty);
    });
  });
}
