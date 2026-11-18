import 'dart:async';

import 'package:drift/native.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/deletion/delete_job.dart';
import 'package:frontend/services/deletion/delete_jobs_manager.dart';
import 'package:frontend/services/deletion/deletion_preview.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/operations/durable_submission.dart';

import 'fake_clock.dart';
import 'fake_library_tools_api.dart';
import 'server_binding.dart';
import 'upload_manager_harness.dart' show ManualTimers;

export 'fake_library_tools_api.dart';
export 'upload_manager_harness.dart' show ManualTimers, ManualTimer;

/// A `DeleteJobsManager` over a real in-memory database (the shared
/// `durable_submissions` table), a controlled binding gate, the fake API,
/// manual timers and a fake clock. Operation UUIDs are `op-1`, `op-2`, ….
class DeleteJobsHarness {
  DeleteJobsHarness._(this.db, this.binding, this.token, this.gate);

  /// [database]: another database to run over (default: in-memory, in this
  /// isolate).
  static Future<DeleteJobsHarness> create({
    String instanceId = 'inst-1',
    AppDatabase? database,
  }) async {
    final db = database ?? AppDatabase(NativeDatabase.memory());
    final binding = ServerBindingRepository(db);
    final token = await seedTestBinding(db, reconciled: true);
    final gate = ControlledGate(db);
    final h = DeleteJobsHarness._(db, binding, token, gate);
    h.instanceId = instanceId;
    h.api = FakeLibraryToolsApi(gate: gate.gate);
    h.manager = h.build();
    return h;
  }

  final AppDatabase db;
  final ServerBindingRepository binding;
  String token;
  final ControlledGate gate;
  late String instanceId;
  late FakeLibraryToolsApi api;
  late DeleteJobsManager manager;
  final clock = FakeClock(startUtcMs: 9000);
  final timers = ManualTimers();
  bool offline = false;
  int _n = 0;

  /// Each `/changes` sync the manager requested.
  int syncRequests = 0;

  /// What each requested sync answers: whether a fresh pull ran.
  bool syncSucceeds = true;

  AdvertisedFeature<LibraryToolsFeature>? feature = const AdvertisedFeature(
    LibraryToolsFeature(version: 1, serverDelete: true, duplicateReview: false),
    fromCache: false,
  );

  /// A manager over the same database (a relaunch, or a new scope).
  DeleteJobsManager build() => DeleteJobsManager(
    api: api,
    submissions: DurableSubmission(db: db, binding: binding, clock: clock),
    binding: binding,
    gate: gate.gate,
    feature: () async => feature,
    isOffline: () => offline,
    requestSync: () async {
      syncRequests++;
      return syncSucceeds;
    },
    newUuid: () => 'op-${++_n}',
    timer: timers.call,
    backoff: BackoffSchedule(jitter: 0),
  );

  /// Verifies the gate's connection.
  Future<void> verify() async {
    unawaited(gate.gate.startConnection('http://test'));
    await pump();
    gate.respond(instanceId);
    await pump();
  }

  /// Lets every pass, write and fake answer run.
  Future<void> pump() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
      await manager.idle();
    }
  }

  /// Previews [candidates] (uuid, base revision) through the manager.
  Future<DeletionPreview> preview(List<(String, int?)> candidates) =>
      manager.preview([
        for (final (uuid, base) in candidates) DeletionCandidate(uuid, base),
      ]);

  /// Previews then submits [candidates] with the matching count.
  Future<String> submitAll(List<(String, int?)> candidates) async {
    final p = await preview(candidates);
    return manager.submit(p, confirmedCount: p.count);
  }

  DeleteJob? job(String op) => manager.jobs.value[op];

  Future<List<Map<String, Object?>>> submissions() async => [
    for (final r in await db
        .customSelect(
          'SELECT operation_uuid, kind, local_binding_id, frozen_body_json, '
          'state, receipt_json, error_code FROM durable_submissions '
          'ORDER BY created_at, operation_uuid',
        )
        .get())
      r.data,
  ];

  Future<void> dispose() async {
    await manager.quiesce();
    gate.dispose();
    await db.close();
  }
}
