import 'dart:async';

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
  Future<String?> connect(String url) async => connectError;
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
      fake.set(SessionPhase.resetComplete, failure: LocalResetException([]));
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
