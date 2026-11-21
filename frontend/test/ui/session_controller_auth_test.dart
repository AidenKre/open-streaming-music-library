// Phase M §7.1: SessionControls maps the model's launch result onto the
// screens (presentation state only; the rules are SessionService's).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/session_controller.dart';

import '../helpers/fake_session_service.dart';

void main() {
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

  test('a saved URL without credentials opens Log in, showing the URL',
      () async {
    service.start =
        const SessionStart(SessionStartKind.logIn, serverUrl: 'http://s');
    await session().start();
    expect(session().phase, SessionPhase.logIn);
    expect(session().serverUrl, 'http://s');
  });

  // Review r1 m-R1-07: the notice that the stored sign-in could not be
  // removed is shown on Log in.
  test("Log in shows the model's launch notice", () async {
    service.start = const SessionStart(SessionStartKind.logIn,
        serverUrl: 'http://s', error: 'could not remove');
    await session().start();
    expect(session().phase, SessionPhase.logIn);
    expect(session().authError, 'could not remove');
  });

  test('unreadable credentials open the retry state, not Log in', () async {
    service.start = const SessionStart(SessionStartKind.credentialsUnavailable);
    await session().start();
    expect(session().phase, SessionPhase.credentialsUnavailable);
  });

  test('a successful connect opens Log in for the saved URL', () async {
    await session().start();
    await session().connect('http://new');
    expect(session().phase, SessionPhase.logIn);
    expect(session().serverUrl, 'http://new');
    expect(session().connectError, isNull);
  });

  test('no saved URL opens the server-address screen', () async {
    await session().start();
    expect(session().phase, SessionPhase.serverAddress);
    expect(session().serverUrl, isNull);
  });

  signInGroup();
}

