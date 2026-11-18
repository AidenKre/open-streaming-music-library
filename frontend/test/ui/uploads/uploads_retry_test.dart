// Phase 7B.2c S7: Retry on the Uploads page (spec §7 para 3 "cancel/retry";
// DEV-7B2b-01 left a server-`failed` item with Cancel only). The model says
// which items offer Retry: a `failed` item whose code the server marks
// retryable (7A.2c: `probe_timeout`, `probe_unavailable`,
// `upload_source_missing`, `upload_validation_failed`); a final failure
// offers none. Retry is a network action (disabled offline, like Cancel).
// The controller forwards it to the manager and words the outcome; the page
// shows the button and sends the tap to the controller (SC-26).
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/uploads/upload_intent_store.dart';
import 'package:frontend/services/uploads/upload_manager.dart';
import 'package:frontend/services/uploads/uploads_overview.dart';
import 'package:frontend/services/uploads/uploads_overview_provider.dart';
import 'package:frontend/services/uploads/uploads_visibility.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/uploads/uploads_controller.dart';
import 'package:frontend/ui/uploads/uploads_page.dart';

import '../browse_harness.dart';
import '../fake_session_controls.dart';
import '../fake_uploads_controls.dart';

// A file picked on this device (it has the digest): a lost received file
// can be sent again from here (review r1 #2 keeps Retry for such rows only).
UploadIntentRecord _intent(String state, {String? code}) => UploadIntentRecord(
  itemUuid: 'i',
  batchUuid: 'b',
  parentItemUuid: null,
  selectionIndex: 0,
  displayName: 'a.flac',
  lastState: state,
  lastErrorCode: code,
  lastErrorMessage: null,
  operationUuid: null,
  transferOperationUuid: null,
  reviewGeneration: null,
  draftJson: null,
  localBindingId: 'bind',
  createdAtMs: 0,
  updatedAtMs: 0,
  expectedLength: null,
  expectedSha256: 'abc',
  descriptor: null,
);

UploadRow _row(String state, {String? code, bool online = true}) =>
    UploadsOverview.of(
      intents: [_intent(state, code: code)],
      progress: const {},
      availability: online
          ? UploadsAvailability.available
          : UploadsAvailability.offline,
    ).rows.single;

class _Manager implements UploadManager {
  final calls = <String>[];
  Object? error;
  RetryOutcome outcome = RetryOutcome.accepted;
  Completer<void>? gate;

