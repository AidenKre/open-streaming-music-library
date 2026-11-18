// Phase 9D.2d: the Last.fm model's actions (spec §7.4, 9-U10 client part).
//  * connect returns the validated authorization URL (an invalid one is a
//    "bad answer" and its text never carries the URL or the token);
//  * finish = complete. "After a 410, and only then, the client re-reads
//    the status and treats it as success if it shows a connected account
//    with needs_reconnect false. Every other error is shown as it is."
//  * enable sends the caller's connection_id; disconnect always allowed
//    while the server can be reached;
//  * after every action the account state is read again (the "change on
//    the Integrations page" Now Playing listens to);
//  * no action starts network work on a cached or absent block;
//  * a scope disposed while an action is pending (session/user switch)
//    neither throws nor writes state afterwards.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/lastfm/lastfm_errors.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';

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

/// Builds the model (first status read) and clears the call log.
Future<LastfmService> _ready(ProviderContainer c, FakeLastfmApi api) async {
  c.listen(lastfmServiceProvider, (_, _) {});
  await c.read(lastfmServiceProvider.future);
  api.calls.clear();
  return c.read(lastfmServiceProvider.notifier);
}

LastfmStatus? _status(ProviderContainer c) {
  final v = c.read(lastfmServiceProvider).value;
  return v is LastfmKnown ? v.status : null;
}

Matcher _problem(LastfmProblem p) =>
    throwsA(isA<LastfmException>().having((e) => e.problem, 'problem', p));

