// Phase M §7.1 / M-U18: Log in and Create account are views over
// SessionControls (fake controller here): every input goes to the
// controller, the server's SC-22 message and the client-side check results
// are rendered from its state. StartupGate routes the phases and asks before
// a user switch.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/create_account_page.dart';
import 'package:frontend/ui/login_page.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/startup_gate.dart';

import '../helpers/fake_session_service.dart';
import 'browse_harness.dart' show teardownTree;
import 'fake_session_controls.dart';

void main() {
  Future<FakeSessionControls> pump(
    WidgetTester tester,
    SessionPhase phase, {
    String? serverUrl = 'http://music.local:8000',
  }) async {
    final fake = FakeSessionControls(phase: phase)..serverUrl = serverUrl;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionControlsProvider.overrideWithValue(fake)],
        child: const MaterialApp(home: StartupGate()),
      ),
    );
    await tester.pump();
    return fake;
  }

  group('Log in', () {
    testWidgets('shows the server address; Log in sends the typed fields',
        (tester) async {
      final fake = await pump(tester, SessionPhase.logIn);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.textContaining('http://music.local:8000'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('login.username')), 'sam');
      await tester.enterText(
          find.byKey(const Key('login.password')), 'secret-pw');
      await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
      await tester.pump();
      expect(fake.calls, contains('login sam secret-pw'));
      await teardownTree(tester);
    });

    testWidgets('the password field is obscured', (tester) async {
      await pump(tester, SessionPhase.logIn);
      final field = tester.widget<TextField>(find.descendant(
          of: find.byKey(const Key('login.password')),
          matching: find.byType(TextField)));
      expect(field.obscureText, isTrue);
      await teardownTree(tester);
    });

    testWidgets("renders the controller's error (the server's message)",
        (tester) async {
      final fake = await pump(tester, SessionPhase.logIn);
      fake.setAuthError('Wrong username or password.');
      await tester.pump();
      expect(find.text('Wrong username or password.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('Create account is always offered; Change server too',
        (tester) async {
      final fake = await pump(tester, SessionPhase.logIn);
      await tester.tap(find.text('Create account'));
      await tester.pump();
      await tester.tap(find.text('Change server'));
      await tester.pump();
      expect(fake.calls, containsAllInOrder(['showCreateAccount', 'changeServer']));
      await teardownTree(tester);
    });
  });

  // Pre-merge review A5-03: the real controller over a sign-in that throws
  // after the server answered: the button comes back and a sentence shows.
  for (final register in [false, true]) {
    testWidgets(
        'a ${register ? 'register' : 'login'} that throws gives the button '
        'back and shows a sentence', (tester) async {
      final service = FakeSessionService()
        ..signInThrows = StateError('database is locked');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            home: register ? const CreateAccountPage() : const LoginPage(),
          ),
        ),
      );
      final prefix = register ? 'createAccount' : 'login';
      final label = register ? 'Create account' : 'Log in';
      await tester.enterText(find.byKey(Key('$prefix.username')), 'sam');
      await tester.enterText(find.byKey(Key('$prefix.password')), '12345678');
      if (register) {
        await tester.enterText(
            find.byKey(const Key('createAccount.confirm')), '12345678');
      }
      await tester.tap(find.widgetWithText(FilledButton, label));
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      final button =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));
      expect(button.onPressed, isNotNull, reason: 'the button is usable again');
      expect(find.text('Could not sign in.'), findsOneWidget);
      await teardownTree(tester);
    });
  }

  group('Create account', () {
    testWidgets('sends username, password and confirmation to the controller',
        (tester) async {
      final fake = await pump(tester, SessionPhase.createAccount);
      expect(find.byType(CreateAccountPage), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('createAccount.username')), 'sam');
      await tester.enterText(
          find.byKey(const Key('createAccount.password')), '12345678');
      await tester.enterText(
          find.byKey(const Key('createAccount.confirm')), '12345679');
      await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
      await tester.pump();
      expect(fake.calls, contains('register sam 12345678 12345679'));
      await teardownTree(tester);
    });

    testWidgets('both password fields are obscured', (tester) async {
      await pump(tester, SessionPhase.createAccount);
      for (final key in ['createAccount.password', 'createAccount.confirm']) {
        final field = tester.widget<TextField>(find.descendant(
            of: find.byKey(Key(key)), matching: find.byType(TextField)));
        expect(field.obscureText, isTrue, reason: key);
      }
      await teardownTree(tester);
    });

    testWidgets('the password hint names the minimum length', (tester) async {
      await pump(tester, SessionPhase.createAccount);
      expect(find.text('At least 8 characters.'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets("renders the controller's error; back goes to Log in",
        (tester) async {
      final fake = await pump(tester, SessionPhase.createAccount);
      fake.setAuthError('That username is taken.');
      await tester.pump();
      expect(find.text('That username is taken.'), findsOneWidget);
      await tester.tap(find.text('I have an account'));
      await tester.pump();
      expect(fake.calls, contains('showLogIn'));
      await teardownTree(tester);
    });
  });

  group('a different user on this device', () {
    Future<FakeSessionControls> ask(WidgetTester tester) async {
      final fake = await pump(tester, SessionPhase.logIn);
      fake.lossSummaries = ['3 unsent history events'];
      fake.askUserSwitch('bob');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return fake;
    }

    testWidgets('asks, naming the new user and what is lost', (tester) async {
      await ask(tester);
      expect(find.textContaining('bob'), findsWidgets);
      expect(find.textContaining("previous account's downloads"),
          findsOneWidget);
      expect(find.textContaining('3 unsent history events'), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('cancel goes back to Log in through the controller',
        (tester) async {
      final fake = await ask(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('cancelUserSwitch'));
      expect(fake.calls, isNot(contains('confirmUserSwitch')));
      expect(find.byType(LoginPage), findsOneWidget);
      await teardownTree(tester);
    });

    testWidgets('confirm is the controller\'s', (tester) async {
      final fake = await ask(tester);
      await tester.tap(find.text('Remove and log in'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('confirmUserSwitch'));
      await teardownTree(tester);
    });
  });

  testWidgets('unreadable credentials: a retry, not the Log in screen',
      (tester) async {
    final fake = await pump(tester, SessionPhase.credentialsUnavailable);
    expect(find.byType(LoginPage), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(fake.calls, contains('retryCredentials'));
    expect(fake.calls, isNot(contains('logInAgain')));
    await teardownTree(tester);
  });

  // Review r1 m-R1-16: logging out shows progress, not the app.
  testWidgets('signing out shows the splash', (tester) async {
    await pump(tester, SessionPhase.signingOut);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    await teardownTree(tester);
  });

  // Review r1 m-R1-05: the retry screen is never a dead end. "Log in again"
  // is a second, explicit choice; "Try again" stays the primary action.
  testWidgets('unreadable credentials: "Log in again" is the second choice',
      (tester) async {
    final fake = await pump(tester, SessionPhase.credentialsUnavailable);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Log in again'), findsNothing);
    await tester.tap(find.text('Log in again'));
    await tester.pump();
    expect(fake.calls, contains('logInAgain'));
    expect(fake.calls, isNot(contains('retryCredentials')));
    await teardownTree(tester);
  });
}