  @override
  Future<RetryOutcome> retry(String itemUuid) async {
    calls.add('retry $itemUuid');
    await gate?.future;
    if (error != null) throw error!;
    return outcome;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('which items offer Retry (model)', () {
    for (final code in [
      'probe_timeout',
      'probe_unavailable',
      'upload_source_missing',
      'upload_validation_failed',
    ]) {
      test('a failed item with the retryable code $code offers Retry', () {
        final row = _row('failed', code: code);
        expect(row.offersRetry, isTrue);
        expect(row.canRetry, isTrue);
      });
    }

    for (final code in [
      'upload_invalid_audio',
      'upload_unsupported_audio',
      'upload_archive_corrupt',
      null,
    ]) {
      test('a final failure ($code) offers no Retry', () {
        expect(_row('failed', code: code).offersRetry, isFalse);
      });
    }

    test('other states offer no Retry', () {
      for (final s in [
        'review_ready',
        'imported',
        'expired',
        'cancelled',
        'rejected',
        'needs_reselect',
      ]) {
        expect(_row(s, code: 'probe_timeout').offersRetry, isFalse, reason: s);
      }
    });

    test('offline, Retry is shown but off', () {
      final row = _row('failed', code: 'probe_timeout', online: false);
      expect(row.offersRetry, isTrue);
      expect(row.canRetry, isFalse);
    });
  });

  group('the controller forwards Retry and words the outcome', () {
    late _Manager manager;
    late ProviderContainer container;
    late NotifierUploadsVisibility visibility;

    setUp(() {
      manager = _Manager();
      visibility = NotifierUploadsVisibility();
      final overview = StateProvider<UploadsOverview?>(
        (ref) => fakeUploadsOverview(const []),
      );
      container = ProviderContainer(
        overrides: [
          uploadManagerProvider.overrideWithValue(manager),
          uploadsVisibilityProvider.overrideWithValue(visibility),
          uploadsOverviewProvider.overrideWith((ref) => ref.watch(overview)),
        ],
      );
    });
    tearDown(() {
      container.dispose();
      visibility.dispose();
    });

    UploadsControls create() =>
        container.read(uploadsControllerFactoryProvider)();

    test('accepted: forwarded, nothing to say', () async {
      final c = create();
      await c.retry('i');
      expect(manager.calls, ['retry i']);
      expect(c.notice, isNull);
      c.dispose();
    });

    test('not retryable: the user is told', () async {
      manager.outcome = RetryOutcome.notRetryable;
      final c = create();
      await c.retry('i');
      expect(c.notice?.title, "This file can't be retried.");
      c.dispose();
    });

    test('changed meanwhile: the user is told to look again', () async {
      manager.outcome = RetryOutcome.changed;
      final c = create();
      await c.retry('i');
      expect(c.notice?.title,
          'This file changed on the server. Check its status and try again.');
      c.dispose();
    });

    test('a failure is explained, never thrown', () async {
      manager.error = NetworkException('lost', attemptsMade: 1);
      final c = create();
      await c.retry('i');
      expect(c.notice?.title, 'Something went wrong. Try again.');
      c.dispose();
    });

    test('a second tap while one retry runs sends nothing more', () async {
      manager.gate = Completer<void>();
      final c = create();
      final first = c.retry('i');
      await c.retry('i');
      manager.gate!.complete();
      await first;
      expect(manager.calls, ['retry i']);
      c.dispose();
    });
  });

  group('the page', () {
    late AppDatabase db;
    late BrowseHarness harness;
    late FakeUploadsControls fake;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      harness = await BrowseHarness.create(db);
    });
    tearDown(() async {
      await harness.dispose();
      await db.close();
    });

    Future<void> pump(WidgetTester tester, UploadsOverview overview) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      fake = FakeUploadsControls(overview: overview);
      await tester.pumpWidget(harness.wrap(
        const UploadsPage(),
        overrides: [
          uploadsControllerFactoryProvider.overrideWithValue(() => fake),
          sessionControlsProvider.overrideWithValue(FakeSessionControls()),
        ],
      ));
      await tester.pump();
    }

    testWidgets('Retry goes to the controller', (tester) async {
      await pump(tester, fakeUploadsOverview([
        fakeUploadRow('a', name: 'one.flac', retry: true, cancel: true),
      ]));
      expect(find.bySemanticsLabel('Retry one.flac'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(fake.calls, ['retry a']);
      await teardownTree(tester);
    });

    testWidgets('no Retry where the model offers none', (tester) async {
      await pump(tester, fakeUploadsOverview([
        fakeUploadRow('a', name: 'one.flac', cancel: true),
      ]));
      expect(find.text('Retry'), findsNothing);
      await teardownTree(tester);
    });

    testWidgets('offline, Retry is shown disabled', (tester) async {
      await pump(
        tester,
        fakeUploadsOverview(
          [fakeUploadRow('a', name: 'one.flac', retry: true, enabled: false)],
          availability: UploadsAvailability.offline,
        ),
      );
      final button = tester.widget<TextButton>(
          find.ancestor(of: find.text('Retry'), matching: find.byType(TextButton)));
      expect(button.onPressed, isNull);
      await tester.tap(find.text('Retry'), warnIfMissed: false);
      await tester.pump();
      expect(fake.calls, isEmpty);
      await teardownTree(tester);
    });
  });
}