void signInGroup() {
  group('sign-in input (SessionControls over SessionService)', () {
    late FakeSessionService service;
    late ProviderContainer c;

    setUp(() async {
      c = ProviderContainer(overrides: [
        sessionServiceProvider
            .overrideWith((ref) => service = FakeSessionService(
                start: const SessionStart(SessionStartKind.logIn,
                    serverUrl: 'http://s'))),
      ]);
      c.read(sessionServiceProvider);
      await c.read(sessionControlsProvider).start();
    });
    tearDown(() => c.dispose());

    SessionControls session() => c.read(sessionControlsProvider);

    test('login forwards to the model; a failure shows the server message',
        () async {
      service.outcome = const SignInFailed('Wrong username or password.');
      await session().login('sam', 'secret-pw');
      expect(service.calls, ['login sam']);
      expect(session().authError, 'Wrong username or password.');
      expect(session().phase, SessionPhase.logIn);
    });

    // Pre-merge review A5-03: a sign-in that throws ends the attempt with
    // a sentence; the next attempt runs.
    for (final register in [false, true]) {
      test('a ${register ? 'register' : 'login'} that throws ends the attempt '
          'with a sentence; the next attempt runs', () async {
        if (register) session().showCreateAccount();
        service.signInThrows = StateError('database is locked');
        Future<void> attempt() => register
            ? session().register('sam', '12345678', '12345678')
            : session().login('sam', 'secret-pw');
        await attempt();
        expect(session().authError, 'Could not finish signing in.');
        service.signInThrows = null;
        service.outcome = const SignInFailed('Wrong username or password.');
        await attempt();
        expect(service.calls, hasLength(2));
        expect(session().authError, 'Wrong username or password.');
      });
    }

    test('blank fields are refused before the model is asked', () async {
      await session().login('', 'secret-pw');
      expect(service.calls, isEmpty);
      expect(session().authError, isNotNull);
    });

    test('Create account and back, and Change server', () async {
      session().showCreateAccount();
      expect(session().phase, SessionPhase.createAccount);
      session().showLogIn();
      expect(session().phase, SessionPhase.logIn);
      session().changeServer();
      expect(session().phase, SessionPhase.serverAddress);
    });

    test('register checks the confirmation and the minimum length first',
        () async {
      session().showCreateAccount();
      await session().register('sam', '1234567', '1234567');
      expect(service.calls, isEmpty);
      expect(session().authError, contains('8'));
      await session().register('sam', '12345678', '12345670');
      expect(service.calls, isEmpty);
      expect(session().authError, contains('match'));
      await session().register('sam', '12345678', '12345678');
      expect(service.calls, ['register sam']);
    });

    test('a server refusal on Create account shows its message', () async {
      session().showCreateAccount();
      service.outcome = const SignInFailed('Sign-up is closed on this server.');
      await session().register('sam', '12345678', '12345678');
      expect(session().authError, 'Sign-up is closed on this server.');
      expect(session().phase, SessionPhase.createAccount);
    });

    group('a different user on this device', () {
      setUp(() async {
        service.outcome = const SignInNeedsUserSwitch('bob');
        await session().login('bob', 'secret-pw');
      });

      test('asks: pendingUserSwitch names the new user, nothing reset', () {
        expect(session().pendingUserSwitch, 'bob');
        expect(session().phase, SessionPhase.logIn);
        expect(service.calls, ['login bob']);
      });

      test('confirm: resetting, then complete, through the model', () async {
        service.resetGate = Completer<void>();
        final done = session().confirmUserSwitch();
        expect(session().phase, SessionPhase.resetting);
        expect(session().pendingUserSwitch, isNull);
        service.resetGate!.complete();
        await done;
        expect(service.calls, contains('confirmPendingSignIn'));
        expect(session().phase, SessionPhase.resetComplete);
      });

      test('cancel: the model revokes; back at Log in', () async {
        await session().cancelUserSwitch();
        expect(session().pendingUserSwitch, isNull);
        expect(service.calls, contains('cancelPendingSignIn'));
        expect(session().phase, SessionPhase.logIn);
      });
    });

    group('a different server found at login', () {
      setUp(() async {
        service.outcome = const SignInDifferentServer('http://s');
        await session().login('sam', 'secret-pw');
      });

      test('is the different-server sheet', () {
        expect(session().pendingServerSwitch, 'http://s');
        expect(session().pendingUserSwitch, isNull);
      });

      test('cancel lets the model revoke the held sign-in', () async {
        session().cancelServerSwitch();
        await pumpEventQueue();
        expect(service.calls, contains('cancelPendingSignIn'));
        expect(session().phase, SessionPhase.logIn);
      });

      test('confirm resets through the model for that URL', () async {
        await session().confirmServerSwitch();
        expect(service.calls, contains('resetForNewServer http://s'));
      });
    });

    // Review F5: one sign-in at a time; the screen can't change under it.
    test('a second Log in while one runs is ignored, and so is Change '
        'server', () async {
      service.signInGate = Completer<void>();
      final first = session().login('sam', 'secret-pw');
      unawaited(session().login('sam', 'secret-pw'));
      unawaited(session().register('sam', '12345678', '12345678'));
      session().changeServer();
      session().showCreateAccount();
      expect(session().phase, SessionPhase.logIn);
      service.signInGate!.complete();
      await first;
      expect(service.calls, ['login sam']);
      session().changeServer();
      expect(session().phase, SessionPhase.serverAddress,
          reason: 'allowed again once the sign-in finished');
    });

    // Review F4: a second Log out tap while one runs does nothing.
    // signoff-8-logout-warning round 3: the banner's Log in keeps the unsent
    // uploads and deletions; the controller only passes that on.
    test('a log-out that keeps the unsent changes says so to the model',
        () async {
      await session().logOutKeepingUnsent();
      expect(service.calls, ['logout keep']);
    });

    test('a second logout while one runs is ignored', () async {
      service.logoutGate = Completer<void>();
      final first = session().logout();
      await pumpEventQueue();
      unawaited(session().logout());
      service.logoutGate!.complete();
      await first;
      expect(service.calls, ['logout']);
    });

    // Review r1 m-R1-07: a logout the model could not finish never throws
    // out of the controller, and a later Log out still reaches the model.
    test('a failed logout is swallowed and does not block the next one',
        () async {
      service.logoutError = StateError('could not clear');
      await session().logout();
      await session().logout();
      expect(service.calls, ['logout', 'logout']);
    });

    // Review r1 m-R1-05: "Log in again" is the model's forget, then Log in.
    test('"Log in again" asks the model to forget the sign-in, then shows '
        'Log in', () async {
      await session().logInAgain();
      expect(service.calls, ['forgetStoredSignIn']);
      expect(session().phase, SessionPhase.logIn);
    });

    // Review r1 m-R1-16: logout can take seconds (quiesce, a 10 s revoke):
    // it shows progress, and no reset may start while it runs (nor it while
    // a reset runs).
    test('logout shows progress and blocks Disconnect meanwhile', () async {
      service.logoutGate = Completer<void>();
      final first = session().logout();
      await pumpEventQueue();
      expect(session().phase, SessionPhase.signingOut);
      await session().disconnect();
      expect(service.calls, isNot(contains('resetLocalData')));
      service.logoutGate!.complete();
      await first;
      expect(session().phase, SessionPhase.logIn,
          reason: 'without a rebuild hook it ends at Log in');
    });

    test('a reset in progress blocks Log out', () async {
      service.resetGate = Completer<void>();
      final reset = session().confirmUserSwitch();
      await pumpEventQueue();
      expect(session().phase, SessionPhase.resetting);
      await session().logout();
      expect(service.calls, isNot(contains('logout')));
      service.resetGate!.complete();
      await reset;
    });

    test('logout and the credential retry are model calls', () async {
      await session().logout();
      await session().retryCredentials();
      expect(service.calls, ['logout', 'reloadSession']);
    });
  });
}
