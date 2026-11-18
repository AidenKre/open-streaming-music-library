import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart' show DatabaseVersionRefused;
import 'package:frontend/services/download/track_downloader.dart'
    show DownloadsLeftByReset, downloadsLeftByResetMessage;
import 'package:frontend/services/download_manager.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/server_address_page.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/startup_gate.dart';

import '../helpers/fake_session_service.dart';
import 'fake_session_controls.dart';

void main() {
  group('SessionController (presentation state over SessionService)', () {
    late FakeSessionService service;
    late ProviderContainer c;

    setUp(() {
      c = ProviderContainer(
        overrides: [
          sessionServiceProvider.overrideWith(
            (ref) => service = FakeSessionService(),
          ),
        ],
      );
      c.read(sessionServiceProvider);
    });
    tearDown(() => c.dispose());

    SessionControls session() => c.read(sessionControlsProvider);

    test('a resumed online or offline session is live', () async {
      service.start = const SessionStart(SessionStartKind.offline);
      await session().start();
      expect(session().phase, SessionPhase.live);
    });

    // Review major 2: launch finished an interrupted reset; it ends like any
    // finished reset (the view rebuilds the scope), with no failure to show.
    test('a launch that finished an interrupted reset completes a reset',
        () async {
      service.start = const SessionStart(SessionStartKind.resetFinished);
      await session().start();
      expect(session().phase, SessionPhase.resetComplete);
      expect(session().resetFailure, isNull);
    });

    test(
      'readiness is not the controller\'s rule (the model marks it)',
      () async {
        // The fake service never marks readiness; going live through the
        // controller must not mark it either.
        service.start = const SessionStart(SessionStartKind.offline);
        await session().start();
        expect(session().phase, SessionPhase.live);
        expect(c.read(sessionReadinessProvider).isReady, isFalse);
      },
    );

    // Re-audit 4A #6: the real controller's Retry reaches the model.
    test(
      'retryLibrarySync asks the model for a library sync each time',
      () async {
        await session().retryLibrarySync();
        await session().retryLibrarySync();
        expect(service.syncs, 2);
      },
    );

    test('start runs the saved-session check once', () async {
      await session().start();
      await session().start();
      expect(service.starts, 1);
    });

    test('a rejected saved server signs out with its error', () async {
      service.start = const SessionStart(
        SessionStartKind.serverAddress,
        error: 'rejected',
      );
      await session().start();
      expect(session().phase, SessionPhase.serverAddress);
      expect(session().connectError, 'rejected');
    });

    test('connect: failure keeps the server-address screen with the error; '
        'success opens Log in (Phase M 7.1)', () async {
      await session().start();
      service.connectError = 'unreachable';
      await session().connect('http://typo');
      expect(session().phase, SessionPhase.serverAddress);
      expect(session().connectError, 'unreachable');
      service.connectError = null;
      await session().connect('http://ok');
      expect(session().phase, SessionPhase.logIn);
      expect(session().connectError, isNull);
    });

    test(
      'disconnect: resetting, then complete with an honest failure',
      () async {
        service.start = const SessionStart(SessionStartKind.online);
        await session().start();
        service.resetGate = Completer<void>();
        service.resetFailure = LocalResetException([]);
        final done = session().disconnect();
        expect(session().phase, SessionPhase.resetting);
        // A second request while resetting does not start a second reset.
        unawaited(session().disconnect());
        service.resetGate!.complete();
        await done;
        expect(service.resets, 1);
        expect(session().phase, SessionPhase.resetComplete);
        expect(session().resetFailure, same(service.resetFailure));
        expect(service.reloads, 0, reason: 'the view shows the result first');
        await session().acknowledgeReset();
        // Review r1 m-R1-08: the model rebuilds the scope, never the view.
        expect(service.reloads, 1);
        expect(session().phase, SessionPhase.serverAddress);
        expect(session().resetFailure, isNull);
      },
    );

    group('a login finds a different server (SC-01 rule 1)', () {
      Future<int> askSwitch() async {
        await session().start();
        service.differentServer = true;
        var notified = 0;
        session().addListener(() => notified++);
        await session().connect('http://b');
        return notified;
      }

      test('asks first: still signed out, nothing reset, no error', () async {
        final notified = await askSwitch();
        expect(session().phase, SessionPhase.serverAddress);
        expect(session().pendingServerSwitch, 'http://b');
        expect(session().connectError, isNull);
        expect(notified, greaterThan(0));
        expect(service.switchedTo, isEmpty);
        expect(service.resets, 0);
      });

      test('cancel: back to the login screen, nothing reset', () async {
        await askSwitch();
        session().cancelServerSwitch();
        expect(session().pendingServerSwitch, isNull);
        expect(session().phase, SessionPhase.serverAddress);
        expect(service.switchedTo, isEmpty);
      });

      test('confirm: resetting, then complete; the reset keeps the new URL',
          () async {
        await askSwitch();
        service.resetGate = Completer<void>();
        final done = session().confirmServerSwitch();
        expect(session().phase, SessionPhase.resetting);
        expect(session().pendingServerSwitch, isNull);
        service.resetGate!.complete();
        await done;
        expect(service.switchedTo, ['http://b']);
        expect(service.resets, 0, reason: 'not the URL-dropping disconnect');
        expect(session().phase, SessionPhase.resetComplete);
      });
    });

    test('the blocked state mirrors the model and notifies the view',
        () async {
      var notified = 0;
      session().addListener(() => notified++);
      expect(session().serverBlocked, ServerBlockedReason.none);
      service.blocked.value = ServerBlockedReason.differentServer;
      expect(session().serverBlocked, ServerBlockedReason.differentServer);
      expect(notified, 1);
      service.blocked.value = ServerBlockedReason.signedOut;
      expect(session().serverBlocked, ServerBlockedReason.signedOut);
      expect(notified, 2);
      service.blocked.value = ServerBlockedReason.none;
      expect(session().serverBlocked, ServerBlockedReason.none);
      expect(notified, 3);
    });

    test('Reset on the blocked banner: resetting, then complete, through '
        "the model's keep-the-URL reset", () async {
      service.start = const SessionStart(SessionStartKind.online);
      await session().start();
      service.resetGate = Completer<void>();
      final done = session().resetBlockedServer();
      expect(session().phase, SessionPhase.resetting);
      service.resetGate!.complete();
      await done;
      expect(service.blockedResets, 1);
      expect(service.resets, 0);
      expect(session().phase, SessionPhase.resetComplete);
    });

    // U21-FE-SESSION-A-03: a storage fault inside the model must not leave
    // the splash or the reset spinner up until the app restarts.
    group('a storage fault in the model', () {
      test('at launch: the retry screen, not the splash', () async {
        service.startError = StateError('prefs unreadable');
        final error = await session()
            .start()
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(session().phase, SessionPhase.credentialsUnavailable);
        expect(error, isNull, reason: 'start never throws into the view');
        // Sign-off s7-app-texts item 1: the retry screen names the saved
        // session, not the stored sign-in.
        expect(session().launchFailed, isTrue);
      });

      test('an unreadable stored sign-in is not a launch fault', () async {
        service.start = const SessionStart(
          SessionStartKind.credentialsUnavailable,
          serverUrl: 'http://s',
        );
        await session().start();
        expect(session().phase, SessionPhase.credentialsUnavailable);
        expect(session().launchFailed, isFalse);
      });

      test('at connect: the server-address screen, and connect completes',
          () async {
        await session().start();
        service.connectThrows = StateError('database is locked');
        final error = await session()
            .connect('http://x')
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(error, isNull, reason: 'connect never throws into the view');
        expect(session().phase, SessionPhase.serverAddress);
        // Sign-off s7-app-texts item 1.
        expect(session().connectError,
            'This device could not save the server address.');
      });

      test("at connect: an earlier attempt's error is not left on screen",
          () async {
        await session().start();
        service.connectError = 'Could not reach the server.';
        await session().connect('http://x');
        expect(session().connectError, 'Could not reach the server.');
        service.connectThrows = StateError('database is locked');
        await session()
            .connect('http://x')
            .then<void>((_) {}, onError: (Object _) {});
        expect(session().connectError,
            'This device could not save the server address.',
            reason: 'the old message would name the wrong cause');
      });

      test('in a reset: the reset still completes and its failure is shown',
          () async {
        service.resetThrows = StateError('disk I/O error');
        await session().disconnect().then<void>((_) {}, onError: (Object _) {});
        expect(session().phase, SessionPhase.resetComplete);
        final failure = session().resetFailure;
        expect(failure, isNotNull);
        expect(failure!.failures.any((f) => !f.quiesce), isTrue,
            reason: 'nothing may be assumed wiped: shown as incomplete');
      });
    });

    // Pre-merge review D3-01 (owner, 2026-11-18): a local database of
    // another schema version gets its own screen (its sentence and Reset…),
    // wherever the app meets it: launch, connect, sign-in. Any other fault
    // keeps its own sentence.
    group('a database of another version', () {
      final refusal = DatabaseVersionRefused(8, 1);

      test('at launch: the refusal screen', () async {
        service.startError = refusal;
        await session().start();
        expect(session().phase, SessionPhase.credentialsUnavailable);
        expect(session().databaseRefused, isTrue);
      });

      test('any other launch fault is not the refusal', () async {
        service.startError = StateError('prefs unreadable');
        await session().start();
        expect(session().launchFailed, isTrue);
        expect(session().databaseRefused, isFalse);
      });

      test('at connect: the refusal screen, not the save-failed sentence',
          () async {
        await session().start();
        service.connectThrows = refusal;
        await session().connect('http://x');
        expect(session().phase, SessionPhase.credentialsUnavailable);
        expect(session().databaseRefused, isTrue);
        expect(session().connectError, isNull);
      });

      test('any other connect fault keeps the save-failed sentence', () async {
        await session().start();
        service.connectThrows = StateError('database is locked');
        await session().connect('http://x');
        expect(session().phase, SessionPhase.serverAddress);
        expect(session().databaseRefused, isFalse);
        expect(session().connectError,
            'This device could not save the server address.');
      });

      test('at sign-in: the refusal screen, not a sign-in sentence', () async {
        service.start = const SessionStart(SessionStartKind.logIn,
            serverUrl: 'http://s');
        await session().start();
        service.signInThrows = refusal;
        await session().login('alice', 'pw-alice-1');
        expect(session().phase, SessionPhase.credentialsUnavailable);
        expect(session().databaseRefused, isTrue);
        expect(session().authError, isNull);
      });

      test('any other sign-in fault keeps "Could not sign in."', () async {
        service.start = const SessionStart(SessionStartKind.logIn,
            serverUrl: 'http://s');
        await session().start();
        service.signInThrows = StateError('database is locked');
        await session().login('alice', 'pw-alice-1');
        expect(session().phase, SessionPhase.logIn);
        expect(session().databaseRefused, isFalse);
        expect(session().authError, 'Could not sign in.');
      });

      test('Reset… resets like Disconnect', () async {
        service.startError = refusal;
        await session().start();
        await session().disconnect();
        expect(service.calls, contains('resetLocalData'));
        expect(session().phase, SessionPhase.resetComplete);
        await session().acknowledgeReset();
        expect(session().phase, SessionPhase.serverAddress);
        expect(session().databaseRefused, isFalse,
            reason: 'the reset replaced that database');
      });
    });

    // EX-75c (SC-26): whether the finished reset's dialog is the "sign-in
    // not saved" sentence is the model's rule, read through the controller,
    // so the view imports no service.
    group('signInNotSavedNotice', () {
      Future<String?> after(LocalResetException failure) async {
        service.resetFailure = failure;
        await session().disconnect();
        return session().signInNotSavedNotice;
      }

      LocalResetFailure notSaved() =>
          SignInNotSavedFailure(StateError('keychain'), StackTrace.empty);

      test('only the sign-in was not saved: the sentence', () async {
        expect(await after(LocalResetException([notSaved()])),
            'Could not save the sign-in on this device.');
      });

      test('with a quiesce failure too: still the sentence', () async {
        expect(
          await after(LocalResetException([
            LocalResetFailure(int, StateError('in flight'), StackTrace.empty,
                quiesce: true),
            notSaved(),
          ])),
          'Could not save the sign-in on this device.',
        );
      });

      test('with a wipe failure too: none (the reset is incomplete)',
          () async {
        expect(
          await after(LocalResetException([
            LocalResetFailure(int, StateError('wipe failed'), StackTrace.empty),
            notSaved(),
          ])),
          isNull,
        );
      });
    });

    // Other-issues row 66 and APP-DATA review 2 F4: the "Reset incomplete"
    // sentence is the model's, read through the controller.
    group('resetIncompleteMessage', () {
      Future<String?> after(LocalResetException failure) async {
        service.resetFailure = failure;
        await session().disconnect();
        return session().resetIncompleteMessage;
      }

      LocalResetFailure downloadsLeft() => LocalResetFailure(
          DownloadManager, const DownloadsLeftByReset(2), StackTrace.empty);

      test('downloads left outside the folder: the downloads sentence',
          () async {
        expect(await after(LocalResetException([downloadsLeft()])),
            downloadsLeftByResetMessage);
      });

      test('any other wipe failure: the fixed sentence, without its text',
          () async {
        expect(
          await after(LocalResetException([
            downloadsLeft(),
            LocalResetFailure(int, StateError('wipe failed'), StackTrace.empty),
          ])),
          'Some local data could not be cleared.',
        );
      });

      test('no failure: none', () async {
        await session().disconnect();
        expect(session().resetIncompleteMessage, isNull);
      });
    });

    test('the loss summaries come from the model', () async {
      service.losses = ['2 unsent metadata edits'];
      expect(
        await session().pendingLossSummaries(),
        ['2 unsent metadata edits'],
      );
    });

    // signoff-8-logout-warning: the log-out warning's counts are the model's.
    test('the log-out losses come from the model', () async {
      const losses = LogoutLosses(
        unsentUploads: 2,
        reviewDrafts: 0,
        unsentReviews: null,
        unsentCancels: 0,
        unsentDeletions: 0,
        unconfirmedDeletions: 1,
      );
      service.logoutLosses = losses;
      expect(await session().pendingLogoutLosses(), same(losses));
    });
  });

  group('StartupGate renders the session controller', () {
    Future<FakeSessionControls> pump(
      WidgetTester tester,
      SessionPhase phase, {
      Future<void> Function()? onSessionChanged,
    }) async {
      final fake = FakeSessionControls(phase: phase);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionControlsProvider.overrideWithValue(fake),
            onSessionChangedProvider.overrideWithValue(onSessionChanged),
          ],
          child: const MaterialApp(home: StartupGate()),
        ),
      );
      await tester.pump();
      return fake;
    }

    testWidgets('starts the session once, spinner meanwhile', (tester) async {
      final fake = await pump(tester, SessionPhase.starting);
      expect(fake.calls, ['start']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('signed out: login screen with the error; connect is the '
        "controller's", (tester) async {
      final fake = await pump(tester, SessionPhase.starting);
      fake.set(SessionPhase.serverAddress, error: 'rejected');
      await tester.pump();
      final login = tester.widget<ServerAddressPage>(find.byType(ServerAddressPage));
      expect(login.error, 'rejected');
      await login.onConnect('http://x');
      expect(fake.calls, ['start', 'connect http://x']);
    });

    testWidgets('a quiesce timeout alone (the wipe completed) is not shown as '
        'data left behind (live gate)', (tester) async {
      var rebuilt = 0;
      final fake = await pump(
        tester,
        SessionPhase.resetting,
        onSessionChanged: () async => rebuilt++,
      );
      fake.set(SessionPhase.resetComplete, failure: LocalResetException([
        LocalResetFailure(int, TimeoutException('history pass in flight'),
            StackTrace.empty, quiesce: true),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset incomplete'), findsNothing);
      // Review r1 m-R1-08: the view hands the finished reset to the
      // controller; it never calls the model's rebuild hook itself.
      expect(fake.calls, contains('acknowledgeReset'));
      expect(rebuilt, 0);
    });

    testWidgets('a partial reset is shown, then the scope is rebuilt', (
      tester,
    ) async {
      var rebuilt = 0;
      final fake = await pump(
        tester,
        SessionPhase.resetting,
        onSessionChanged: () async => rebuilt++,
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      fake.set(SessionPhase.resetComplete, failure: LocalResetException([
        LocalResetFailure(int, StateError('wipe failed'), StackTrace.empty,
            participant: Object()),
      ]));
      // The splash spinner animates forever: bounded pumps, not settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset incomplete'), findsOneWidget);
      expect(fake.calls, isNot(contains('acknowledgeReset')));
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.calls, contains('acknowledgeReset'));
      expect(rebuilt, 0, reason: 'review r1 m-R1-08: never the view');
    });

    // U21-FE-SESSION-B-02: the wipe worked, the held sign-in could not be
    // saved. Shown as that, not as data left behind.
    testWidgets('a sign-in not saved after a clean wipe is not shown as an '
        'incomplete reset', (tester) async {
      final fake = await pump(tester, SessionPhase.resetting);
      fake.set(SessionPhase.resetComplete, failure: LocalResetException([
        SignInNotSavedFailure(StateError('keychain'), StackTrace.empty),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset incomplete'), findsNothing);
      // Sign-off s7-app-texts item 1: the dialog has a title of its own.
      expect(find.widgetWithText(AlertDialog, 'Sign-in not saved'),
          findsOneWidget);
      expect(find.text('Could not save the sign-in on this device.'),
          findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.calls, contains('acknowledgeReset'));
    });

    // Sign-off s7-app-texts item 1: a fault thrown at launch is not a stored
    // sign-in that could not be read; the same retry screen names the saved
    // session, and keeps both buttons and what they do.
    group('the retry screen', () {
      const sessionUnreadable = "This device's saved session could not be read.";
      const signInUnreadable = 'Your sign-in could not be read.';
      const signInKept = 'Your saved sign-in is still on this device. Try '
          'again, or log in again to replace it.';

      testWidgets('after a launch fault: the saved session, both buttons',
          (tester) async {
        final fake = FakeSessionControls(
          phase: SessionPhase.credentialsUnavailable,
        )..launchFailed = true;
        await tester.pumpWidget(ProviderScope(
          overrides: [sessionControlsProvider.overrideWithValue(fake)],
          child: const MaterialApp(home: StartupGate()),
        ));
        await tester.pump();
        expect(find.text(sessionUnreadable), findsOneWidget);
        expect(find.text(signInUnreadable), findsNothing);
        expect(find.text(signInKept), findsNothing,
            reason: 'whether a sign-in is stored is not known here');
        await tester.tap(find.text('Try again'));
        await tester.tap(find.text('Log in again'));
        await tester.pump();
        expect(fake.calls, ['start', 'retryCredentials', 'logInAgain']);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      // Owner, 2026-11-17: after a launch fault the screen says what "Log
      // in again" does (it deletes any stored sign-in); the unreadable
      // sign-in case keeps its own texts.
      const replaces =
          'Logging in again replaces any sign-in saved on this device.';

      testWidgets('after a launch fault: says what Log in again does',
          (tester) async {
        final fake = FakeSessionControls(
          phase: SessionPhase.credentialsUnavailable,
        )..launchFailed = true;
        await tester.pumpWidget(ProviderScope(
          overrides: [sessionControlsProvider.overrideWithValue(fake)],
          child: const MaterialApp(home: StartupGate()),
        ));
        await tester.pump();
        expect(find.text(sessionUnreadable), findsOneWidget);
        expect(find.text(replaces), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('an unreadable stored sign-in: no launch-fault sentence',
          (tester) async {
        await pump(tester, SessionPhase.credentialsUnavailable);
        expect(find.text(replaces), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('an unreadable stored sign-in: the sign-in texts as before',
          (tester) async {
        final fake = await pump(tester, SessionPhase.credentialsUnavailable);
        expect(find.text(signInUnreadable), findsOneWidget);
        expect(find.text(signInKept), findsOneWidget);
        expect(find.text(sessionUnreadable), findsNothing);
        expect(find.text('Try again'), findsOneWidget);
        expect(find.text('Log in again'), findsOneWidget);
        expect(fake.launchFailed, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    // Pre-merge review D3-01 (owner, 2026-11-18): the approved sentence and
    // Reset…, which opens the existing "Reset and disconnect?" sheet.
    group('a database of another version', () {
      const refusedText = "This device's saved app data was made by a "
          "different version of the app and can't be opened. Resetting "
          "removes this device's downloads, settings and sign-in. Nothing on "
          'the server changes.';
      const sessionUnreadable = "This device's saved session could not be read.";
      const uncounted = 'Some unsent changes could not be counted';

      Future<FakeSessionControls> refused(WidgetTester tester) async {
        final fake = FakeSessionControls(
          phase: SessionPhase.credentialsUnavailable,
        )
          ..launchFailed = true
          ..databaseRefused = true
          ..lossSummaries = const [uncounted];
        await tester.pumpWidget(ProviderScope(
          overrides: [sessionControlsProvider.overrideWithValue(fake)],
          child: const MaterialApp(home: StartupGate()),
        ));
        await tester.pump();
        return fake;
      }

      Future<void> openSheet(WidgetTester tester) async {
        await tester.tap(find.text('Reset…'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      testWidgets('the approved sentence and Reset…, and nothing else to '
          'press; nothing runs while it shows', (tester) async {
        final fake = await refused(tester);
        expect(find.text(refusedText), findsOneWidget);
        expect(find.text('Reset…'), findsOneWidget);
        expect(find.text(sessionUnreadable), findsNothing);
        expect(find.text('Try again'), findsNothing,
            reason: 'trying again cannot open this database');
        expect(find.text('Log in again'), findsNothing);
        await tester.pump(const Duration(minutes: 5));
        expect(fake.calls, ['start']);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('Reset… opens "Reset and disconnect?" with the uncounted '
          'line; confirming resets', (tester) async {
        final fake = await refused(tester);
        await openSheet(tester);
        expect(find.text('Reset and disconnect?'), findsOneWidget);
        expect(find.textContaining(uncounted), findsOneWidget);
        await tester.tap(find.text('Reset and disconnect'));
        await tester.pump();
        expect(fake.calls, ['start', 'disconnect']);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('Cancel resets nothing; the screen stays', (tester) async {
        final fake = await refused(tester);
        await openSheet(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(fake.calls, ['start']);
        expect(find.text(refusedText), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('a second tap while the losses are read opens one sheet',
          (tester) async {
        final fake = await refused(tester);
        final gate = Completer<List<String>>();
        fake.lossSummariesGate = gate;
        await tester.tap(find.text('Reset…'));
        await tester.tap(find.text('Reset…'));
        gate.complete(const [uncounted]);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(fake.lossSummaryReads, 1);
        expect(find.text('Reset and disconnect?'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets('a launch fault that is not the refusal never shows its '
          'sentence', (tester) async {
        final fake = FakeSessionControls(
          phase: SessionPhase.credentialsUnavailable,
        )..launchFailed = true;
        await tester.pumpWidget(ProviderScope(
          overrides: [sessionControlsProvider.overrideWithValue(fake)],
          child: const MaterialApp(home: StartupGate()),
        ));
        await tester.pump();
        expect(find.text(refusedText), findsNothing);
        expect(find.text('Reset…'), findsNothing);
        expect(find.text(sessionUnreadable), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    });

    group('a login finds a different server', () {
      Future<FakeSessionControls> ask(WidgetTester tester) async {
        final fake = await pump(tester, SessionPhase.serverAddress);
        fake.lossSummaries = ['2 unsent metadata edits'];
        fake.askServerSwitch('http://b');
        await tester.pump();
        await tester.pump();
        // Let the confirmation finish its entrance (a bottom sheet slides in).
        await tester.pump(const Duration(milliseconds: 400));
        return fake;
      }

      testWidgets('asks to confirm, naming the server and what will be lost',
          (tester) async {
        await ask(tester);
        expect(find.text('Connect to a different server?'), findsOneWidget);
        expect(find.textContaining('http://b'), findsOneWidget);
        expect(find.textContaining('2 unsent metadata edits'), findsOneWidget);
        expect(find.text('Reset and connect'), findsOneWidget);
      });

      testWidgets('cancel goes back to the login screen', (tester) async {
        final fake = await ask(tester);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(fake.calls, contains('cancelServerSwitch'));
        expect(fake.calls, isNot(contains('confirmServerSwitch')));
        expect(find.byType(ServerAddressPage), findsOneWidget);
      });

      testWidgets('confirm resets and keeps the URL', (tester) async {
        final fake = await ask(tester);
        await tester.tap(find.text('Reset and connect'));
        await tester.pumpAndSettle();
        expect(fake.calls, contains('confirmServerSwitch'));
        expect(fake.calls, isNot(contains('cancelServerSwitch')));
      });
    });

    testWidgets('without a rebuild hook, a finished reset returns to login', (
      tester,
    ) async {
      final fake = await pump(tester, SessionPhase.resetting);
      fake.set(SessionPhase.resetComplete);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(fake.calls, contains('acknowledgeReset'));
    });
  });
}
