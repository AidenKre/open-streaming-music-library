// Phase M §7.2 "Credentials enter the scope before it is built" (M-U19
// scope): FrontendApp loads the session URL asynchronously BEFORE each keyed
// scope build, and `onSessionChanged()` re-reads it, then bumps the
// generation, so every scope's client is built from its own immutable URL.
// M.3b: the stored credentials are loaded the same way, before each scope
// build, so the scope's client carries that scope's immutable credentials.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/main.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/background/backoff_schedule.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:frontend/ui/session_controller.dart';
import 'package:frontend/ui/startup_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import 'fake_player_controls.dart';
import 'fake_session_controls.dart';
import 'browse_harness.dart' show teardownTree;

class _NoRecovery extends RecoveryService {
  _NoRecovery(super.ref);
  @override
  Future<void> runFor(RecoveryTrigger trigger) async {}
}

void main() {
  late AppDatabase db;
  late Directory dir;
  late List<Completer<String?>> loads;
  late FakeSecureBackend secure;
  late CredentialStore store;
  Completer<void>? credentialGate;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    dir = await Directory.systemTemp.createTemp('frontend_app_test_');
    loads = [];
    secure = FakeSecureBackend();
    store = CredentialStore(secure: secure, directory: dir);
    credentialGate = null;
  });

  tearDown(() async {
    await db.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<String?> load() {
    final c = Completer<String?>();
    loads.add(c);
    return c.future;
  }

  Widget app({
    Future<Credentials?> Function()? loadCredentials,
    SessionEventLogFile? sessionEventLog,
    List<Override> extraOverrides = const [],
  }) =>
      FrontendApp(
        db: db,
        sessionEventLog: sessionEventLog,
        audioHandler: AudioServiceBridge(),
        coverArtDirectory: dir,
        loadSessionUrl: load,
        credentialStore: store,
        loadCredentials: loadCredentials ??
            () async {
              await credentialGate?.future;
              return store.read();
            },
        testOverrides: [
          sessionControlsProvider
              .overrideWith((ref) => FakeSessionControls(
                    phase: SessionPhase.starting,
                  )),
          recoveryServiceProvider.overrideWith(_NoRecovery.new),
          playerControlsProvider.overrideWithValue(FakePlayerControls()),
          ...extraOverrides,
        ],
      );

  ProviderContainer scopeOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(StartupGate)));

  testWidgets('no scope is built until the saved URL has loaded; the scope '
      'gets that URL', (tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.byType(StartupGate), findsNothing);
    expect(loads, hasLength(1));

    loads.single.complete('http://saved:1');
    await tester.pump();
    await tester.pump();

    final scope = scopeOf(tester);
    expect(scope.read(sessionUrlProvider), 'http://saved:1');
    expect(scope.read(apiClientProvider).baseUrl, 'http://saved:1');
    await teardownTree(tester);
  });

  testWidgets('onSessionChanged re-reads the URL, then builds a new scope '
      'with it', (tester) async {
    await tester.pumpWidget(app());
    loads.single.complete(null); // no session yet
    await tester.pump();
    await tester.pump();
    final first = scopeOf(tester);
    expect(first.read(sessionUrlProvider), isNull);
    final onSessionChanged = first.read(onSessionChangedProvider);
    expect(onSessionChanged, isNotNull);

    final rebuilt = onSessionChanged!();
    await tester.pump();
    expect(loads, hasLength(2), reason: 're-read before the rebuild');
    expect(identical(scopeOf(tester), first), isTrue,
        reason: 'the old scope stays until the URL is read');

    loads.last.complete('http://new:2');
    await rebuilt;
    await tester.pump();
    await tester.pump();

    final second = scopeOf(tester);
    expect(identical(second, first), isFalse);
    expect(second.read(sessionUrlProvider), 'http://new:2');
    expect(second.read(apiClientProvider).baseUrl, 'http://new:2');
    await teardownTree(tester);
  });

  // Sign-off s7-app-texts item 2 (review r1 #7): the process's one session
  // log file reaches every scope, also after a rebuild, so its writes stay
  // in one serialized chain.
  testWidgets('every scope gets the app\'s session log file', (tester) async {
    final log = SessionEventLogFile(dir);
    await tester.pumpWidget(app(sessionEventLog: log));
    loads.single.complete(null);
    await tester.pump();
    await tester.pump();
    final first = scopeOf(tester);
    expect(first.read(sessionEventLogFileProvider), same(log));

    final rebuilt = first.read(onSessionChangedProvider)!();
    await tester.pump();
    loads.last.complete(null);
    await rebuilt;
    await tester.pump();
    await tester.pump();
    final second = scopeOf(tester);
    expect(identical(second, first), isFalse);
    expect(second.read(sessionEventLogFileProvider), same(log));
    await teardownTree(tester);
  });

  const alice = Credentials(
    token: 'api-token-A',
    mediaToken: 'media-token-A',
    userId: 7,
    username: 'alice',
  );
  const bob = Credentials(
    token: 'api-token-B',
    mediaToken: 'media-token-B',
    userId: 8,
    username: 'bob',
  );

  testWidgets('the scope gets the stored credentials and the store',
      (tester) async {
    await tester.runAsync(() => store.save(alice));
    await tester.pumpWidget(app());
    loads.single.complete('http://saved:1');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();

    final scope = scopeOf(tester);
    expect(scope.read(credentialsProvider), alice);
    expect(scope.read(hasSessionProvider), isTrue);
    expect(identical(scope.read(credentialStoreProvider), store), isTrue);
    await teardownTree(tester);
  });

  testWidgets('no stored credentials: the scope is signed out',
      (tester) async {
    await tester.pumpWidget(app());
    loads.single.complete('http://saved:1');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();

    final scope = scopeOf(tester);
    expect(scope.read(credentialsProvider), isNull);
    expect(scope.read(hasSessionProvider), isFalse);
    await teardownTree(tester);
  });

  testWidgets('no scope is built until the credentials have loaded',
      (tester) async {
    credentialGate = Completer<void>();
    await tester.pumpWidget(app());
    loads.single.complete('http://saved:1');
    await tester.pump();
    await tester.pump();
    expect(find.byType(StartupGate), findsNothing,
        reason: 'the URL alone is not enough');

    credentialGate!.complete();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
    expect(find.byType(StartupGate), findsOneWidget);
    await teardownTree(tester);
  });

  testWidgets('onSessionChanged re-reads the credentials for the new scope',
      (tester) async {
    await tester.runAsync(() => store.save(alice));
    await tester.pumpWidget(app());
    loads.single.complete('http://saved:1');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
    final first = scopeOf(tester);
    expect(first.read(credentialsProvider), alice);

    await tester.runAsync(() => store.save(bob));
    final rebuilt = first.read(onSessionChangedProvider)!();
    await tester.pump();
    loads.last.complete('http://saved:1');
    await tester.runAsync(() => rebuilt);
    await tester.pump();
    await tester.pump();

    final second = scopeOf(tester);
    expect(identical(second, first), isFalse);
    expect(second.read(credentialsProvider), bob);
    await teardownTree(tester);
  });

  // Review r1 finding 5: overlapping onSessionChanged calls apply only the
  // newest result, and a failing credentials read still builds a scope.
  testWidgets('an older load finishing last never replaces a newer one',
      (tester) async {
    final credentialLoads = <Completer<Credentials?>>[];
    await tester.pumpWidget(app(loadCredentials: () {
      final c = Completer<Credentials?>();
      credentialLoads.add(c);
      return c.future;
    }));
    loads.single.complete('http://saved:1');
    await tester.pump();
    credentialLoads.single.complete(null);
    await tester.pump();
    await tester.pump();
    final first = scopeOf(tester);

    final older = first.read(onSessionChangedProvider)!();
    final newer = first.read(onSessionChangedProvider)!();
    await tester.pump();
    loads[1].complete('http://saved:1');
    loads[2].complete('http://saved:1');
    await tester.pump();
    credentialLoads[2].complete(bob); // the newer call finishes first
    await tester.pump();
    credentialLoads[1].complete(alice); // the older one finishes last
    await older;
    await newer;
    await tester.pump();
    await tester.pump();

    expect(scopeOf(tester).read(credentialsProvider), bob);
    await teardownTree(tester);
  });

  testWidgets('a credentials read that fails still builds a signed-out '
      'scope', (tester) async {
    await tester.pumpWidget(app(
      loadCredentials: () async => throw CredentialsUnavailableException(),
    ));
    loads.single.complete('http://saved:1');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(StartupGate), findsOneWidget);
    expect(scopeOf(tester).read(credentialsProvider), isNull);
    await teardownTree(tester);
  });

  // M.3b review 2 (UI side, M.3c): unknown is not absent. The scope learns
  // the read failed, so launch shows a retry state instead of Log in.
  testWidgets('a failed credentials read is marked unavailable in the scope',
      (tester) async {
    await tester.pumpWidget(app(
      loadCredentials: () async => throw CredentialsUnavailableException(),
    ));
    loads.single.complete('http://saved:1');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(scopeOf(tester).read(credentialsUnavailableProvider), isTrue);
    await teardownTree(tester);
  });

  // Review r1 m-R1-46: a prefs failure while loading the saved URL must not
  // leave the splash up forever: the scope is built with no URL.
  testWidgets('a session-URL load that throws still builds a scope',
      (tester) async {
    await tester.pumpWidget(app());
    loads.single.completeError(StateError('prefs plugin failed'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(StartupGate), findsOneWidget);
    expect(scopeOf(tester).read(sessionUrlProvider), isNull);
    await teardownTree(tester);
  });

  testWidgets('a read that finds nothing is not "unavailable"',
      (tester) async {
    await tester.pumpWidget(app(loadCredentials: () async => null));
    loads.single.complete('http://saved:1');
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(scopeOf(tester).read(credentialsUnavailableProvider), isFalse);
    await teardownTree(tester);
  });

  // Phase M §7.2/§7.7 (M-U24): the scope's 401 hook is the session's
  // signed-out reason, once the bound server's identity is read again.
  testWidgets("the scope's 401 hook sets the session's signed-out reason",
      (tester) async {
    await tester.runAsync(() async {
      await store.save(alice);
      await seedTestBinding(db,
          baseUrl: 'http://saved:1', instanceId: 'inst-1', userId: alice.userId);
    });
    await tester.pumpWidget(app(extraOverrides: [
      // The bound server answers the identity read.
      serverBindingGateProvider.overrideWith((ref) {
        final gate = ServerBindingGate(
          repository: ref.read(serverBindingRepositoryProvider),
          signedInUserId: alice.userId,
          probe: ({required String baseUrl, required bool reportOffline}) async =>
              const ServerIdentity('inst-1'),
          backoff: BackoffSchedule(jitter: 0),
        );
        ref.onDispose(gate.dispose);
        return gate;
      }),
    ]));
    loads.single.complete('http://saved:1');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();

    final scope = scopeOf(tester);
    final session = scope.read(sessionServiceProvider);
    expect(session.serverBlocked.value, ServerBlockedReason.none);
    await tester.runAsync(() async {
      scope.read(onUnauthorizedProvider)(null); // no stamp: the identity read
      await pumpEventQueue();
    });
    expect(session.serverBlocked.value, ServerBlockedReason.signedOut);
    await teardownTree(tester);
  });
}
