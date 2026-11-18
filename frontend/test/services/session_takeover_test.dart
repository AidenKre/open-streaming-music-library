// signoff-8-logout-warning round 3 (user 2026-11-14): "Maybe we should save
// these changes and on log in (same user, same server) they are restored."
//
// After a rejected session the banner's Log in logs out KEEPING the unsent
// upload and deletion records (SessionService.logout(keepUnsent: true)).
// The next login decides, with the proof Phase M already uses to keep and
// send unsent plays and edits (SessionService._signIn: the same
// (instance, user) pair as the binding row):
//  * same user, same server: the new sign-in takes the records over (their
//    local_binding_id becomes the current token), nothing else changes and
//    nothing is sent by the login itself;
//  * another user, or another server: nothing is taken over; the user-switch
//    / different-server sheet counts the kept records among what it removes,
//    and its reset wipes them before the other sign-in is stored (SC-28).
// A deliberate Settings log-out still removes them (nothing to take over).
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/dead_sign_in_records.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';

const _alice = Credentials(
  token: 'tok-old',
  mediaToken: 'med-old',
  userId: 7,
  username: 'alice',
);

const _draft = '{"v":1,"edits":{"title":"Typed"}}';
const _source = '{"path":"/music/a.flac"}';

final _log = <String>[];

/// A removal that fails (review r3 #1: a discard whose removal failed).
class _FailingRemoval extends DeadSignInRecords {
  _FailingRemoval(AppDatabase db)
      : super(db: db, binding: ServerBindingRepository(db));
  @override
  Future<void> removeAllBut(String currentToken) async =>
      throw StateError('database is locked');
}

