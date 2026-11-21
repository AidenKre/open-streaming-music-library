import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' as drift
    show ApplyInterceptor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/upload_review_transport.dart';
import 'package:frontend/services/uploads/upload_source.dart';

import 'fake_clock.dart';
import 'fake_uploads_api.dart';
import 'server_binding.dart';

/// A timer a test fires by hand.
class ManualTimer implements Timer {
  ManualTimer(this.duration, this._callback);
  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

/// Collects every timer the code under test starts.
class ManualTimers {
  final all = <ManualTimer>[];

  Timer call(Duration d, void Function() f) {
    final t = ManualTimer(d, f);
    all.add(t);
    return t;
  }

  List<ManualTimer> get active => [for (final t in all) if (t.isActive) t];

  /// Fires every active timer of exactly [d] (or all, when null).
  void fire([Duration? d]) {
    for (final t in active) {
      if (d == null || t.duration == d) t.fire();
    }
  }
}

/// An `UploadManager` over a real in-memory database, a controlled binding
/// gate, the fake API, manual timers and a fake clock. Files live in an
/// owned temporary directory.
class UploadHarness {
  UploadHarness._(this.dir, this.db, this.binding, this.token, this.gate);

  static Future<UploadHarness> create({
    String instanceId = 'inst-1',
    ValueListenable<bool>? visible,
    UploadReviewTransport? review,
    drift.QueryInterceptor? interceptor,
  }) async {
    final dir = Directory.systemTemp.createTempSync('osml_7b1d');
    final memory = NativeDatabase.memory();
    final db = AppDatabase(
      interceptor == null ? memory : memory.interceptWith(interceptor),
    );
    final binding = ServerBindingRepository(db);
    final token =
        await seedTestBinding(db, instanceId: instanceId, reconciled: true);
    final gate = ControlledGate(db);
    final h = UploadHarness._(dir, db, binding, token, gate);
    h.instanceId = instanceId;
    h.visible = visible ?? ValueNotifier(false);
    h.review = review;
    h.api = FakeUploadsApi(gate: gate.gate);
    h.manager = h.build();
    return h;
  }

  final Directory dir;
  final AppDatabase db;
  final ServerBindingRepository binding;
  final String token;
  final ControlledGate gate;
  late String instanceId;
  late ValueListenable<bool> visible;
  UploadReviewTransport? review;
  late FakeUploadsApi api;
  late UploadManager manager;
  final clock = FakeClock(startUtcMs: 9000);
  final timers = ManualTimers();
  bool offline = false;

  /// The manager's `/app/info` re-read (null: none).
  Future<void> Function()? refreshCapabilities;
  int _n = 0;
  AdvertisedFeature<UploadsFeature>? feature = const AdvertisedFeature(
    UploadsFeature(version: 1, limits: UploadLimits(receivesPerUser: 2)),
    fromCache: false,
  );

  /// A second manager over the same database (a relaunch).
  UploadManager build() => UploadManager(
    api: api,
    submissions: DurableSubmission(db: db, binding: binding, clock: clock),
    intents: UploadIntentStore(db: db, binding: binding, clock: clock),
    binding: binding,
    gate: gate.gate,
    clock: clock,
    feature: () async => feature,
    refreshCapabilities: refreshCapabilities,
    isOffline: () => offline,
    newUuid: () => 'u-${++_n}',
    timer: timers.call,
    passBackoff: BackoffSchedule(jitter: 0),
    transferBackoff: BackoffSchedule(jitter: 0),
    visible: visible,
    review: review,
    openSource: openSource,
  );

  /// Paths the manager opened for a transfer, in order.
  final opened = <String>[];

  /// Opens a source synchronously (a stat on the calling thread), so a
  /// transfer's start never waits on asynchronous file I/O whose completion
  /// order the test can't control.
  Future<FileUploadSource> openSource(String path, {String? displayName}) {
    opened.add(path);
    final f = File(path);
    if (!f.existsSync()) return Future.error(const UploadSourceUnavailable());
    return Future.value(FileUploadSource(
      path: path,
      displayName: displayName ?? path.split('/').last,
      length: f.lengthSync(),
    ));
  }

  /// The intent store over this harness's database.
  UploadIntentStore get store =>
      UploadIntentStore(db: db, binding: binding, clock: clock);

  /// Verifies the gate's connection.
  Future<void> verify() async {
    unawaited(gate.gate.startConnection('http://test'));
    await pump();
    gate.respond(instanceId);
    await pump();
  }

  Future<FileUploadSource> file(String name, String content) async {
    final f = File('${dir.path}/$name')..writeAsStringSync(content);
    return FileUploadSource.open(f.path);
  }

  /// Lets every pass, write and fake answer run.
  Future<void> pump() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
      await manager.idle();
    }
  }

  Future<List<Map<String, Object?>>> intents() async => [
    for (final r in await db
        .customSelect(
          'SELECT item_uuid, batch_uuid, last_state, last_error_code, '
          'transfer_operation_uuid, local_binding_id FROM upload_intents '
          'ORDER BY batch_uuid, selection_index',
        )
        .get())
      r.data,
  ];

  Future<Map<String, String>> states() async => {
    for (final r in await intents())
      r['item_uuid'] as String: r['last_state'] as String,
  };

  Future<List<Map<String, Object?>>> submissions() async => [
    for (final r in await db
        .customSelect(
          'SELECT operation_uuid, kind, state, error_code, updated_at '
          'FROM durable_submissions ORDER BY created_at, operation_uuid',
        )
        .get())
      r.data,
  ];

  Future<void> dispose() async {
    await manager.quiesce();
    gate.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  }
}

