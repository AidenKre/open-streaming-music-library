// Phase M §7.7 (M-U24, unit level): a 401 is not a logout. Local,
// downloaded and already-buffered audio keeps playing: signing out by a 401
// quiesces no participant (playback admission stays open, listens and
// history are not closed), rotates and wipes nothing, and does not rebuild
// the scope. Only the banner's Log in (a logout) does that.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/local_resettable.dart';
import 'package:frontend/services/session_readiness.dart';
import 'package:frontend/services/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/revoked_session.dart';

final _events = <String>[];

class _Quiesce implements Quiescable {
  _Quiesce(this.quiesceName);
  @override
  final String quiesceName;
  @override
  Future<void> quiesce() async => _events.add('quiesce $quiesceName');
}

class _Wipe implements LocalResettable {
  @override
  int get resetPriority => ResetPriority.clearPreferences;
  @override
  Future<void> resetLocalState() async => _events.add('wipe');
}

void main() {
  late RevokedSession s;

  setUp(() async {
    _events.clear();
    s = await RevokedSession.create(
      overrides: [
        localQuiescablesProvider.overrideWithValue([
          _Quiesce('playback'),
          _Quiesce('listens'),
          _Quiesce('history'),
        ]),
        localResettablesProvider.overrideWithValue([_Wipe()]),
        onSessionChangedProvider.overrideWithValue(
          () async => _events.add('onSessionChanged'),
        ),
      ],
    );
  });

  tearDown(() => s.dispose());

  test('a 401 quiesces nothing, keeps the binding, and keeps the session '
      'ready for local playback', () async {
    final start = await s.session.resumeSavedSession();
    expect(start.kind, SessionStartKind.online);
    await pumpEventQueue();
    expect(s.container.read(sessionReadinessProvider).isReady, isTrue);
    final before = await ServerBindingRepository(s.db).current();

    await expectLater(
      s.container.read(apiClientProvider).getJson(['tracks']),
      throwsA(anything),
    );
    await pumpEventQueue();

    expect(s.session.serverBlocked.value, ServerBlockedReason.signedOut);
    expect(_events, isEmpty,
        reason: 'no quiesce (playback admission stays open), no wipe, no '
            'rebuild');
    final after = await ServerBindingRepository(s.db).current();
    expect(after!.localBindingId, before!.localBindingId,
        reason: 'not rotated: queue and listen writes still land');
    expect(s.container.read(sessionReadinessProvider).isReady, isTrue);
    expect(await s.store.read(), isNotNull);
  });

  // §7.7/§7.8: "the banner's Log in performs logout" — from the signed-out
  // state the logout still completes: participants quiesced, credentials
  // deleted, URL kept, the scope rebuilt (it then opens at Log in), and no
  // request carries the revoked token (the gate is not verified).
  test("the banner's Log in: logout completes from the signed-out state",
      () async {
    await s.session.resumeSavedSession();
    await pumpEventQueue();
    await expectLater(
      s.container.read(apiClientProvider).getJson(['tracks']),
      throwsA(anything),
    );
    expect(s.session.serverBlocked.value, ServerBlockedReason.signedOut);
    final sent = s.server.private.length;

    await s.session.logout();

    expect(_events, [
      'quiesce playback',
      'quiesce listens',
      'quiesce history',
      'onSessionChanged',
    ]);
    expect(await s.store.read(), isNull);
    expect(s.server.private.length, sent, reason: 'no revoke with a revoked '
        'token through a closed gate');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('serverUrl'), 'http://s');
  });
}
