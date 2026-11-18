// Phase M §7.7 end to end (M-U24, M.3c review F4): a real 401 through the
// scope's authenticated client reaches `SessionService.onUnauthorized`
// through the scope's hook. Offline turns on through the signed-out reason
// only: no network-failure listener fires on a 401. A scope resumed with a
// revoked token (a logout whose credential delete failed) shows signed-out
// at its first request instead of looping: after the 401 no runner request
// leaves, also across a recovery edge.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_service.dart';

import '../helpers/revoked_session.dart';


void main() {
  late RevokedSession s;
  late ProviderContainer c;

  setUp(() async {
    s = await RevokedSession.create();
    c = s.container;
  });

  tearDown(() => s.dispose());

  SessionService service() => s.session;

  test('a 401 response sets signedOut; no network-failure listener fires',
      () async {
    var networkFailures = 0;
    c.read(apiClientProvider).addNetworkFailureListener(() => networkFailures++);
    final offlineWatch = c.listen(offlineModeProvider, (_, _) {});
    addTearDown(offlineWatch.close);
    // Sign-off OPEN-M-11: the token goes only to a verified server (fixture).
    await s.verify();

    await expectLater(
      c.read(apiClientProvider).getJson(['tracks']),
      throwsA(anything),
    );
    expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
    expect(networkFailures, 0, reason: 'offline comes from the reason only');
    expect(c.read(offlineModeProvider), isTrue);
    expect(await s.store.read(), isNotNull, reason: 'credentials are kept');
  });

  test('a resumed session with a revoked token: signed out at the first '
      'request, then no runner request leaves (no loop)', () async {
    final offlineWatch = c.listen(offlineModeProvider, (_, _) {});
    addTearDown(offlineWatch.close);
    final start = await service().resumeSavedSession();
    expect(start.kind, SessionStartKind.online);
    await pumpEventQueue();
    expect(c.read(serverBindingGateProvider).state, isA<BindingVerified>());

    await service().onSessionActivated(); // the initial catalog sync
    await pumpEventQueue();
    expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
    expect(c.read(serverBindingGateProvider).state, isA<BindingSignedOut>());
    final afterFirst = s.server.private.length;
    expect(afterFirst, 1, reason: 'exactly the one 401');

    // A recovery edge and a user retry: both wait at the closed gate.
    unawaited(c.read(serverBindingGateProvider).startConnection('http://s'));
    unawaited(service().syncLibrary());
    await pumpEventQueue(times: 50);
    expect(s.server.private.length, afterFirst);
    expect(service().serverBlocked.value, ServerBlockedReason.signedOut);
  });
}
