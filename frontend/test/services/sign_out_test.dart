// Phase M §7.6 logout (M-U23) and Disconnect's revoke (§7.1).
//
// LocalResetService.signOut() is not a reset: no resetPending marker, no
// wipe. It bumps the generation, quiesces playback (admission first), then
// listens and history BEFORE ServerBindingRepository.rotate(), so the last
// listen's finalize lands and any later durable write from the old scope is
// a no-op; then it stops the gate, revokes the server session (best effort;
// a 401 means already logged out), deletes the stored credentials and keeps
// the saved URL. SessionService.logout then rebuilds the scope at Log in.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/dead_sign_in_records.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';
import '../helpers/test_credentials.dart';

final _events = <String>[];

class _Quiesce implements Quiescable {
  _Quiesce(this.quiesceName);
  @override
  final String quiesceName;
  @override
  Future<void> quiesce() async => _events.add('quiesce $quiesceName');
}

class _SpyRepo extends ServerBindingRepository {
  _SpyRepo(super.db);
  @override
  Future<ServerBindingRecord?> rotate() {
    _events.add('rotate');
    return super.rotate();
  }

  @override
  Future<void> fence() {
    _events.add('fence');
    return super.fence();
  }
}

class _FailingFence extends ServerBindingRepository {
  _FailingFence(super.db);
  @override
  Future<void> fence() async => throw StateError('disk I/O error');
}

class _SpyStore extends CredentialStore {
  _SpyStore(Directory dir, {FakeSecureBackend? secure})
      : super(secure: secure ?? FakeSecureBackend(), directory: dir);
  @override
  Future<void> delete() async {
    _events.add('store.delete');
    await super.delete();
  }
}

class _SpyDeadRecords extends DeadSignInRecords {
  _SpyDeadRecords(AppDatabase db, {this.fail = false})
      : _repo = ServerBindingRepository(db),
        super(db: db, binding: ServerBindingRepository(db));
  final ServerBindingRepository _repo;
  final bool fail;
  @override
  Future<void> removeAllBut(String currentToken) async {
    final current = (await _repo.current())?.localBindingId;
    _events.add('remove dead records '
        '${currentToken == current ? '(current token)' : '(other token)'}');
    if (fail) throw StateError('database is locked');
    await super.removeAllBut(currentToken);
  }
}

class _Wipe implements LocalResettable {
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async => _events.add('wipe');
}

