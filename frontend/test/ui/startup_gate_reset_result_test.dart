// What the StartupGate shows when a reset finishes, for each kind of result
// (refactor APP-SESSION-1, guide A.1, places 4 and 5; the other places are in
// test/services/reset_result_sites_test.dart). Today:
//  * no failure, or only stopping (quiesce) failed: no dialog, then the
//    reset is acknowledged (the quiesce-only case also writes a developer
//    log line, which these tests do not observe);
//  * any other failure: a dialog first, then the acknowledgement after OK.
//    "Sign-in not saved" when every failure other than stopping is the
//    unsaved sign-in; "Reset incomplete" with the downloads sentence alone
//    when every such failure is downloads left outside the app's folder;
//    otherwise "Reset incomplete" with one fixed sentence, never the
//    failures' own text (other-issues row 66).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/services/download/track_downloader.dart'
    show DownloadsLeftByReset, downloadsLeftByResetMessage;
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/startup_gate.dart';

import 'fake_session_controls.dart';

void main() {
  LocalResetFailure quiesce() => LocalResetFailure(
      int, TimeoutException('history pass in flight'), StackTrace.empty,
      quiesce: true);
  LocalResetFailure wipe() => LocalResetFailure(
      int, StateError('wipe failed'), StackTrace.empty,
      participant: Object());
  // The gate reads no participant; the subsystem names the database.
  LocalResetFailure database() => LocalResetFailure(
      AppDatabase, StateError('db wipe failed'), StackTrace.empty);
  LocalResetFailure aborted() => LocalResetFailure(
      LocalResetService, StateError('fence failed'), StackTrace.empty);
  LocalResetFailure notSaved() =>
      SignInNotSavedFailure(StateError('keychain'), StackTrace.empty);
  LocalResetFailure downloadsLeft() => LocalResetFailure(
      DownloadManager, const DownloadsLeftByReset(1), StackTrace.empty,
      participant: Object());

  Future<FakeSessionControls> finish(
    WidgetTester tester,
    LocalResetException? failure,
  ) async {
    final fake = FakeSessionControls(phase: SessionPhase.resetting);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionControlsProvider.overrideWithValue(fake)],
        child: const MaterialApp(home: StartupGate()),
      ),
    );
    await tester.pump();
    fake.set(SessionPhase.resetComplete, failure: failure);
    // The splash spinner animates forever: bounded pumps, not settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return fake;
  }

  final noDialog = <String, List<LocalResetFailure> Function()?>{
    'no failure': null,
    'an empty failure list': () => [],
    'only stopping failed': () => [quiesce()],
  };
  for (final MapEntry(key: name, value: failures) in noDialog.entries) {
    testWidgets('$name: no dialog, the reset is acknowledged', (tester) async {
      final fake = await finish(
          tester, failures == null ? null : LocalResetException(failures()));
      expect(find.byType(AlertDialog), findsNothing);
      expect(fake.calls, contains('acknowledgeReset'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  final incomplete = <String, List<LocalResetFailure> Function()>{
    'a wipe step failed': () => [wipe()],
    'the database wipe failed': () => [database()],
    'the fence failed': () => [aborted()],
    'stopping and a wipe step failed': () => [quiesce(), wipe()],
    'a wipe step failed and the sign-in was not saved': () =>
        [wipe(), notSaved()],
    'downloads were left and another wipe step failed': () =>
        [downloadsLeft(), wipe()],
  };
  for (final MapEntry(key: name, value: failures) in incomplete.entries) {
    testWidgets('$name: "Reset incomplete" with one fixed sentence, then the '
        'acknowledgement', (tester) async {
      final failure = LocalResetException(failures());
      final fake = await finish(tester, failure);
      expect(find.widgetWithText(AlertDialog, 'Reset incomplete'),
          findsOneWidget);
      expect(find.text('Some local data could not be cleared.'),
          findsOneWidget);
      expect(find.textContaining('LocalResetException'), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
      expect(fake.calls, isNot(contains('acknowledgeReset')));
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.calls, contains('acknowledgeReset'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  // APP-DATA review 2, F4: the downloads sentence alone, without the
  // exception's class names.
  final downloads = <String, List<LocalResetFailure> Function()>{
    'only downloads were left': () => [downloadsLeft()],
    'stopping failed and downloads were left': () =>
        [quiesce(), downloadsLeft()],
  };
  for (final MapEntry(key: name, value: failures) in downloads.entries) {
    testWidgets('$name: "Reset incomplete" with the downloads sentence alone',
        (tester) async {
      final fake = await finish(tester, LocalResetException(failures()));
      expect(find.widgetWithText(AlertDialog, 'Reset incomplete'),
          findsOneWidget);
      expect(find.text(downloadsLeftByResetMessage), findsOneWidget);
      expect(find.textContaining('LocalResetException'), findsNothing);
      expect(find.textContaining('DownloadManager'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.calls, contains('acknowledgeReset'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  final signInNotSaved = <String, List<LocalResetFailure> Function()>{
    'only the sign-in was not saved': () => [notSaved()],
    'stopping failed and the sign-in was not saved': () =>
        [quiesce(), notSaved()],
  };
  for (final MapEntry(key: name, value: failures) in signInNotSaved.entries) {
    testWidgets('$name: "Sign-in not saved", then the acknowledgement',
        (tester) async {
      final fake = await finish(tester, LocalResetException(failures()));
      expect(find.widgetWithText(AlertDialog, 'Sign-in not saved'),
          findsOneWidget);
      expect(find.text('Could not save the sign-in on this device.'),
          findsOneWidget);
      expect(find.text('Reset incomplete'), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.calls, contains('acknowledgeReset'));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