void main() {
  late AppDatabase db;
  late ControlledGate gate;
  late Directory dir;
  late FakeSecureBackend secure;
  late CredentialStore store;
  late String oldToken;

  // Who the server says logged in, and which server it is.
  late int loginUserId;
  late String loginUsername;
  late String loginInstance;

  setUp(() async {
    _log.clear();
    loginUserId = 7;
    loginUsername = 'alice';
    loginInstance = 'inst-1';
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    db = AppDatabase(NativeDatabase.memory());
    gate = ControlledGate(db, signedInUserId: 7);
    dir = await Directory.systemTemp.createTemp('osml-takeover-');
    secure = FakeSecureBackend();
    store = CredentialStore(secure: secure, directory: dir);
    await store.save(_alice);
    oldToken = await seedTestBinding(db,
        baseUrl: 'http://s', instanceId: 'inst-1', userId: 7);
  });

  tearDown(() async {
    gate.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  http.Client transport() => MockClient((req) async {
        _log.add('${req.method} ${req.url.path}');
        const json = {'content-type': 'application/json'};
        if ('${req.method} ${req.url.path}' == 'POST /auth/login') {
          return http.Response(
              jsonEncode({
                'token': 'tok-new',
                'media_token': 'med-new',
                'server_instance_id': loginInstance,
                'user': {
                  'id': loginUserId,
                  'username': loginUsername,
                  'is_admin': false,
                  'is_master_admin': false,
                },
              }),
              200,
              headers: json);
        }
        if ('${req.method} ${req.url.path}' == 'POST /auth/logout') {
          return http.Response('', 204);
        }
        return http.Response('{}', 200, headers: json);
      });

  /// The signed-in scope that logs out (A), or the Log in scope (B).
  ProviderContainer scope({
    bool signedIn = false,
    DeadSignInRecords? deadRecords,
  }) {
    final t = transport();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      httpClientProvider.overrideWithValue(t),
      sessionUrlProvider.overrideWithValue('http://s'),
      apiClientProvider.overrideWithValue(testApiClient('http://s', t)),
      unauthenticatedApiClientProvider
          .overrideWithValue((url) => testApiClient(url, t)),
      if (signedIn) credentialsProvider.overrideWithValue(_alice),
      credentialStoreProvider.overrideWithValue(store),
      serverBindingGateProvider.overrideWithValue(gate.gate),
      downloadDirectoryProvider.overrideWithValue(() async => dir),
      localQuiescablesProvider.overrideWithValue(const []),
      // The real database wipe, so a reset really removes the records.
      localResettablesProvider.overrideWithValue([db, store]),
      onSessionChangedProvider.overrideWithValue(() async {}),
      if (deadRecords != null)
        deadSignInRecordsProvider.overrideWithValue(deadRecords),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// Unsent work of alice's sign-in: a file mid-transfer (with its file
  /// reference and typed tags), a pending cancel, a deletion never sent and
  /// one the server may have received, plus the transfer's own submission.
  Future<void> seedUnsent() async {
    Future<void> intent(String item, String state, {String? draft}) =>
        db.customStatement(
          'INSERT INTO upload_intents (item_uuid, batch_uuid, selection_index, '
          'display_name, source_descriptor_json, expected_sha256, '
          'expected_length, last_state, transfer_operation_uuid, draft_json, '
          'local_binding_id, created_at, updated_at) VALUES '
          "(?, 'b-1', 0, 'a.flac', ?, 'abc', 3, ?, 'xfer-1', ?, ?, 1, 1)",
          [item, _source, state, draft, oldToken],
        );
    Future<void> submission(String op, String kind, String state, String body) =>
        db.customStatement(
          'INSERT INTO durable_submissions (operation_uuid, kind, '
          'local_binding_id, frozen_body_json, state, created_at, '
          'updated_at) VALUES (?, ?, ?, ?, ?, 1, 1)',
          [op, kind, oldToken, body, state],
        );
    await intent('u-1', 'transferring', draft: _draft);
    await intent('u-2', 'cancelling');
    await submission('xfer-1', 'upload_content', 'sent', '{}');
    await submission('del-1', 'track_deletion', 'prepared',
        '{"targets":[{"uuid_id":"a","base_revision":1}],"confirmed_count":1}');
    await submission('del-2', 'track_deletion', 'sent',
        '{"targets":[{"uuid_id":"b","base_revision":4}],"confirmed_count":1}');
  }

  Future<List<String>> tokens() async => [
        for (final r in await db
            .customSelect('SELECT local_binding_id AS t FROM upload_intents '
                'UNION ALL SELECT local_binding_id FROM durable_submissions')
            .get())
          r.read<String>('t'),
      ];

  Future<int> rows() async => (await tokens()).length;

  Future<String> current() async =>
      (await ServerBindingRepository(db).current())!.localBindingId;

  /// The banner's Log in after a rejected session: a log-out that keeps the
  /// unsent records.
  Future<void> sessionEndedLogOut() =>
      scope(signedIn: true).read(sessionServiceProvider).logout(keepUnsent: true);

  group('same user, same server', () {
    test('the new sign-in takes the kept records over, unchanged; the login '
        'sends nothing else', () async {
      await seedUnsent();
      await sessionEndedLogOut();
      expect(await rows(), 5, reason: 'kept on the device');
      expect((await tokens()).toSet(), {oldToken});
      final rotated = await current();
      expect(rotated, isNot(oldToken));
      _log.clear();

      final outcome =
          await scope().read(sessionServiceProvider).login('alice', 'pw');

      expect(outcome, isA<SignInSucceeded>());
      expect(_log, ['POST /auth/login']);
      final now = await current();
      expect(now, rotated, reason: 'the same-pair login keeps the row');
      expect((await tokens()).toSet(), {now},
          reason: 'every kept record belongs to the new sign-in');
      final u1 = (await db
              .customSelect("SELECT * FROM upload_intents WHERE item_uuid = 'u-1'")
              .getSingle())
          .data;
      expect(u1['last_state'], 'transferring');
      expect(u1['source_descriptor_json'], _source);
      expect(u1['expected_sha256'], 'abc');
      expect(u1['draft_json'], _draft);
      expect(u1['transfer_operation_uuid'], 'xfer-1');
      final states = {
        for (final r in await db
            .customSelect('SELECT operation_uuid AS o, state AS s '
                'FROM durable_submissions')
            .get())
          r.read<String>('o'): r.read<String>('s'),
      };
      expect(states, {'xfer-1': 'sent', 'del-1': 'prepared', 'del-2': 'sent'});
    });

    // Review r3 (crossing #1): only the records the session-ended log-out
    // kept are taken over. Records the user discarded (whose removal failed)
    // and leftovers of older sign-ins are removed, never sent.
    test('a discard whose removal failed is never taken over', () async {
      await seedUnsent();
      await scope(signedIn: true, deadRecords: _FailingRemoval(db))
          .read(sessionServiceProvider)
          .logout();
      expect(await rows(), 5, reason: 'the removal failed');
      final outcome =
          await scope().read(sessionServiceProvider).login('alice', 'pw');
      expect(outcome, isA<SignInSucceeded>());
      expect(await rows(), 0, reason: 'removed at the login, not taken over');
    });

    test('leftovers of an older sign-in are removed, the kept ones taken '
        'over', () async {
      await seedUnsent();
      await db.customStatement(
        'INSERT INTO durable_submissions (operation_uuid, kind, '
        'local_binding_id, frozen_body_json, state, created_at, updated_at) '
        "VALUES ('del-old', 'track_deletion', 'an-older-sign-in', '{}', "
        "'prepared', 1, 1)",
      );
      await sessionEndedLogOut();
      await scope().read(sessionServiceProvider).login('alice', 'pw');
      final now = await current();
      expect((await tokens()).toSet(), {now});
      expect(await rows(), 5, reason: 'del-old is gone');
    });

    // Review r3 (crossing #2): a login that stored the sign-in but did not
    // get to the take-over (the app was closed in between) is finished when
    // the stored sign-in resumes.
    test('a resumed stored sign-in takes the kept records over', () async {
      await seedUnsent();
      await sessionEndedLogOut();
      await store.save(_alice); // stored, but no take-over ran
      final c = scope(signedIn: true);
      await c.read(sessionServiceProvider).resumeSavedSession();
      expect((await tokens()).toSet(), {await current()});
    });

    test('after a Settings log-out there is nothing to take over', () async {
      await seedUnsent();
      await scope(signedIn: true).read(sessionServiceProvider).logout();
      expect(await rows(), 0, reason: 'discarded, as the sheet said');
      final outcome =
          await scope().read(sessionServiceProvider).login('alice', 'pw');
      expect(outcome, isA<SignInSucceeded>());
      expect(await rows(), 0);
    });
  });

  group('another user (SC-28)', () {
    setUp(() {
      loginUserId = 8;
      loginUsername = 'bob';
    });

    test('nothing is taken over; the user-switch sheet counts the kept '
        'records', () async {
      await seedUnsent();
      await sessionEndedLogOut();
      final b = scope();
      final outcome = await b.read(sessionServiceProvider).login('bob', 'pw');
      expect(outcome, isA<SignInNeedsUserSwitch>());
      expect((await tokens()).toSet(), {oldToken});
      expect(await current(), isNot(oldToken));
      expect(await store.read(), isNull, reason: 'bob is not stored yet');

      final losses = await b.read(sessionServiceProvider).pendingLossSummaries();
      expect(losses, contains('1 upload not yet sent'));
      expect(losses, contains('2 deletions not yet confirmed'));
    });

    test('confirming removes every kept record before bob is signed in',
        () async {
      await seedUnsent();
      await sessionEndedLogOut();
      final b = scope();
      await b.read(sessionServiceProvider).login('bob', 'pw');
      await b.read(sessionServiceProvider).confirmPendingSignIn();
      expect(await rows(), 0);
      final row = (await ServerBindingRepository(db).current())!;
      expect(row.userId, 8);
      expect((await store.read())!.userId, 8);
    });

    test('cancelling keeps them, still not taken over', () async {
      await seedUnsent();
      await sessionEndedLogOut();
      final b = scope();
      await b.read(sessionServiceProvider).login('bob', 'pw');
      await b.read(sessionServiceProvider).cancelPendingSignIn();
      expect((await tokens()).toSet(), {oldToken});
      expect(await current(), isNot(oldToken));
    });
  });

  group('another server', () {
    setUp(() => loginInstance = 'inst-2');

    test('nothing is taken over; the different-server sheet counts the kept '
        'records', () async {
      await seedUnsent();
      await sessionEndedLogOut();
      final b = scope();
      final outcome = await b.read(sessionServiceProvider).login('alice', 'pw');
      expect(outcome, isA<SignInDifferentServer>());
      expect((await tokens()).toSet(), {oldToken});
      final losses = await b.read(sessionServiceProvider).pendingLossSummaries();
      expect(losses, contains('1 upload not yet sent'));
      expect(losses, contains('2 deletions not yet confirmed'));
    });
  });
}