void main() {
  late AppDatabase db;
  late ControlledGate controlled;
  late Directory dir;
  late _SpyStore store;
  late Future<http.Response> Function(http.Request) server;

  setUp(() async {
    _events.clear();
    SharedPreferences.setMockInitialValues(
        {'serverUrl': 'http://s', 'settings.x': 'A'});
    db = AppDatabase(NativeDatabase.memory());
    controlled = ControlledGate(db);
    dir = await Directory.systemTemp.createTemp('osml-signout-');
    store = _SpyStore(dir);
    await store.save(testCredentials);
    server = (_) async => http.Response('', 204);
  });

  tearDown(() async {
    controlled.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  /// A signed-in scope whose real apiClientProvider carries the token.
  ProviderContainer scope({
    bool signedIn = true,
    ServerBindingRepository? repository,
    DeadSignInRecords? deadRecords,
    SessionEventLogFile? sessionLog,
  }) {
    final transport = MockClient((req) async {
      final auth = req.headers['Authorization'];
      _events.add('${req.method} ${req.url.path}'
          '${auth == null ? '' : ' [$auth]'}');
      return server(req);
    });
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      httpClientProvider.overrideWithValue(transport),
      sessionUrlProvider.overrideWithValue('http://s'),
      if (signedIn) credentialsProvider.overrideWithValue(testCredentials),
      credentialStoreProvider.overrideWithValue(store),
      serverBindingRepositoryProvider
          .overrideWithValue(repository ?? _SpyRepo(db)),
      serverBindingGateProvider.overrideWithValue(controlled.gate),
      localQuiescablesProvider.overrideWithValue([
        _Quiesce('playback'),
        _Quiesce('listens'),
        _Quiesce('history'),
      ]),
      localResettablesProvider.overrideWithValue([_Wipe(), store]),
      onSessionChangedProvider
          .overrideWithValue(() async => _events.add('onSessionChanged')),
      if (deadRecords != null)
        deadSignInRecordsProvider.overrideWithValue(deadRecords),
      if (sessionLog != null)
        sessionEventLogFileProvider.overrideWithValue(sessionLog),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  ServerBindingRepository repo() => ServerBindingRepository(db);

  /// Every recorded request that carried the session token (any path).
  Iterable<String> tokenRequests() =>
      _events.where((e) => e.contains('[Bearer ${testCredentials.token}]'));

  /// The session's connection verified against the bound server: the only
  /// state in which a revoke may carry the token (review F2).
  Future<void> verify(String instanceId) async {
    final done = controlled.gate.startConnection('http://s');
    await pumpEventQueue();
    controlled.respond(instanceId);
    await done;
  }

  Future<String> seedRow() async {
    final token = await seedTestBinding(db,
        baseUrl: 'http://s', instanceId: 'inst-1');
    await db.customStatement(
      'INSERT INTO pending_edits (uuid_id, values_json, write_mode, status, '
      "updated_at) VALUES ('a', '{}', 'db_only', 'pending', 1)",
    );
    return token;
  }

  group('LocalResetService.signOut', () {
    test('quiesces playback, listens and history before rotating; then stops '
        'the gate, revokes and deletes the credentials', () async {
      await seedRow();
      await verify('inst-1');
      final c = scope();
      await c.read(localResetServiceProvider).signOut();
      expect(_events, [
        'quiesce playback',
        'quiesce listens',
        'quiesce history',
        'rotate',
        'POST /auth/logout [Bearer ${testCredentials.token}]',
        'store.delete',
      ]);
      await expectLater(controlled.gate.awaitVerified(),
          throwsA(isA<BindingGateClosedException>()),
          reason: 'the gate is closed for the rest of this scope');
    });

    test('bumps the in-memory generation', () async {
      await seedRow();
      final c = scope();
      final resets = c.read(localResetServiceProvider);
      final before = resets.generation;
      await resets.signOut();
      expect(resets.generation, greaterThan(before));
    });

    test('is not a reset: no marker, no wipe, every local store kept, the '
        'URL kept', () async {
      await seedRow();
      final c = scope();
      await c.read(localResetServiceProvider).signOut();
      expect(_events, isNot(contains('wipe')));
      expect(_events, isNot(contains('fence')));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(LocalResetService.resetPendingKey), isNull);
      expect(prefs.getString('serverUrl'), 'http://s');
      expect(prefs.getString('settings.x'), 'A');
      final n = (await db
              .customSelect('SELECT COUNT(*) AS n FROM pending_edits')
              .getSingle())
          .read<int>('n');
      expect(n, 1, reason: 'unsent edits stay for the next same-user login');
      final row = (await repo().current())!;
      expect(row.userId, testUserId);
      expect(row.instanceId, 'inst-1');
      expect(await store.read(), isNull);
    });

    test("a late durable write from the old scope is dropped", () async {
      final oldToken = await seedRow();
      final c = scope();
      await c.read(localResetServiceProvider).signOut();
      await expectLater(
        repo().runFenced(oldToken, () async {}),
        throwsA(isA<BindingFencedException>()),
      );
    });

    test('a 401 on the revoke means already logged out: still signed out',
        () async {
      await seedRow();
      server = (_) async => http.Response(
          '{"detail":{"error":"invalid_token","message":"x"}}', 401);
      final c = scope();
      await c.read(localResetServiceProvider).signOut();
      expect(await store.read(), isNull);
    });

    test('an unreachable server still signs out locally', () async {
      await seedRow();
      server = (_) async => throw const SocketException('down');
      final c = scope();
      await c.read(localResetServiceProvider).signOut();
      expect(await store.read(), isNull);
      expect(_events, contains('rotate'));
    });
  });

  // signoff-8-logout-warning (DEV-7-22, DEV-8-14): the warning counts the
  // current sign-in's unsent work before the token changes; counting
  // changes nothing.
  // Sign-off s7-app-texts item 2: log-out wipes no local store, so the
  // session log file stays, whether the unsent changes are kept or not
  // (only a reset removes it).
  group('log-out keeps the session log file', () {
    for (final keep in [false, true]) {
      test(keep ? 'keeping the unsent changes' : 'discarding them', () async {
        await seedRow();
        final log = SessionEventLogFile(dir);
        await log.append('Stored sign-in dropped at launch: reason=x');
        await scope(deadRecords: _SpyDeadRecords(db), sessionLog: log)
            .read(sessionServiceProvider)
            .logout(keepUnsent: keep);
        await log.idle();
        expect(log.file.existsSync(), isTrue);
        expect(await log.file.readAsLines(), hasLength(1));
      });
    }
  });

  group('SessionService.pendingLogoutLosses', () {
    test('counts this sign-in\'s unsent work and changes nothing', () async {
      final token = await seedRow();
      await db.customStatement(
        'INSERT INTO upload_intents (item_uuid, batch_uuid, selection_index, '
        'display_name, expected_sha256, last_state, local_binding_id, '
        "created_at, updated_at) VALUES ('u-1', 'b-1', 0, 'a.flac', 'abc', "
        "'transferring', ?, 1, 1)",
        [token],
      );
      final c = scope();
      final losses = await c.read(sessionServiceProvider).pendingLogoutLosses();
      expect(losses.unsentUploads, 1);
      expect(losses.unconfirmedDeletions, 0);
      expect(_events, isEmpty, reason: 'no quiesce, rotate or revoke');
      expect((await repo().current())!.localBindingId, token);
      expect(await store.read(), isNotNull);
    });

    test('a counter that cannot be built is unknown, never nothing to lose',
        () async {
      await seedRow();
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          logoutLossCounterProvider
              .overrideWith((ref) => throw StateError('database is locked')),
        ],
      );
      addTearDown(c.dispose);
      final losses = await c.read(sessionServiceProvider).pendingLogoutLosses();
      expect(losses.unsentUploads, isNull);
      expect(losses.unconfirmedDeletions, isNull);
      expect(losses.isEmpty, isFalse);
    });
  });

  // signoff-8-logout-warning (DEV-7-22, DEV-8-14): after the token changes,
  // the upload and deletion records of earlier sign-ins are never sent, so
  // log-out removes them; nothing on the server is touched (no request), and
  // plays, edits and pending file clean-ups keep their behaviour.
  group('log-out removes the dead upload and deletion records', () {
    Future<int> rows(String table) async => (await db
            .customSelect('SELECT COUNT(*) AS n FROM $table')
            .getSingle())
        .read<int>('n');

    Future<void> intent(String uuid, String token) => db.customStatement(
          'INSERT INTO upload_intents (item_uuid, batch_uuid, '
          'selection_index, display_name, expected_sha256, last_state, '
          'draft_json, local_binding_id, created_at, updated_at) VALUES '
          "(?, 'b-1', 0, 'a.flac', 'abc', 'transferring', "
          "'{\"v\":1,\"edits\":{\"title\":\"T\"}}', ?, 1, 1)",
          [uuid, token],
        );

    Future<void> submission(
      String op,
      String kind,
      String state,
      String token,
    ) =>
        db.customStatement(
          'INSERT INTO durable_submissions (operation_uuid, kind, '
          'local_binding_id, frozen_body_json, state, created_at, '
          "updated_at) VALUES (?, ?, ?, '{}', ?, 1, 1)",
          [op, kind, token, state],
        );

    test('every upload intent and submission of an earlier sign-in is '
        'removed; plays, edits and file clean-ups stay', () async {
      final oldToken = await seedRow();
      await intent('u-1', oldToken);
      await intent('u-0', 'an-older-sign-in');
      await submission('op-1', 'track_deletion', 'prepared', oldToken);
      await submission('op-2', 'upload_allocation', 'accepted', oldToken);
      await submission('op-3', 'upload_commit', 'ambiguous', oldToken);
      await submission('op-0', 'track_deletion', 'sent', 'an-older-sign-in');
      await db.customStatement(
        'INSERT INTO history_events (event_uuid, kind, entity_type, '
        "entity_ref, occurred_at, pending_upload) VALUES ('e-1', 'play', "
        "'track', 't-1', 1, 1)",
      );
      await db.customStatement(
        'INSERT INTO owned_file_cleanup (path, root_kind, local_binding_id, '
        "created_at) VALUES ('/d/a.flac', 'downloads', ?, 1)",
        [oldToken],
      );

      await scope().read(localResetServiceProvider).signOut();

      expect(await rows('upload_intents'), 0);
      expect(await rows('durable_submissions'), 0);
      expect(await rows('pending_edits'), 1, reason: 'edits are kept');
      expect(await rows('history_events'), 1, reason: 'plays are kept');
      expect(await rows('owned_file_cleanup'), 1,
          reason: 'pending file clean-ups are kept');
      expect(
        _events.where((e) => e.startsWith('POST') || e.startsWith('DELETE')),
        isEmpty,
        reason: 'never verified: nothing is sent, nothing on the server '
            'is cancelled or deleted',
      );
    });

    // Round 3 (user 2026-11-14): the signed-out banner's Log in keeps them
    // for the same user's next login.
    test('a log-out that keeps the unsent changes removes nothing',
        () async {
      final oldToken = await seedRow();
      await intent('u-1', oldToken);
      await submission('op-1', 'track_deletion', 'prepared', oldToken);
      await scope(deadRecords: _SpyDeadRecords(db))
          .read(sessionServiceProvider)
          .logout(keepUnsent: true);
      expect(_events, contains('rotate'), reason: 'still fenced');
      expect(_events.where((e) => e.startsWith('remove dead records')),
          isEmpty);
      expect(await rows('upload_intents'), 1);
      expect(await rows('durable_submissions'), 1);
      expect(await store.read(), isNull, reason: 'still signed out');
    });

    test('removed under the new token, after the rotate', () async {
      await seedRow();
      await scope(deadRecords: _SpyDeadRecords(db))
          .read(localResetServiceProvider)
          .signOut();
      expect(
        _events.indexOf('remove dead records (current token)'),
        greaterThan(_events.indexOf('rotate')),
      );
    });

    test('a removal that fails does not stop the log-out', () async {
      final oldToken = await seedRow();
      await intent('u-1', oldToken);
      await scope(deadRecords: _SpyDeadRecords(db, fail: true))
          .read(localResetServiceProvider)
          .signOut();
      expect(_events, contains('rotate'));
      expect(_events, contains('store.delete'));
      expect(await store.read(), isNull);
      expect(await rows('upload_intents'), 1, reason: 'left dead, as before');
    });

    test("keeps the current sign-in's rows; a stale token removes nothing",
        () async {
      final current = await seedRow();
      await intent('u-1', current);
      await intent('u-0', 'an-older-sign-in');
      await submission('op-1', 'track_deletion', 'prepared', current);
      await submission('op-0', 'track_deletion', 'prepared', 'an-older-sign-in');
      final records = DeadSignInRecords(db: db, binding: repo());

      await expectLater(
        records.removeAllBut('an-older-sign-in'),
        throwsA(isA<BindingFencedException>()),
      );
      expect(await rows('upload_intents'), 2);
      expect(await rows('durable_submissions'), 2);

      await records.removeAllBut(current);
      final left = await db
          .customSelect('SELECT local_binding_id AS t FROM upload_intents '
              'UNION ALL SELECT local_binding_id FROM durable_submissions')
          .get();
      expect([for (final r in left) r.read<String>('t')], [current, current]);
    });
  });

  group('SessionService.logout', () {
    test('signs out, then rebuilds the scope; the next launch is Log in',
        () async {
      await seedRow();
      final c = scope();
      await c.read(sessionServiceProvider).logout();
      expect(_events.last, 'onSessionChanged');
      expect(_events.indexOf('store.delete'),
          lessThan(_events.indexOf('onSessionChanged')));

      // The rebuilt scope: the URL is kept and there are no credentials,
      // also when the server cannot be reached.
      server = (_) async => throw const SocketException('down');
      final next = scope(signedIn: false);
      final start =
          await next.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
    });
  });

  // Review r1 m-R1-07: the secure delete AND the signed-out marker write
  // both fail. Logout still ends at Log in for this run (in-memory signed
  // out), says the stored sign-in could not be removed, and a second logout
  // (the signed-out banner's Log in) does not loop.
  group('logout when the stored sign-in cannot be cleared', () {
    late FakeSecureBackend secure;

    setUp(() async {
      final blocker = File('${dir.path}/not-a-directory')..writeAsStringSync('x');
      secure = FakeSecureBackend();
      store = _SpyStore(Directory(blocker.path), secure: secure);
      await store.save(testCredentials);
      secure.deleteError = StateError('keychain delete failed');
    });

    test('signOut reports the credential store and still rotated, closed the '
        'gate and revoked', () async {
      await seedRow();
      final c = scope();
      await verify('inst-1');
      final error = await c
          .read(localResetServiceProvider)
          .signOut()
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<LocalResetException>());
      expect(
        (error! as LocalResetException).failures.map((f) => f.subsystem),
        contains(CredentialStore),
      );
      expect(_events, contains('rotate'));
      expect(_events.where((e) => e.startsWith('POST /auth/logout')), hasLength(1));
      await expectLater(controlled.gate.awaitVerified(),
          throwsA(isA<BindingGateClosedException>()));
    });

    test('logout rethrows, still rebuilds, and the next scope opens at Log in '
        'saying the sign-in could not be removed', () async {
      await seedRow();
      final c = scope();
      await expectLater(c.read(sessionServiceProvider).logout(), throwsA(anything));
      expect(_events.last, 'onSessionChanged');

      // This run reads signed out although the keychain still holds it.
      expect(await store.read(), isNull);
      expect(secure.values, isNotEmpty);
      final next = scope(signedIn: false);
      final start = await next.read(sessionServiceProvider).resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
      expect(start.error, isNotNull,
          reason: 'the user is told the stored sign-in could not be removed');
    });

    // Review r2 m-R2-10: the keychain still holds the sign-in, and the next
    // launch (a new process, no in-memory "signed out") reads it. If the
    // revoke never ran (offline, or never verified) that launch signs the
    // user back in. The notice says so instead of promising a cleanup.
    test('the notice says the next start may sign you back in, which it can',
        () async {
      await seedRow();
      await expectLater(scope().read(sessionServiceProvider).logout(),
          throwsA(anything));
      expect(_events.where((e) => e.contains('/auth/logout')), isEmpty,
          reason: 'never verified: the server session was not revoked');
      final start = await scope(signedIn: false)
          .read(sessionServiceProvider)
          .resumeSavedSession();
      expect(
        start.error,
        'You are logged out, but your sign-in could not be removed from this '
        "device's storage. The next time the app starts, it may find it and "
        'sign you in again; if it does, log out again.',
      );
      final nextProcess = CredentialStore(
          secure: secure, directory: Directory('${dir.path}/not-a-directory'));
      expect(await nextProcess.read(), testCredentials,
          reason: 'the next launch still finds the sign-in');
    });

    test("the signed-out banner's Log in (a second logout) ends at Log in too",
        () async {
      await seedRow();
      await expectLater(scope().read(sessionServiceProvider).logout(),
          throwsA(anything));
      _events.clear();
      await expectLater(scope().read(sessionServiceProvider).logout(),
          throwsA(anything));
      expect(_events.last, 'onSessionChanged');
      final start = await scope(signedIn: false)
          .read(sessionServiceProvider)
          .resumeSavedSession();
      expect(start.kind, SessionStartKind.logIn);
    });
  });

  // Review F1: logout closes the gate for good, so no recovery edge can
  // restart it and hand the rotated token to old-scope runners.
  test('after signOut the gate never verifies again in this scope', () async {
    await seedRow();
    await verify('inst-1');
    final c = scope();
    await c.read(localResetServiceProvider).signOut();
    unawaited(controlled.gate.startConnection('http://s')); // appResume edge
    await pumpEventQueue();
    expect(controlled.pendingProbes, 0);
    expect(controlled.gate.state, isNot(isA<BindingVerified>()));
  });

  // Review F2: the token only goes to the server the gate verified; never to
  // a different instance found at the saved URL, nor unverified.
  group('the revoke goes only to the verified server', () {
    test('logout while blocked on a different server sends nothing', () async {
      await seedRow();
      await verify('inst-2'); // a different server answers at the saved URL
      expect(controlled.gate.state, isA<BindingDifferentServer>());
      final c = scope();
      await c.read(localResetServiceProvider).signOut();
      expect(_events.where((e) => e.contains('/auth/logout')), isEmpty);
      expect(await store.read(), isNull, reason: 'still signed out locally');
    });

    test('Reset on the blocked banner sends nothing', () async {
      await seedRow();
      await verify('inst-2');
      final c = scope();
      await c.read(sessionServiceProvider).resetForBlockedServer();
      expect(_events.where((e) => e.contains('/auth/logout')), isEmpty);
    });

    // Review r1 m-R1-19: a re-verify in flight (app resume, network
    // recovered) or a failed re-probe does not forget that this scope
    // already verified the same server: the session is still revoked, once,
    // to the scope's own URL. Server sessions never expire.
    group('after this scope verified the server', () {
      Future<void> reverifyInFlight() async {
        unawaited(controlled.gate.startConnection('http://s'));
        await pumpEventQueue();
        expect(controlled.gate.state, isA<BindingVerifying>());
      }

      test('logout during a re-verify still revokes', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reverifyInFlight();
        await c.read(localResetServiceProvider).signOut();
        expect(
            _events.where((e) =>
                e == 'POST /auth/logout [Bearer ${testCredentials.token}]'),
            hasLength(1));
      });

      // Review r2 m-R2-09 (coordinator decision): a failed check means the
      // host at the URL is in doubt, so nothing is sent; the server session
      // then stays (a logged open item). This test said "still revokes"
      // until r2.
      test('logout after a failed re-probe sends nothing', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reverifyInFlight();
        controlled.fail(const SocketException('down'));
        await pumpEventQueue();
        expect(controlled.gate.state, isA<BindingUnverified>());
        await c.read(localResetServiceProvider).signOut();
        expect(tokenRequests(), isEmpty);
        expect(await store.read(), isNull, reason: 'still signed out locally');
      });

      // Review r2 m-R2-09: a host that answers without an instance id is not
      // our server; the token must never reach it.
      Future<void> reprobeAnswersWithoutInstanceId() async {
        await reverifyInFlight();
        controlled.respond(null);
        await pumpEventQueue();
        expect(controlled.gate.state, isA<BindingUnverified>());
      }

      test('logout after a re-probe that reports no instance id sends no '
          'request with the token', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reprobeAnswersWithoutInstanceId();
        await c.read(sessionServiceProvider).logout();
        expect(tokenRequests(), isEmpty);
        expect(await store.read(), isNull, reason: 'still signed out locally');
      });

      test('Disconnect after a re-probe that reports no instance id sends no '
          'request with the token', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reprobeAnswersWithoutInstanceId();
        await c.read(sessionServiceProvider).resetLocalData();
        expect(tokenRequests(), isEmpty);
        expect(_events, contains('wipe'));
      });

      test('a failed re-probe is not forgotten by the retry in flight',
          () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reprobeAnswersWithoutInstanceId();
        await reverifyInFlight(); // the next attempt is probing again
        await c.read(localResetServiceProvider).signOut();
        expect(tokenRequests(), isEmpty);
      });

      test('verified again after a failure revokes again', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reprobeAnswersWithoutInstanceId();
        await verify('inst-1');
        await c.read(localResetServiceProvider).signOut();
        expect(tokenRequests(), hasLength(1));
      });

      test('Disconnect during a re-verify still revokes', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reverifyInFlight();
        await c.read(sessionServiceProvider).resetLocalData();
        expect(_events.where((e) => e.startsWith('POST /auth/logout')),
            hasLength(1));
      });

      test('a different server answering since then sends nothing', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        await reverifyInFlight();
        controlled.respond('inst-2');
        await pumpEventQueue();
        expect(controlled.gate.state, isA<BindingDifferentServer>());
        await c.read(localResetServiceProvider).signOut();
        expect(_events.where((e) => e.contains('/auth/logout')), isEmpty);
      });
    });

    // Review s7-session-network F1 (sign-off OPEN-M-11): after an outage the
    // host at the saved address is in doubt too (a network switch can put
    // another host there), so the revoke is not sent while offline.
    for (final (name, act) in [
      ('logout', (ProviderContainer c) =>
          c.read(localResetServiceProvider).signOut()),
      ('Disconnect', (ProviderContainer c) =>
          c.read(sessionServiceProvider).resetLocalData()),
    ]) {
      test('$name while offline sends nothing', () async {
        await seedRow();
        final c = scope();
        await verify('inst-1');
        expect(controlled.gate.state, isA<BindingVerified>());
        c.read(offlineModeProvider.notifier)
          ..enterOffline()
          ..cancelOfflinePolling();
        await act(c);
        expect(_events.where((e) => e.contains('/auth/logout')), isEmpty);
      });
    }

    test('an unverified connection sends nothing', () async {
      await seedRow();
      final c = scope();
      await c.read(localResetServiceProvider).signOut();
      expect(_events.where((e) => e.contains('/auth/logout')), isEmpty);
    });

    // Review r2 m-R2-09 (design D-04): what counts is the URL the gate
    // verified, not just its state. A connection verified at another URL
    // proves nothing about the scope's own server.
    test('a gate verified at another URL than the scope client sends nothing',
        () async {
      await seedRow();
      final c = scope();
      final done = controlled.gate.startConnection('http://elsewhere');
      await pumpEventQueue();
      controlled.respond('inst-1');
      await done;
      expect(controlled.gate.state, isA<BindingVerified>());
      await c.read(localResetServiceProvider).signOut();
      expect(tokenRequests(), isEmpty);
    });
  });

  group('Disconnect also revokes (best effort)', () {
    // Review F3: the revoke runs inside the reset, after the fence and the
    // quiesce (old-scope runners are stopped) and before the wipe.
    test('the session is revoked after the fence and quiesce, before the wipe',
        () async {
      await seedRow();
      await verify('inst-1');
      final c = scope();
      final failure = await c.read(sessionServiceProvider).resetLocalData();
      expect(failure, isNull);
      final revoke = _events
          .indexOf('POST /auth/logout [Bearer ${testCredentials.token}]');
      expect(revoke, greaterThan(_events.indexOf('fence')));
      expect(revoke, greaterThan(_events.indexOf('quiesce history')));
      expect(revoke, lessThan(_events.indexOf('wipe')));
      expect(_events.indexOf('fence'), greaterThanOrEqualTo(0));
      expect(await store.read(), isNull);
    });

    test('an aborted reset (the fence failed) revokes nothing', () async {
      await seedRow();
      await verify('inst-1');
      final c = scope(repository: _FailingFence(db));
      await c.read(sessionServiceProvider).resetLocalData();
      expect(_events.where((e) => e.contains('/auth/logout')), isEmpty);
      expect(await store.read(), testCredentials,
          reason: 'still signed in: nothing was reset');
    });

    test('a failed revoke does not stop the reset', () async {
      await seedRow();
      server = (_) async => throw const SocketException('down');
      final c = scope();
      await c.read(sessionServiceProvider).resetLocalData();
      expect(_events, contains('wipe'));
    });

    test('without credentials nothing is revoked', () async {
      await seedRow();
      final c = scope(signedIn: false);
      await c.read(sessionServiceProvider).resetLocalData();
      expect(_events.where((e) => e.contains('/auth/logout')), isEmpty);
      expect(_events, contains('wipe'));
    });
  });
}
