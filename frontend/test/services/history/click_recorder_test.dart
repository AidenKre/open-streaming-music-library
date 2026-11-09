import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/models/history_intent.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/history/click_recorder.dart';

import '../../helpers/fake_clock.dart';

class _Binding extends ServerBindingRepository {
  _Binding(super.db);
  String token = 'b1';
  @override
  Future<ServerBindingRecord?> current() async => ServerBindingRecord(
        instanceId: null,
        localBindingId: token,
        lastBaseUrl: 'http://x',
        boundAtMs: 0,
        catalogReconciled: false,
      );
}

class _GatedHistory extends HistoryRepository {
  _GatedHistory(super.db);
  final inserted = <(String, String)>[];
  Completer<void>? gate;
  final fencedTokens = <String>{};
  int failures = 0;
  @override
  Future<void> insertLocal(String bindingToken, HistoryEventPayload event) async {
    final g = gate;
    if (g != null) {
      gate = null;
      await g.future;
    }
    if (fencedTokens.contains(bindingToken)) {
      throw BindingFencedException(bindingToken);
    }
    if (failures > 0) {
      failures--;
      throw StateError('disk full');
    }
    inserted.add((bindingToken, event.entityRef));
  }
}

void main() {
  test('a click under a new binding during a flush is not lost', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final binding = _Binding(db);
    final history = _GatedHistory(db);
    final recorder =
        ClickRecorder(history: history, binding: binding, clock: FakeClock());
    final gate = history.gate = Completer<void>();
    final first = recorder.record(const HistoryIntent.track('a'));
    await pumpEventQueue();
    binding.token = 'b2'; // a reset bound another server meanwhile
    final second = recorder.record(const HistoryIntent.track('b'));
    await pumpEventQueue();
    gate.complete();
    await first;
    await second;
    await pumpEventQueue();
    expect(history.inserted, contains(('b2', 'b')),
        reason: 'the new click is inserted under its own binding');
  });

  test('a fenced binding drops only its own clicks', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final binding = _Binding(db);
    final history = _GatedHistory(db);
    final recorder =
        ClickRecorder(history: history, binding: binding, clock: FakeClock());
    history.failures = 1;
    await recorder.record(const HistoryIntent.track('a')); // b1, kept
    binding.token = 'b2';
    history.fencedTokens.add('b1'); // b1's store was reset
    await recorder.record(const HistoryIntent.track('b'));
    expect(history.inserted, [('b2', 'b')]);
  });

  test('unsaved clicks are bounded; the oldest are dropped first', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final history = _GatedHistory(db);
    final recorder = ClickRecorder(
        history: history, binding: _Binding(db), clock: FakeClock());
    history.failures = ClickRecorder.maxPending + 5;
    for (var i = 0; i < ClickRecorder.maxPending + 5; i++) {
      await recorder.record(HistoryIntent.track('t$i'));
    }
    history.failures = 0;
    await recorder.record(const HistoryIntent.track('last'));
    final refs = history.inserted.map((e) => e.$2).toList();
    expect(refs, hasLength(ClickRecorder.maxPending));
    expect(refs.first, 't6', reason: 'the six oldest were dropped');
    expect(refs.last, 'last');
  });
}
