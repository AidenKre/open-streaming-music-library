// Review r1 m-R1-37, spec 7.6 (M-U23): "Unsent plays and edits stay queued,
// and go out at the next same-user login" and "playback restore works".
//
// One database, one credential store and one request log across four scopes,
// driven through the real model:
//   A  signed in as user 7 with a queued metadata edit, a queued play and a
//      saved queue;
//   logout (SessionService.logout -> LocalResetService.signOut): binding
//      rotated, credentials deleted, nothing sent but the revoke;
//   B  the Log in scope: SessionService.login as the same user (the same
//      pair), no wipe;
//   C  the rebuilt scope with the stored credentials: its gate verifies,
//      then the edit outbox and one history pass send the queued work with
//      the NEW token, and the saved queue reads back.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/app_info.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/models/history_event.dart';
import 'package:frontend/models/metadata_edit.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/queue_repository.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/app_info_service.dart';
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/edit_outbox.dart';
import 'package:frontend/services/history/history_providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_secure_backend.dart';
import '../helpers/server_binding.dart';

const _oldCredentials = Credentials(
  token: 'tok-old',
  mediaToken: 'med-old',
  userId: 7,
  username: 'alice',
);

/// Every request the model sends, as "METHOD /path [Authorization]", plus
/// "wipe" markers: one ordered log.
final _log = <String>[];

class _OfflineOff extends OfflineModeNotifier {
  @override
  bool build() {
    super.build();
    return false;
  }
}

class _Wipe implements LocalResettable {
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async => _log.add('wipe');
}

Future<void> _seedTrack(AppDatabase db) async {
  await db.customStatement(
    'INSERT INTO tracks (uuid_id, created_at, last_updated, revision) '
    "VALUES ('u1', 0, 0, 5)",
  );
  await db.customStatement(
    'INSERT INTO trackmetadata (uuid_id, title, artist, album, duration, '
    'bitrate_kbps, sample_rate_hz, channels, has_album_art) '
    "VALUES ('u1', 'Old', 'OldA', 'OldAlb', 1, 1, 1, 2, 0)",
  );
  final rowid = (await db
          .customSelect("SELECT rowid AS r FROM trackmetadata WHERE uuid_id = 'u1'")
          .getSingle())
      .read<int>('r');
  await db.customStatement(
    'INSERT INTO fts_tracks(rowid, title, artist_name, album_name) '
    "VALUES (?, 'Old', 'OldA', 'OldAlb')",
    [rowid],
  );
}

