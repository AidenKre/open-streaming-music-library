import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/startup_gate.dart';

import 'fake_session_controls.dart';

class _FakeService extends SessionService {
  _FakeService(super.ref);
  SessionStart start = const SessionStart(SessionStartKind.signedOut);
  String? connectError;
  bool differentServer = false;
  List<String> losses = const [];
  final switchedTo = <String>[];
  final blocked = ValueNotifier<bool>(false);
  int blockedResets = 0;
  @override
  ValueListenable<bool> get serverBlocked => blocked;
  @override
  Future<LocalResetException?> resetForBlockedServer() async {
    blockedResets++;
    await resetGate?.future;
    return resetFailure;
  }

  LocalResetException? resetFailure;
  Completer<void>? resetGate;
  int resets = 0;
  int starts = 0;
  int syncs = 0;
  @override
  Future<void> syncLibrary() async => syncs++;
  @override
  Future<SessionStart> resumeSavedSession() async {
    starts++;
    return start;
  }

  @override
  Future<ConnectOutcome> connect(String url) async {
    if (differentServer) return ConnectDifferentServer(url);
    final error = connectError;
    return error == null ? const ConnectSucceeded() : ConnectFailed(error);
  }

  @override
  Future<List<String>> pendingLossSummaries() async => losses;

  @override
  Future<LocalResetException?> resetForNewServer(String url) async {
    switchedTo.add(url);
    await resetGate?.future;
    return resetFailure;
  }

  @override
  Future<LocalResetException?> resetLocalData() async {
    resets++;
    await resetGate?.future;
    return resetFailure;
  }
}

void main() {
  group('SessionController (presentation state over SessionService)', () {
    late _FakeService service;
    late ProviderContainer c;

    setUp(() {
      c = ProviderContainer(
        overrides: [
          sessionServiceProvider.overrideWith(
            (ref) => service = _FakeService(ref),
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
        SessionStartKind.signedOut,
        error: 'rejected',
      );
      await session().start();
      expect(session().phase, SessionPhase.signedOut);
      expect(session().connectError, 'rejected');
    });

    test('connect: failure keeps the login screen with the error; success '
        'enters the session', () async {
      await session().start();
      service.connectError = 'unreachable';
      await session().connect('http://typo');
      expect(session().phase, SessionPhase.signedOut);
      expect(session().connectError, 'unreachable');
      service.connectError = null;
      await session().connect('http://ok');
      expect(session().phase, SessionPhase.live);
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
        session().acknowledgeReset();
        expect(session().phase, SessionPhase.signedOut);
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
        expect(session().phase, SessionPhase.signedOut);
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
        expect(session().phase, SessionPhase.signedOut);
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
      expect(session().serverBlocked, isFalse);
      service.blocked.value = true;
      expect(session().serverBlocked, isTrue);
      expect(notified, 1);
      service.blocked.value = false;
      expect(session().serverBlocked, isFalse);
      expect(notified, 2);
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

    test('the loss summaries come from the model', () async {
      service.losses = ['2 unsent metadata edits'];
      expect(
        await session().pendingLossSummaries(),
        ['2 unsent metadata edits'],
      );
    });
  });

  group('StartupGate renders the session controller', () {
    Future<FakeSessionControls> pump(
      WidgetTester tester,
      SessionPhase phase, {
      VoidCallback? onLocalResetComplete,
    }) async {
      final fake = FakeSessionControls(phase: phase);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionControlsProvider.overrideWithValue(fake)],
          child: MaterialApp(
            home: StartupGate(onLocalResetComplete: onLocalResetComplete),
          ),
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
      fake.set(SessionPhase.signedOut, error: 'rejected');
      await tester.pump();
      final login = tester.widget<LoginPage>(find.byType(LoginPage));
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
        onLocalResetComplete: () => rebuilt++,
      );
      fake.set(SessionPhase.resetComplete, failure: LocalResetException([
        LocalResetFailure(int, TimeoutException('history pass in flight'),
            StackTrace.empty, quiesce: true),
      ]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Reset incomplete'), findsNothing);
      expect(rebuilt, 1);
    });

    testWidgets('a partial reset is shown, then the scope is rebuilt', (
      tester,
    ) async {
      var rebuilt = 0;
      final fake = await pump(
        tester,
        SessionPhase.resetting,
        onLocalResetComplete: () => rebuilt++,
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
      expect(rebuilt, 0);
      await tester.tap(find.text('OK'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(rebuilt, 1);
    });

    group('a login finds a different server', () {
      Future<FakeSessionControls> ask(WidgetTester tester) async {
        final fake = await pump(tester, SessionPhase.signedOut);
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
        expect(find.byType(LoginPage), findsOneWidget);
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
