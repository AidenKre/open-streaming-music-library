// 7B.1d S12: SC-15 for uploads. `quiesce()` cancels transfers, polling,
// status queries and the runner and returns promptly; the reset runs it
// after history and before durable submissions, without building the
// manager just to stop it. The Disconnect confirmation gets "N uploads not
// yet sent" for this binding's files whose bytes the server doesn't have
// (rows of an earlier sign-in can't be sent any more, so they are not
// counted). One manager per scope, sharing the scope's DurableSubmission.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/api/uploads_api.dart';
import 'package:frontend/models/dto/upload_dtos.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/clock.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/operations/durable_submission.dart';
import 'package:frontend/services/uploads/upload_import_sync.dart';
import 'package:frontend/services/uploads/upload_manager.dart';

import '../../helpers/fake_clock.dart';
import '../../helpers/fake_uploads_api.dart';
import '../../helpers/server_binding.dart';
import '../../helpers/upload_manager_harness.dart';

void main() {
  group('quiesce', () {
    late UploadHarness h;
    late ValueNotifier<bool> visible;

    setUp(() async {
      visible = ValueNotifier(true);
      h = await UploadHarness.create(visible: visible);
      await h.verify();
    });
    tearDown(() => h.dispose());

    test('aborts transfers, stops polling and the runner; nothing is sent '
        'afterwards', () async {
      await h.manager.addFiles([
        await h.file('a.flac', 'abc'),
        await h.file('b.flac', 'abcd'),
      ]);
      await h.pump();
      final puts = h.api.openPuts;
      expect(puts, hasLength(2));

      await h.manager.quiesce();
      await h.pump();

      expect(puts.every((p) => p.aborted), isTrue);
      expect(h.timers.active, isEmpty);
      final calls = h.api.calls.length;
      h.manager.start();
      visible.value = false;
      visible.value = true;
      await h.pump();
      expect(h.api.calls.length, calls);
    });

    test('a status query that never answers does not hold the quiesce',
        () async {
      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      await h.pump();
      h.api.onGetItem = (_) => Completer<UploadItem>().future;
      h.api.openPuts.single.fail(
        apiError(503, 'upload_slots_busy', retryable: true, retryAfterS: 1),
      );
      await h.pump();
      h.clock.advance(const Duration(seconds: 5));
      h.timers.fire();
      await h.pump();
      expect(h.api.calls.last, 'getItem u-2'); // hanging

      await expectLater(h.manager.quiesce(), completes);
    });

    test('a quiesce while the gate is unverified ends the wait', () async {
      final fresh = await UploadHarness.create();
      addTearDown(fresh.dispose);
      await fresh.manager.addFiles([await fresh.file('a.flac', 'abc')]);
      await expectLater(fresh.manager.quiesce(), completes);
      expect(fresh.api.calls, isEmpty);
    });
  });

  group('loss summary', () {
    late UploadHarness h;
    setUp(() async => h = await UploadHarness.create());
    tearDown(() => h.dispose());

    test('counts this binding\'s files not yet on the server, singular and '
        'plural; null when none', () async {
      final reporter = UploadLossReporter(
        intents: h.store,
        binding: h.binding,
      );
      expect(await reporter.pendingLossSummary(), isNull);

      await h.manager.addFiles([await h.file('a.flac', 'abc')]);
      expect(await reporter.pendingLossSummary(), '1 upload not yet sent');

      await h.manager.addFiles([await h.file('b.flac', 'abcd')]);
      expect(await reporter.pendingLossSummary(), '2 uploads not yet sent');

      // States whose bytes the server has, or that ended, don't count.
      for (final s in ['validating', 'review_ready', 'imported', 'cancelled',
          'failed', 'rejected']) {
        await h.db.customStatement(
          "UPDATE upload_intents SET last_state = '$s' WHERE item_uuid = 'u-2'",
        );
        expect(await reporter.pendingLossSummary(), '1 upload not yet sent',
            reason: s);
      }
      // Those that still need sending do.
      for (final s in ['allocated', 'transferring', 'needs_reselect',
          'source_changed']) {
        await h.db.customStatement(
          "UPDATE upload_intents SET last_state = '$s' WHERE item_uuid = 'u-2'",
        );
        expect(await reporter.pendingLossSummary(), '2 uploads not yet sent',
            reason: s);
      }

      await h.binding.rotate(); // rows of an earlier sign-in: not counted
      expect(await reporter.pendingLossSummary(), isNull);
    });
  });

  group('scope wiring', () {
    late AppDatabase db;
    late ProviderContainer c;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await seedTestBinding(db, reconciled: true);
      c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          clockProvider.overrideWithValue(FakeClock()),
          autoVerifiedGateOverride(startOnRead: false),
          uploadsApiProvider.overrideWithValue(FakeUploadsApi()),
        ],
      );
    });
    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('a reset quiesces uploads after history and before submissions, '
        'without building the manager', () async {
      final participants = c.read(localQuiescablesProvider);
      expect([for (final q in participants) q.quiesceName], [
        'playback',
        'listens',
        'preview',
        'history',
        'uploads',
        'submissions',
      ]);
      await participants
          .singleWhere((q) => q.quiesceName == 'uploads')
          .quiesce();
      expect(c.exists(uploadManagerProvider), isFalse);
    });

    test('the upload loss line is a Disconnect contributor', () async {
      expect(
        c.read(lossReportersProvider).whereType<UploadLossReporter>(),
        hasLength(1),
      );
    });

    test('one manager per scope, on the scope\'s DurableSubmission', () {
      final a = c.read(uploadManagerProvider);
      final b = c.read(uploadManagerProvider);
      expect(identical(a, b), isTrue);
      expect(identical(a.submissions, c.read(durableSubmissionProvider)),
          isTrue);
    });

    // TR-UPLOAD-06: the library sync after an import needs no page; it
    // lives as long as the manager (built at cold start by recovery).
    test('TR-UPLOAD-06 the import sync lives with the manager', () {
      expect(c.exists(uploadImportSyncProvider), isFalse);
      c.read(uploadManagerProvider);
      expect(c.exists(uploadImportSyncProvider), isTrue);
    });

    test('disposing the scope quiesces the manager', () async {
      final m = c.read(uploadManagerProvider);
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      expect(m.isClosed, isTrue);
    });
  });
}
