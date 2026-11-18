import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/database/database.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/repositories/history_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

import '../helpers/server_binding.dart';

ListenDraft _draft(String uuid, {int micros = 5000000, int checkpoint = 10}) =>
    ListenDraft(
      listenUuid: uuid,
      queueSessionId: 1,
      queueItemId: 2,
      trackUuid: 't1',
      startedAt: 1800000000000,
      durationSeconds: 200,
      accumulatedMicros: micros,
      lastCheckpointAt: checkpoint,
    );

HistoryEventPayload _play(String uuid, {double seconds = 5}) =>
    HistoryEventPayload(
      eventUuid: uuid,
      kind: 'play',
      entityType: 'track',
      entityRef: 't1',
      occurredAt: 1800000000000,
      secondsPlayed: seconds,
      trackLength: 200,
    );

void main() {
  late AppDatabase db;
  late HistoryRepository repo;
  late String token;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    token = await seedTestBinding(db);
    repo = HistoryRepository(db);
  });
  tearDown(() => db.close());

  Future<List<HistoryEvent>> events() => db.select(db.historyEvents).get();

  test('a checkpoint creates the draft and later ones update it', () async {
    await repo.checkpointDraft(token, _draft('11111111-1111-4111-8111-111111111111'));
    await repo.checkpointDraft(token,
        _draft('11111111-1111-4111-8111-111111111111', micros: 9000000, checkpoint: 20));
    final drafts = await repo.drafts();
    expect(drafts, hasLength(1));
    expect(drafts.single.accumulatedMicros, 9000000);
    expect(drafts.single.lastCheckpointAt, 20);
    expect(drafts.single.finalizing, isFalse);
  });

  test('finalizing inserts the play event and deletes the draft together',
      () async {
    const uuid = '22222222-2222-4222-8222-222222222222';
    await repo.checkpointDraft(token, _draft(uuid));
    expect(await repo.finalizeDraft(token, _play(uuid)),
        DraftFinalization.inserted);
    expect(await repo.drafts(), isEmpty);
    final rows = await events();
    expect(rows.single.eventUuid, uuid);
    expect(rows.single.kind, 'play');
    expect(rows.single.secondsPlayed, 5);
    expect(rows.single.pendingUpload, isTrue);
  });

  test('a repeated finalization is idempotent; a different one conflicts',
      () async {
    const uuid = '33333333-3333-4333-8333-333333333333';
    await repo.checkpointDraft(token, _draft(uuid));
    await repo.finalizeDraft(token, _play(uuid));
    await repo.checkpointDraft(token, _draft(uuid)); // crash replay
    expect(await repo.finalizeDraft(token, _play(uuid)),
        DraftFinalization.alreadyPresent);
    expect(await repo.drafts(), isEmpty);
    expect(await events(), hasLength(1));
    await repo.checkpointDraft(token, _draft(uuid));
    expect(await repo.finalizeDraft(token, _play(uuid, seconds: 9)),
        DraftFinalization.conflict);
    expect((await events()).single.secondsPlayed, 5, reason: 'never overwritten');
    expect(await repo.drafts(), hasLength(1), reason: 'kept for diagnosis');
  });

  test('a frozen draft keeps its final payload and stops accumulating',
      () async {
    const uuid = '44444444-4444-4444-8444-444444444444';
    await repo.checkpointDraft(token, _draft(uuid));
    await repo.freezeDraft(token, uuid, _play(uuid));
    await repo.checkpointDraft(token, _draft(uuid, micros: 99000000));
    final draft = (await repo.drafts()).single;
    expect(draft.finalizing, isTrue);
    expect(draft.finalPayload, _play(uuid));
    expect(draft.accumulatedMicros, 5000000,
        reason: 'a frozen payload is never mutated later');
  });

  test('a zero-credit draft is deleted', () async {
    const uuid = '55555555-5555-4555-8555-555555555555';
    await repo.checkpointDraft(token, _draft(uuid));
    await repo.deleteDraft(token, uuid);
    expect(await repo.drafts(), isEmpty);
  });

  test('every draft write is fenced by the binding', () async {
    const u = '66666666-6666-4666-8666-666666666666';
    await repo.checkpointDraft(token, _draft(u));
    await db.customStatement('DELETE FROM server_binding');
    final fenced = throwsA(isA<BindingFencedException>());
    await expectLater(repo.checkpointDraft(token, _draft(u, micros: 9)), fenced);
    await expectLater(repo.freezeDraft(token, u, _play(u)), fenced);
    await expectLater(repo.finalizeDraft(token, _play(u)), fenced);
    await expectLater(repo.deleteDraft(token, u), fenced);
    final draft = (await repo.drafts()).single;
    expect((draft.accumulatedMicros, draft.finalizing), (5000000, false),
        reason: 'nothing changed under a replaced binding');
    expect(await db.select(db.historyEvents).get(), isEmpty);
  });

  test('a finalization is atomic: a failed draft delete inserts no event',
      () async {
    const u = '77777777-7777-4777-8777-777777777777';
    await repo.checkpointDraft(token, _draft(u));
    await db.customStatement(
        'CREATE TRIGGER keep_drafts BEFORE DELETE ON active_listens '
        "BEGIN SELECT RAISE(ABORT, 'disk full'); END");
    await expectLater(repo.finalizeDraft(token, _play(u)), throwsA(anything));
    expect(await db.select(db.historyEvents).get(), isEmpty);
    expect((await repo.drafts()).single.listenUuid, u);
  });

  // U26-A-07: one frozen draft whose stored payload cannot be read made
  // drafts() throw, so recovery settled none of the others.
  test('a draft whose payload cannot be read is skipped, the rest are listed',
      () async {
    const good = '44444444-4444-4444-8444-444444444444';
    const notJson = '55555555-5555-4555-8555-555555555555';
    const wrongShape = '66666666-6666-4666-8666-666666666666';
    const accumulating = '77777777-7777-4777-8777-777777777777';
    // At most one draft accumulates: freeze each before the next starts.
    for (final uuid in [good, notJson, wrongShape]) {
      await repo.checkpointDraft(token, _draft(uuid));
      await repo.freezeDraft(token, uuid, _play(uuid));
    }
    await repo.checkpointDraft(token, _draft(accumulating));
    await db.customStatement(
        "UPDATE active_listens SET final_payload_json = '{not json' "
        "WHERE listen_uuid = '$notJson'");
    await db.customStatement(
        "UPDATE active_listens SET final_payload_json = '{\"kind\":\"play\"}' "
        "WHERE listen_uuid = '$wrongShape'");

    final drafts = await repo.drafts();

    expect({for (final d in drafts) d.listenUuid}, {good, accumulating});
    final frozen = drafts.singleWhere((d) => d.listenUuid == good);
    expect(frozen.finalPayload?.eventUuid, good);
    // The unreadable rows are kept, not deleted.
    expect(await db.select(db.activeListens).get(), hasLength(4));
  });

  // B.13 (U26-A-01): the drafts read their stored payload with the one
  // strict reader the transport uses, so a payload missing a key is
  // unreadable (it was read with the measure as unknown) and skipped like
  // the others; the app always writes every key.
  test('a stored payload missing a key is unreadable and skipped', () async {
    const good = '88888888-8888-4888-8888-888888888888';
    const missingKey = '99999999-9999-4999-8999-999999999999';
    for (final uuid in [good, missingKey]) {
      await repo.checkpointDraft(token, _draft(uuid));
      await repo.freezeDraft(token, uuid, _play(uuid));
    }
    final stored = (await (db.select(db.activeListens)
              ..where((l) => l.listenUuid.equals(missingKey)))
            .getSingle())
        .finalPayloadJson!;
    final withoutMeasure = (jsonDecode(stored) as Map<String, Object?>)
      ..remove('track_length');
    await (db.update(db.activeListens)
          ..where((l) => l.listenUuid.equals(missingKey)))
        .write(ActiveListensCompanion(
      finalPayloadJson: Value(jsonEncode(withoutMeasure)),
    ));

    final drafts = await repo.drafts();

    expect([for (final d in drafts) d.listenUuid], [good]);
    expect(await db.select(db.activeListens).get(), hasLength(2));
  });
}
