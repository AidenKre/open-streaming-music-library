// Phase 9D.2d: the Last.fm model's account state and its one error home.
//  * SC-03: the status route is read only when the server sent the
//    `integrations` block with a `lastfm` entry on this read; a cached
//    block (offline, failed refresh) never starts network work, and an
//    absent block means Last.fm is not offered.
//  * Spec §7.12: with `available: false` the status is still read, so the
//    page can offer status and Disconnect to a user who still has a
//    connection; `available` travels with the status.
//  * SC-22: every failure becomes one typed `LastfmException`; the user
//    reads OSML's own words for it, never the server's text or code.
//  * §7.8: a timeout is not "offline".
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/lastfm/lastfm_errors.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';
import 'package:http/http.dart' as http;

import '../../helpers/fake_lastfm_api.dart';

ProviderContainer _scope(
  FakeLastfmApi api, {
  AdvertisedFeature<IntegrationsFeature>? block,
  bool absent = false,
}) {
  final c = ProviderContainer(
    overrides: lastfmOverrides(api, block: block, absent: absent),
  );
  addTearDown(c.dispose);
  return c;
}

/// Riverpod 3 pauses an unlistened provider: listen, then await.
Future<LastfmAccount> _account(ProviderContainer c) {
  c.listen(lastfmServiceProvider, (_, _) {});
  return c.read(lastfmServiceProvider.future);
}

