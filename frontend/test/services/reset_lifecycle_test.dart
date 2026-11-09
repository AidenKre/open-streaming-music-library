// SC-15: reset lifecycle fence -> quiesce -> wipe.
//  1. Fence (first, awaited): bump the in-memory generation synchronously,
//     then delete the SC-01 binding row. If the delete fails, ABORT before
//     quiesce or wipe and report it.
//  2. Quiesce (best effort, bounded): ordered participants stop timers and
//     settle in-flight work; failures/timeouts are reported but never block.
//  3. Wipe: the existing priority bands.
// Plus the Disconnect confirmation's aggregated "will be lost" summaries.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/server_binding.dart';

class _Quiesce implements Quiescable {
  _Quiesce(this.name, this.log, {this.onQuiesce});
  final String name;
  final List<String> log;
  final Future<void> Function()? onQuiesce;
  @override
  String get quiesceName => name;
  @override
  Future<void> quiesce() async {
    log.add('quiesce:$name');
    await onQuiesce?.call();
  }
}

class _Wipe implements LocalResettable {
  _Wipe(this.name, this.log, {this.onReset});
  final String name;
  final List<String> log;
  final Future<void> Function()? onReset;
  @override
  int get resetPriority => 0;
  @override
  Future<void> resetLocalState() async {
    log.add('wipe:$name');
    await onReset?.call();
  }
}

class _Loss implements LossReporter {
  _Loss(this.summary);
  final String? summary;
  @override
  Future<String?> pendingLossSummary() async => summary;
}

class _BrokenLoss implements LossReporter {
  @override
  Future<String?> pendingLossSummary() async => throw StateError('db locked');
}

class _FailingFence extends ServerBindingRepository {
  _FailingFence(super.db);
  @override
  Future<void> fence() async => throw StateError('disk I/O error');
}

void main() {
  late AppDatabase db;
  late List<String> log;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    await seedTestBinding(db);
    log = [];
  });

  tearDown(() => db.close());

  ProviderContainer container({
    List<Quiescable> quiescables = const [],
    List<LocalResettable>? resettables,
    List<LossReporter> reporters = const [],
    ServerBindingRepository? binding,
    Duration quiesceTimeout = const Duration(seconds: 5),
  }) {
    final c = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        if (binding != null)
          serverBindingRepositoryProvider.overrideWithValue(binding),
        localQuiescablesProvider.overrideWithValue(quiescables),
        localResettablesProvider.overrideWithValue(
          resettables ?? [_Wipe('db', log)],
        ),
        lossReportersProvider.overrideWithValue(reporters),
        localResetServiceProvider.overrideWith(
          (ref) => LocalResetService(ref, quiesceTimeout: quiesceTimeout),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<bool> bound() async =>
      (await ServerBindingRepository(db).current()) != null;

  test('the binding row is deleted before any quiesce or wipe step', () async {
    final seen = <String, bool>{};
    final c = container(
      quiescables: [
        _Quiesce('player', log, onQuiesce: () async => seen['quiesce'] = await bound()),
      ],
      resettables: [
        _Wipe('db', log, onReset: () async => seen['wipe'] = await bound()),
      ],
    );
    await c.read(localResetServiceProvider).reset();
    expect(log, ['quiesce:player', 'wipe:db']);
    expect(seen, {'quiesce': false, 'wipe': false});
  });

  test('the in-memory generation bumps synchronously at reset start', () async {
    final c = container();
    final service = c.read(localResetServiceProvider);
    final before = service.generation;
    final running = service.reset();
    expect(service.generation, before + 1);
    await running;
  });

  test('a failed fence aborts before quiesce and wipe', () async {
    final c = container(
      binding: _FailingFence(db),
      quiescables: [_Quiesce('player', log)],
      resettables: [_Wipe('db', log)],
    );
    await expectLater(
      c.read(localResetServiceProvider).reset(),
      throwsA(isA<LocalResetAbortedException>()),
    );
    expect(log, isEmpty);
    expect(await bound(), isTrue);
  });

  test('quiesce runs in registry order; a failure is reported, never blocks',
      () async {
    final c = container(
      quiescables: [
        _Quiesce('player', log),
        _Quiesce('runner', log, onQuiesce: () async => throw StateError('boom')),
        _Quiesce('uploads', log),
      ],
      resettables: [_Wipe('db', log)],
    );
    final error = await c
        .read(localResetServiceProvider)
        .reset()
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(log, ['quiesce:player', 'quiesce:runner', 'quiesce:uploads', 'wipe:db']);
    expect(error, isA<LocalResetException>());
    expect((error! as LocalResetException).failures.single.error, isA<StateError>());
  });

  test('a hung quiesce participant is bounded by the timeout', () async {
    final never = Completer<void>();
    final c = container(
      quiesceTimeout: Duration.zero,
      quiescables: [
        _Quiesce('stuck', log, onQuiesce: () => never.future),
        _Quiesce('next', log),
      ],
      resettables: [_Wipe('db', log)],
    );
    await expectLater(
      c.read(localResetServiceProvider).reset(),
      throwsA(isA<LocalResetException>()),
    );
    expect(log, ['quiesce:stuck', 'quiesce:next', 'wipe:db']);
  });

  test('a clean reset reports nothing', () async {
    final c = container(quiescables: [_Quiesce('player', log)]);
    await c.read(localResetServiceProvider).reset();
    expect(log, ['quiesce:player', 'wipe:db']);
  });

  group('pending loss summaries (Disconnect confirmation)', () {
    test('aggregates each participant, skipping those with nothing to lose',
        () async {
      final c = container(
        reporters: [_Loss(null), _Loss('2 unsent edits'), _Loss('1 upload')],
      );
      expect(
        await c.read(localResetServiceProvider).pendingLossSummaries(),
        ['2 unsent edits', '1 upload'],
      );
    });

    // Unknown is not zero: a reporter that cannot count must neither hide
    // the confirmation (Disconnect must stay possible) nor read as "nothing
    // will be lost".
    test('a reporter that fails is reported as uncounted, not dropped',
        () async {
      final c = container(
        reporters: [_Loss('2 unsent edits'), _BrokenLoss(), _Loss('1 upload')],
      );
      expect(
        await c.read(localResetServiceProvider).pendingLossSummaries(),
        [
          '2 unsent edits',
          'Some unsent changes could not be counted',
          '1 upload',
        ],
      );
    });

    test('the edit outbox reports its unresolved edits', () async {
      final c = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(c.dispose);
      final service = c.read(localResetServiceProvider);
      expect(await service.pendingLossSummaries(), isEmpty);

      await db.customStatement(
        'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
        "updated_at) VALUES ('a', '{}', 'db_only', 'pending', 1), "
        "('b', '{}', 'db_only', 'conflicted', 1)",
      );
      expect(await service.pendingLossSummaries(), ['2 unsent metadata edits']);

      // A server-rejected edit still holds the user's values until they fix
      // or discard it, so a reset loses it too (the same "unresolved" set as
      // the pending-edits badge).
      await db.customStatement(
        'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
        "updated_at) VALUES ('c', '{}', 'db_only', 'rejected', 1)",
      );
      expect(await service.pendingLossSummaries(), ['3 unsent metadata edits']);
    });
  });
}