void main() {
  late AppDatabase db;
  late ControlledGate gateA;
  late ControlledGate gateC;
  late Directory dir;
  late FakeSecureBackend secure;
  late CredentialStore store;
  late int rebuilds;

  setUp(() async {
    _log.clear();
    rebuilds = 0;
    SharedPreferences.setMockInitialValues({'serverUrl': 'http://s'});
    db = AppDatabase(NativeDatabase.memory());
    gateA = ControlledGate(db, signedInUserId: 7);
    gateC = ControlledGate(db, signedInUserId: 7);
    dir = await Directory.systemTemp.createTemp('osml-relogin-');
    secure = FakeSecureBackend();
    store = CredentialStore(secure: secure, directory: dir);
    await store.save(_oldCredentials);
  });

  tearDown(() async {
    gateA.dispose();
    gateC.dispose();
    await db.close();
    await dir.delete(recursive: true);
  });

  http.Client transport() => MockClient((req) async {
        final auth = req.headers['Authorization'];
        _log.add('${req.method} ${req.url.path}'
            '${auth == null ? '' : ' [$auth]'}');
        const json = {'content-type': 'application/json'};
        switch ('${req.method} ${req.url.path}') {
          case 'POST /auth/login':
            return http.Response(
                jsonEncode({
                  'token': 'tok-new',
                  'media_token': 'med-new',
                  'server_instance_id': 'inst-1',
                  'user': {
                    'id': 7,
                    'username': 'alice',
                    'is_admin': false,
                    'is_master_admin': false,
                  },
                }),
                200,
                headers: json);
          case 'POST /auth/logout':
            return http.Response('', 204);
          case 'PATCH /tracks/u1':
            return http.Response(
                jsonEncode(
                    {'uuid_id': 'u1', 'revision': 6, 'master_written': false}),
                200,
                headers: json);
          case 'POST /history':
            final events = (jsonDecode(req.body)['events'] as List)
                .map((e) => (e as Map)['event_uuid'] as String)
                .toList();
            return http.Response(jsonEncode({'acknowledged': events}), 200,
                headers: json);
          case 'GET /history/changes':
            return http.Response(
                jsonEncode(
                    {'events': [], 'nextCursor': null, 'latestRevision': 0}),
                200,
                headers: json);
        }
        return http.Response('{}', 200, headers: json);
      });

  /// A scope with real credentials (A before logout, C after the rebuild).
  ProviderContainer signedInScope(Credentials credentials, ControlledGate gate) {
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      httpClientProvider.overrideWithValue(transport()),
      sessionUrlProvider.overrideWithValue('http://s'),
      credentialsProvider.overrideWithValue(credentials),
      credentialStoreProvider.overrideWithValue(store),
      serverBindingGateProvider.overrideWithValue(gate.gate),
      localQuiescablesProvider.overrideWithValue(const []),
      localResettablesProvider.overrideWithValue([_Wipe(), store]),
      offlineModeProvider.overrideWith(_OfflineOff.new),
      appInfoProvider
          .overrideWith((ref) async => const AppInfo(features: FeatureBlocks(history: HistoryFeature(version: 1)))),
      onSessionChangedProvider.overrideWithValue(() async => rebuilds++),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// The Log in scope: a saved URL, no credentials, login through the
  /// unhooked client.
  ProviderContainer logInScope() {
    final t = transport();
    final c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      apiClientProvider.overrideWithValue(testApiClient('http://s', t)),
      unauthenticatedApiClientProvider
          .overrideWithValue((url) => testApiClient(url, t)),
      serverBindingGateProvider.overrideWithValue(gateA.gate),
      credentialStoreProvider.overrideWithValue(store),
      downloadDirectoryProvider.overrideWithValue(() async => dir),
      localQuiescablesProvider.overrideWithValue(const []),
      localResettablesProvider.overrideWithValue([_Wipe(), store]),
      onSessionChangedProvider.overrideWithValue(() async => rebuilds++),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> verify(ControlledGate gate) async {
    final done = gate.gate.startConnection('http://s');
    await pumpEventQueue();
    gate.respond('inst-1');
    await done;
  }

  Future<int> count(String sql) async =>
      (await db.customSelect(sql).getSingle()).read<int>('n');
  Future<int> pendingEdits() =>
      count('SELECT COUNT(*) AS n FROM pending_edits');
  Future<int> unsentPlays() => count(
      'SELECT COUNT(*) AS n FROM history_events WHERE pending_upload = 1');
  Future<int> queueItems() =>
      count('SELECT COUNT(*) AS n FROM queue_session_items');

  test('logout, same-user login, then the queued edit and play go out with '
      'the new token and the saved queue reads back', () async {
    // --- Scope A: signed in, with unsent work and a saved queue. ---
    final bindingA = await seedTestBinding(db,
        baseUrl: 'http://s', instanceId: 'inst-1', userId: 7);
    await _seedTrack(db);
    final a = signedInScope(_oldCredentials, gateA);
    await verify(gateA);
    await a.read(editOutboxProvider).enqueue(
          uuidId: 'u1',
          edit: const MetadataEdit.empty().set('title', 'New'),
          writeMode: EditWriteMode.dbOnly,
          baseRevision: 5,
        );
    await a.read(historyRepositoryProvider).insertLocal(
          bindingA,
          HistoryEventPayload(
            eventUuid: 'play-1',
            kind: 'play',
            entityType: 'track',
            entityRef: 'u1',
            occurredAt: 1000,
            secondsPlayed: 30.5,
          ),
        );
    final sessionId = await QueueRepository(db).createSessionFromExplicitList(
      sourceType: 'search',
      trackUuids: const ['u1'],
    );
    expect(await pendingEdits(), 1);
    expect(await unsentPlays(), 1);
    expect(await queueItems(), 1);
    _log.clear();

    // --- Logout. ---
    await a.read(sessionServiceProvider).logout();
    expect(_log, ['POST /auth/logout [Bearer tok-old]'],
        reason: 'only the revoke is sent: no edit, no play');
    expect(rebuilds, 1);
    expect(secure.values, isEmpty, reason: 'the credentials are deleted');
    final rotated = (await ServerBindingRepository(db).current())!;
    expect(rotated.localBindingId, isNot(bindingA), reason: 'rotated');
    expect(rotated.userId, 7, reason: 'the row still belongs to user 7');
    expect(await pendingEdits(), 1);
    expect(await unsentPlays(), 1);
    expect(await queueItems(), 1);
    _log.clear();

    // --- Scope B: the same user logs in again (the same pair). ---
    final b = logInScope();
    final outcome =
        await b.read(sessionServiceProvider).login('alice', 'pw-alice-1');
    expect(outcome, isA<SignInSucceeded>());
    expect(_log, ['POST /auth/login'],
        reason: 'no wipe, nothing else sent');
    expect(rebuilds, 2);
    final relogged = (await ServerBindingRepository(db).current())!;
    expect(relogged.localBindingId, rotated.localBindingId,
        reason: 'the same-pair login keeps the row');
    expect(await pendingEdits(), 1);
    expect(await unsentPlays(), 1);
    expect(await queueItems(), 1);
    _log.clear();

    // --- Scope C: the next launch reads what was stored. ---
    final stored =
        await CredentialStore(secure: secure, directory: dir).read();
    expect(stored, isNotNull);
    expect(stored!.token, 'tok-new');
    final c = signedInScope(stored, gateC);
    await verify(gateC);

    await c.read(editOutboxProvider).flush();
    await c.read(historySyncServiceProvider).runPass({'test'});

    expect(_log, contains('PATCH /tracks/u1 [Bearer tok-new]'));
    expect(_log, contains('POST /history [Bearer tok-new]'));
    expect(_log.where((e) => e.contains('tok-old')), isEmpty);
    expect(_log.where((e) => e.startsWith('wipe')), isEmpty);
    expect(await pendingEdits(), 0, reason: 'the edit was consumed');
    expect(await unsentPlays(), 0, reason: 'the play was consumed');

    // --- Playback restore: the saved queue reads back under scope C. ---
    final queue = QueueRepository(db);
    final snapshot = await queue.getActiveSessionSnapshot();
    expect(snapshot, isNotNull);
    expect(snapshot!.session.id, sessionId);
    final tracks = await queue.getSessionTracksInPlayOrder(sessionId);
    expect(tracks.map((t) => t.uuidId), ['u1']);
  });
}