void main() {
  group('connect', () {
    test('returns the validated URL, then re-reads the state', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(state: 'not_connected');
      final c = _scope(api);
      final model = await _ready(c, api);
      api.onStatus = () async => lastfmStatus(state: 'awaiting_authorization');

      final a = await model.connect();

      expect(a.url.uri.queryParameters['token'], fakeLastfmToken);
      expect(a.expiresAt, 1800000600000);
      expect(api.calls, ['connect', 'status']);
      expect(_status(c)!.state, LastfmAccountState.awaitingAuthorization);
    });

    test('an answer with an invalid URL is a bad answer, URL never shown',
        () async {
      final api = FakeLastfmApi()..onConnect = () async => null;
      final c = _scope(api);
      final model = await _ready(c, api);

      Object? error;
      try {
        await model.connect();
      } catch (e) {
        error = e;
      }
      expect(error, isA<LastfmException>());
      final x = error as LastfmException;
      expect(x.problem, LastfmProblem.badAnswer);
      for (final text in ['$x', lastfmProblemText(x.problem)]) {
        expect(text.contains(fakeLastfmToken), isFalse);
        expect(text.contains(fakeLastfmKey), isFalse);
      }
    });

    test('server refusals map to their problem', () async {
      for (final (status, code, problem) in [
        (429, 'lastfm_too_soon', LastfmProblem.tooSoon),
        (403, 'lastfm_disabled', LastfmProblem.disabled),
        (503, 'lastfm_stopped', LastfmProblem.stopped),
        (503, 'lastfm_unavailable', LastfmProblem.unavailable),
      ]) {
        final api = FakeLastfmApi()
          ..onConnect = () async => throw lastfmApiError(status, code);
        final c = _scope(api);
        final model = await _ready(c, api);
        await expectLater(model.connect(), _problem(problem), reason: code);
        expect(api.calls, ['connect', 'status'], reason: code);
      }
    });

    test('a timeout is "timed out", not offline', () async {
      final api = FakeLastfmApi()
        ..onConnect = () async => throw NetworkException('t',
            cause: TimeoutException('t'), attemptsMade: 1);
      final c = _scope(api);
      final model = await _ready(c, api);
      await expectLater(model.connect(), _problem(LastfmProblem.timedOut));
    });
  });

  group('finish (complete)', () {
    test('success returns the binding and re-reads the state', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(state: 'awaiting_authorization');
      final c = _scope(api);
      final model = await _ready(c, api);
      api.onStatus = () async => lastfmStatus(state: 'connected_disabled');

      final done = await model.finish();

      expect(done.connectionId, fakeConnectionId);
      expect(done.accountName, 'listener_01');
      expect(done.state, LastfmAccountState.connectedDisabled);
      expect(api.calls, ['complete', 'status']);
      expect(_status(c)!.state, LastfmAccountState.connectedDisabled);
    });

    test('a malformed 200 answer is a bad answer', () async {
      final api = FakeLastfmApi()..onComplete = () async => null;
      final c = _scope(api);
      final model = await _ready(c, api);
      await expectLater(model.finish(), _problem(LastfmProblem.badAnswer));
    });

    group('410, then the status re-read', () {
      for (final (state, needsReconnect) in [
        ('connected_disabled', false),
        ('enabled', false),
      ]) {
        test('$state, needs_reconnect $needsReconnect: success', () async {
          final api = FakeLastfmApi()
            ..onComplete =
                () async => throw lastfmApiError(410, 'lastfm_approval_expired');
          final c = _scope(api);
          final model = await _ready(c, api);
          api.onStatus = () async => lastfmStatus(
                state: state,
                needsReconnect: needsReconnect,
                account: 'listener_01',
                connectionId: fakeConnectionId,
              );

          final done = await model.finish();

          expect(done.connectionId, fakeConnectionId);
          expect(done.accountName, 'listener_01');
          expect(done.state.name, state == 'enabled'
              ? 'enabled'
              : 'connectedDisabled');
          expect(api.calls, ['complete', 'status'],
              reason: 'exactly one re-read');
          expect(_status(c)!.isConnected, isTrue);
        });
      }

      for (final (label, status) in [
        ('needs reconnect', lastfmStatus(needsReconnect: true)),
        ('needs_reconnect unknown', lastfmStatus(needsReconnect: null)),
        ('not connected', lastfmStatus(state: 'not_connected')),
        ('awaiting authorization',
            lastfmStatus(state: 'awaiting_authorization')),
        ('unknown state', lastfmStatus(state: 'mystery')),
        ('no account name', lastfmStatus(account: null)),
        ('no connection id', lastfmStatus(connectionId: null)),
      ]) {
        test('$label: the 410 stands', () async {
          final api = FakeLastfmApi()
            ..onComplete =
                () async => throw lastfmApiError(410, 'lastfm_approval_expired');
          final c = _scope(api);
          final model = await _ready(c, api);
          api.onStatus = () async => status;

          await expectLater(
              model.finish(), _problem(LastfmProblem.approvalExpired));
          expect(api.calls, ['complete', 'status']);
        });
      }

      test('the re-read fails: the 410 stands', () async {
        final api = FakeLastfmApi()
          ..onComplete =
              () async => throw lastfmApiError(410, 'lastfm_approval_expired');
        final c = _scope(api);
        final model = await _ready(c, api);
        api.onStatus = () async =>
            throw lastfmApiError(503, 'lastfm_unavailable', retryable: true);

        await expectLater(
            model.finish(), _problem(LastfmProblem.approvalExpired));
      });
    });

    // "Every other error is shown as it is", even when the status would
    // look connected.
    for (final (status, code, problem) in [
      (409, 'lastfm_account_mismatch', LastfmProblem.accountMismatch),
      (409, 'lastfm_not_authorized_yet', LastfmProblem.notAuthorizedYet),
      (503, 'lastfm_unavailable', LastfmProblem.unavailable),
      (503, 'lastfm_stopped', LastfmProblem.stopped),
      // OPEN-9-03: Finish has a per-user limit of one gate gap.
      (429, 'lastfm_too_soon', LastfmProblem.tooSoon),
    ]) {
      test('$code is shown as it is, never re-read into success', () async {
        final api = FakeLastfmApi()
          ..onComplete = () async => throw lastfmApiError(status, code,
              extra: code == 'lastfm_account_mismatch'
                  ? {'stored_account': 'listener_01', 'approved_account': 'b'}
                  : const {});
        final c = _scope(api);
        final model = await _ready(c, api);
        // A connected, healthy account: must not turn the error into success.
        api.onStatus = () async => lastfmStatus();

        await expectLater(model.finish(), _problem(problem));
      });
    }

    test('a mismatch keeps both account names for the page', () async {
      final api = FakeLastfmApi()
        ..onComplete = () async => throw lastfmApiError(
              409,
              'lastfm_account_mismatch',
              extra: {'stored_account': 'listener_01', 'approved_account': 'b2'},
            );
      final c = _scope(api);
      final model = await _ready(c, api);
      try {
        await model.finish();
        fail('expected a mismatch');
      } on LastfmException catch (e) {
        expect(e.storedAccount, 'listener_01');
        expect(e.approvedAccount, 'b2');
      }
    });
  });

  group('enable and disconnect', () {
    test('enable sends the connection id and re-reads', () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(state: 'connected_disabled');
      final c = _scope(api);
      final model = await _ready(c, api);
      api.onStatus = () async => lastfmStatus(state: 'enabled');

      await model.enable(fakeConnectionId);

      expect(api.calls, ['enable $fakeConnectionId', 'status']);
      expect(_status(c)!.state, LastfmAccountState.enabled);
    });

    test('a stale enable is refused as connection changed', () async {
      final api = FakeLastfmApi()
        ..onEnable = (_) async =>
            throw lastfmApiError(409, 'lastfm_connection_changed');
      final c = _scope(api);
      final model = await _ready(c, api);
      await expectLater(
          model.enable('old-id'), _problem(LastfmProblem.connectionChanged));
      expect(api.calls, ['enable old-id', 'status']);
    });

    test('disconnect deletes and re-reads', () async {
      final api = FakeLastfmApi();
      final c = _scope(api);
      final model = await _ready(c, api);
      api.onStatus = () async => lastfmStatus(
          state: 'not_connected', needsReconnect: null, account: null,
          connectionId: null);

      await model.disconnect();

      expect(api.calls, ['disconnect', 'status']);
      expect(_status(c)!.state, LastfmAccountState.notConnected);
    });

    test('disconnect works with available false (status and Disconnect)',
        () async {
      final api = FakeLastfmApi()
        ..onStatus = () async => lastfmStatus(service: 'off');
      final c = _scope(api, block: liveIntegrations(available: false));
      final model = await _ready(c, api);
      await model.disconnect();
      expect(api.calls.first, 'disconnect');
    });
  });

  group('no network work without a live block', () {
    test('cached block: every action is unreachable and sends nothing',
        () async {
      final api = FakeLastfmApi();
      final c = _scope(api,
          block: const AdvertisedFeature(
            IntegrationsFeature(
              version: 1,
              lastfm: LastfmIntegration(available: true),
            ),
            fromCache: true,
          ));
      final model = await _ready(c, api);
      await expectLater(model.connect(), _problem(LastfmProblem.unreachable));
      await expectLater(model.finish(), _problem(LastfmProblem.unreachable));
      await expectLater(
          model.enable(fakeConnectionId), _problem(LastfmProblem.unreachable));
      await expectLater(
          model.disconnect(), _problem(LastfmProblem.unreachable));
      expect(api.calls, isEmpty);
    });

    test('absent block: every action is not offered and sends nothing',
        () async {
      final api = FakeLastfmApi();
      final c = _scope(api, absent: true);
      final model = await _ready(c, api);
      await expectLater(model.connect(), _problem(LastfmProblem.notOffered));
      await expectLater(model.disconnect(), _problem(LastfmProblem.notOffered));
      expect(api.calls, isEmpty);
    });
  });

  test('a scope disposed while finish is pending: no error, no re-read',
      () async {
    final api = FakeLastfmApi();
    final pending = Completer<LastfmCompleted?>();
    api.onComplete = () => pending.future;
    final c = ProviderContainer(overrides: lastfmOverrides(api));
    final model = await _ready(c, api);

    final call = model.finish().then<Object?>((v) => v, onError: (Object e) => e);
    await pumpEventQueue();
    c.dispose();
    pending.complete(LastfmCompleted.fromJson({
      'connection_id': fakeConnectionId,
      'account_name': 'listener_01',
      'state': 'connected_disabled',
    }));
    await call;
    await pumpEventQueue();

    expect(api.calls, ['complete'], reason: 'no status read after disposal');
  });
}