void main() {
  group('account state', () {
    test('no integrations block: not offered, nothing sent', () async {
      final api = FakeLastfmApi();
      final c = _scope(api, absent: true);
      expect(await _account(c), isA<LastfmNotOffered>());
      expect(api.calls, isEmpty);
    });

    test('a block without a lastfm entry: not offered, nothing sent',
        () async {
      final api = FakeLastfmApi();
      final c = _scope(api,
          block: const AdvertisedFeature(
            IntegrationsFeature(version: 1),
            fromCache: false,
          ));
      expect(await _account(c), isA<LastfmNotOffered>());
      expect(api.calls, isEmpty);
    });

    test('only a cached block: unreachable, nothing sent', () async {
      final api = FakeLastfmApi();
      final c = _scope(api,
          block: const AdvertisedFeature(
            IntegrationsFeature(
              version: 1,
              lastfm: LastfmIntegration(available: true),
            ),
            fromCache: true,
          ));
      final account = await _account(c);
      expect(account, isA<LastfmUnreachable>());
      expect((account as LastfmUnreachable).available, isTrue);
      expect(api.calls, isEmpty);
    });

    test('a live block: the status is read once', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(state: 'connected_disabled');
      final c = _scope(api);
      final account = await _account(c);
      expect(account, isA<LastfmKnown>());
      final known = account as LastfmKnown;
      expect(known.available, isTrue);
      expect(known.status.state, LastfmAccountState.connectedDisabled);
      expect(known.status.accountName, 'listener_01');
      expect(api.calls, ['status']);
    });

    test('available false still reads the status (status and Disconnect)',
        () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(service: 'off');
      final c = _scope(api, block: liveIntegrations(available: false));
      final known = await _account(c) as LastfmKnown;
      expect(known.available, isFalse);
      expect(known.status.service, LastfmServerState.off);
      expect(known.status.isConnected, isTrue);
      expect(api.calls, ['status']);
    });

    test('a failed status read is a typed error', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async =>
            throw lastfmApiError(503, 'lastfm_unavailable', retryable: true);
      final c = _scope(api);
      c.listen(lastfmServiceProvider, (_, _) {});
      await expectLater(
        c.read(lastfmServiceProvider.future),
        throwsA(isA<LastfmException>()
            .having((e) => e.problem, 'problem', LastfmProblem.unavailable)),
      );
    });
  });

  // 9-R1-38 / 9-R1-07: a status read that failed (the binding not verified
  // now, or any other failure) is read again once, by itself, when the gate
  // next publishes a verified connection; nothing polls, and a disposed
  // scope reads nothing more.
  group('re-read on the next verified connection', () {
    test('not verified: needs a connection, then read when verified',
        () async {
      var reads = 0;
      final api = FakeLastfmApi()
        ..onStatus = () async {
          reads++;
          if (reads == 1) throw const BindingNotVerified();
          return lastfmStatus();
        };
      final c = _scope(api);
      c.listen(lastfmServiceProvider, (_, _) {});
      await expectLater(
        c.read(lastfmServiceProvider.future),
        throwsA(isA<LastfmException>().having(
            (e) => e.problem, 'problem', LastfmProblem.needsConnection)),
      );
      await pumpEventQueue();
      expect(api.calls, ['status'], reason: 'no polling');

      api.verifyAgain();
      await pumpEventQueue();
      expect(api.calls, ['status', 'status']);
      expect(c.read(lastfmServiceProvider).value, isA<LastfmKnown>());

      api.verifyAgain();
      await pumpEventQueue();
      expect(api.calls, hasLength(2), reason: 'known: no further read');
    });

    test('a failed read (502) is read again on the next verified connection',
        () async {
      var reads = 0;
      final api = FakeLastfmApi()
        ..onStatus = () async {
          reads++;
          if (reads == 1) throw ApiException(502, 'bad gateway');
          return lastfmStatus();
        };
      final c = _scope(api);
      c.listen(lastfmServiceProvider, (_, _) {});
      await expectLater(
        c.read(lastfmServiceProvider.future),
        throwsA(isA<LastfmException>()),
      );
      api.verifyAgain();
      await pumpEventQueue();
      expect(api.calls, ['status', 'status']);
      final account = c.read(lastfmServiceProvider).value;
      expect(account, isA<LastfmKnown>());
      expect((account as LastfmKnown).status.state, LastfmAccountState.enabled);
    });

    // R2-FE-03: the gate verified between the fast fail and the arming of
    // the re-read: its edge is gone, so the re-read happens at once.
    test('verified again before the re-read was armed: read at once',
        () async {
      var reads = 0;
      final api = FakeLastfmApi();
      api.onStatus = () async {
        reads++;
        if (reads == 1) {
          api.verifiedNow = true; // the edge passes while the error travels
          throw const BindingNotVerified();
        }
        return lastfmStatus();
      };
      final c = _scope(api);
      c.listen(lastfmServiceProvider, (_, _) {});
      await expectLater(
        c.read(lastfmServiceProvider.future),
        throwsA(isA<LastfmException>()),
      );
      await pumpEventQueue();
      expect(api.calls, ['status', 'status']);
      expect(c.read(lastfmServiceProvider).value, isA<LastfmKnown>());
    });

    test('a 502 while verified does not re-read in a loop', () async {
      final api = FakeLastfmApi()
        ..verifiedNow = true
        ..onStatus = () async => throw ApiException(502, 'bad gateway');
      final c = _scope(api);
      c.listen(lastfmServiceProvider, (_, _) {});
      await expectLater(
        c.read(lastfmServiceProvider.future),
        throwsA(isA<LastfmException>()),
      );
      await pumpEventQueue();
      expect(api.calls, ['status'], reason: 'waits for the next edge');
    });

    // Sign-off OPEN-M-11 (E9): verified but offline, the status read is
    // withheld; it reads as needing a connection and waits for the next
    // verified edge (the reconnect), never re-reading in a loop.
    test('a withheld status read: needs a connection, no re-read loop',
        () async {
      final api = FakeLastfmApi()
        ..verifiedNow = true
        ..onStatus = () async => throw const TokenWithheldException();
      final c = _scope(api);
      c.listen(lastfmServiceProvider, (_, _) {});
      await expectLater(
        c.read(lastfmServiceProvider.future),
        throwsA(isA<LastfmException>().having(
            (e) => e.problem, 'problem', LastfmProblem.needsConnection)),
      );
      await pumpEventQueue(times: 20);
      expect(api.calls, ['status'], reason: 'waits for the next edge');
    });

    // R2-FE-04: a build that was superseded while its read ran does not arm
    // a re-read when that read fails late.
    test('a superseded build failing late arms nothing', () async {
      final first = Completer<LastfmStatus>();
      var reads = 0;
      final api = FakeLastfmApi()
        ..onStatus = () {
          reads++;
          return reads == 1 ? first.future : Future.value(lastfmStatus());
        };
      final c = _scope(api);
      c.listen(lastfmServiceProvider, (_, _) {});
      await pumpEventQueue();
      c.invalidate(lastfmServiceProvider);
      await pumpEventQueue();
      expect(c.read(lastfmServiceProvider).value, isA<LastfmKnown>());
      first.completeError(ApiException(502, 'late'));
      await pumpEventQueue();
      api.verifyAgain();
      await pumpEventQueue();
      expect(api.calls, ['status', 'status']);
    });

    test('a disposed scope reads nothing on a later verification', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => throw const BindingNotVerified();
      final c = ProviderContainer(overrides: lastfmOverrides(api));
      c.listen(lastfmServiceProvider, (_, _) {});
      await expectLater(
        c.read(lastfmServiceProvider.future),
        throwsA(isA<LastfmException>()),
      );
      c.dispose();
      api.verifyAgain();
      await pumpEventQueue();
      expect(api.calls, ['status']);
      expect(api.verifiedListeners, 0, reason: 'nothing outlives the scope');
    });
  });

  group('errors (SC-22)', () {
    test('each server code maps to its problem and retryable flag', () {
      const table = <String, (int, LastfmProblem, bool)>{
        'lastfm_disabled': (403, LastfmProblem.disabled, false),
        'lastfm_stopped': (503, LastfmProblem.stopped, false),
        'lastfm_unavailable': (503, LastfmProblem.unavailable, true),
        'lastfm_too_soon': (429, LastfmProblem.tooSoon, true),
        'lastfm_not_authorized_yet': (409, LastfmProblem.notAuthorizedYet, true),
        'lastfm_approval_expired': (410, LastfmProblem.approvalExpired, false),
        'lastfm_account_mismatch': (409, LastfmProblem.accountMismatch, false),
        'lastfm_not_connected': (409, LastfmProblem.notConnected, false),
        'lastfm_connection_changed':
            (409, LastfmProblem.connectionChanged, false),
        'lastfm_reconnect_required':
            (409, LastfmProblem.reconnectRequired, false),
      };
      for (final e in table.entries) {
        final (status, problem, retryable) = e.value;
        final x = LastfmException.from(
            lastfmApiError(status, e.key, retryable: retryable));
        expect(x.problem, problem, reason: e.key);
        expect(x.retryable, retryable, reason: e.key);
      }
    });

    test('a mismatch carries both account names; implausible ones are dropped',
        () {
      final x = LastfmException.from(lastfmApiError(
        409,
        'lastfm_account_mismatch',
        extra: {'stored_account': 'listener_01', 'approved_account': 'other_02'},
      ));
      expect(x.storedAccount, 'listener_01');
      expect(x.approvedAccount, 'other_02');

      final odd = LastfmException.from(lastfmApiError(
        409,
        'lastfm_account_mismatch',
        extra: {'stored_account': 'a\u202Eb', 'approved_account': 7},
      ));
      expect(odd.problem, LastfmProblem.accountMismatch);
      expect(odd.storedAccount, isNull);
      expect(odd.approvedAccount, isNull);
    });

    test('an unknown code or a plain error is "failed", never a guess', () {
      for (final e in [
        lastfmApiError(409, 'some_future_code'),
        ApiException(500, 'Internal Server Error'),
        ApiException(401, '{"detail": {"error": "invalid_token"}}'),
        ApiException(404, '{"detail": "Not Found"}'),
      ]) {
        expect(LastfmException.from(e).problem, LastfmProblem.failed,
            reason: '$e');
      }
      expect(LastfmException.from(StateError('x')).problem,
          LastfmProblem.failed);
    });

    test('a timeout is "timed out", not "unreachable" (§7.8)', () {
      final timeout = NetworkException('timeout',
          cause: TimeoutException('x'), attemptsMade: 1);
      final refused = NetworkException('refused',
          cause: http.ClientException('refused'), attemptsMade: 1);
      expect(LastfmException.from(timeout).problem, LastfmProblem.timedOut);
      expect(LastfmException.from(refused).problem, LastfmProblem.unreachable);
    });

    test('another server answering is its own problem', () {
      final e = ServerInstanceChangedException(
          boundInstanceId: 'a', servedBy: 'b');
      expect(LastfmException.from(e).problem, LastfmProblem.serverChanged);
    });

    test('the binding not verified now is "needs a connection"', () {
      expect(LastfmException.from(const BindingNotVerified()).problem,
          LastfmProblem.needsConnection);
      expect(lastfmProblemText(LastfmProblem.needsConnection),
          'Last.fm settings need a connection to your server. They load '
          'again once the app reconnects.');
    });

    // Sign-off OPEN-M-11 (E9): a request the token client withheld (not
    // verified, or the app offline) needs a connection, in the existing
    // words; not "Something went wrong".
    test('a withheld token is "needs a connection"', () {
      expect(LastfmException.from(const TokenWithheldException()).problem,
          LastfmProblem.needsConnection);
    });

    // 9-R2-04: "they load again once the app reconnects" is said only when
    // that can happen; a different server and no session say what is true.
    test('a different server and no session have their own words', () {
      expect(
          LastfmException.from(
                  const BindingNotVerified(BindingRefusal.differentServer))
              .problem,
          LastfmProblem.differentServer);
      expect(
          LastfmException.from(
                  const BindingNotVerified(BindingRefusal.noSession))
              .problem,
          LastfmProblem.signedOut);
      expect(
          LastfmException.from(const BindingNotVerified(BindingRefusal.notYet))
              .problem,
          LastfmProblem.needsConnection);
      expect(lastfmProblemText(LastfmProblem.differentServer),
          'A different server answers at this address now, so Last.fm '
          "settings can't load here.");
      expect(lastfmProblemText(LastfmProblem.signedOut),
          "You're not signed in to this server, so Last.fm settings can't "
          'load. Sign in again.');
      for (final p in [LastfmProblem.differentServer, LastfmProblem.signedOut]) {
        expect(lastfmProblemText(p), isNot(contains('reconnects')),
            reason: '$p: reconnecting alone does not fix it');
      }
    });

    test('a LastfmException passes through unchanged', () {
      const original = LastfmException(LastfmProblem.badAnswer);
      expect(LastfmException.from(original), same(original));
    });

    test('every problem has OSML wording; never the server text or code', () {
      for (final p in LastfmProblem.values) {
        final text = lastfmProblemText(p);
        expect(text.trim(), isNotEmpty, reason: '$p');
        expect(text.contains('lastfm_'), isFalse, reason: '$p');
        expect(text.contains('never shown'), isFalse, reason: '$p');
      }
      expect(lastfmProblemText(LastfmProblem.stopped),
          'Scrobbling is stopped on this server. Ask whoever runs it.');
    });

    test('toString names only the problem', () {
      final x = LastfmException.from(lastfmApiError(
        409,
        'lastfm_account_mismatch',
        extra: {'stored_account': 'listener_01', 'approved_account': 'other_02'},
      ));
      expect('$x'.contains('listener_01'), isFalse);
      expect('$x'.contains('never shown'), isFalse);
      expect('$x', contains('accountMismatch'));
    });
  });
}
