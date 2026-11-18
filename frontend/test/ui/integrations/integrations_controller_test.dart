// Phase 9D.2e S3: the Integrations page controller over the real Last.fm
// model (9D.2d `LastfmService`), a scripted API and a recording browser.
//  * SC-26: the controller turns input into model calls and holds
//    presentation state (busy, message); the offer and the problem wording
//    come from the model's policy.
//  * Spec §7.4 "Approve": "The client opens the URL in the system browser on
//    an explicit tap" — the Connect tap — and only a URL the validator
//    accepted.
//  * Spec §7.12 / SC-22: errors are shown in OSML's words
//    (`lastfmProblemText`); an account mismatch names both accounts.
//  * 9D.2d hand-over: Connect only when not connected or a reconnect is
//    needed; connect/finish only online; one action at a time (review r1
//    #2: concurrent actions could publish re-reads out of order).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart' show NetworkException;
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/models/feature_blocks.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/repositories/server_binding_repository.dart';
import 'package:frontend/services/external_browser.dart';
import 'package:frontend/services/feature_providers.dart';
import 'package:frontend/services/lastfm/lastfm_errors.dart';
import 'package:frontend/ui/integrations/integrations_controller.dart';

import '../../helpers/fake_external_browser.dart';
import '../../helpers/fake_lastfm_api.dart';
import '../../helpers/test_offline.dart';

class _Rig {
  _Rig({
    this.absent = false,
    AdvertisedFeature<IntegrationsFeature>? block,
    bool offline = false,
  }) : offline = TestOffline(offline) {
    container = ProviderContainer(
      overrides: [
        ...lastfmOverrides(api, block: block, absent: absent),
        externalBrowserProvider.overrideWithValue(browser),
        offlineModeProvider.overrideWith(() => this.offline),
      ],
    );
  }

  final bool absent;
  final api = FakeLastfmApi();
  final browser = FakeExternalBrowser();
  final TestOffline offline;
  late final ProviderContainer container;
  late IntegrationsControls controls;
  int notified = 0;

  Future<IntegrationsControls> start() async {
    controls = container.read(integrationsControllerFactoryProvider)();
    controls.addListener(() => notified++);
    await settle();
    return controls;
  }

  void dispose() {
    controls.dispose();
    container.dispose();
  }
}

/// A user action refused while the binding was not verified yet (9-R2-11).
const _notSentYet =
    "Nothing was changed: the app wasn't connected to your server yet. "
    'Try again.';

/// Lets scripted futures and listeners run (no wall-clock wait).
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

_Rig _rig({
  bool absent = false,
  AdvertisedFeature<IntegrationsFeature>? block,
  bool offline = false,
  String state = 'not_connected',
  Object? needsReconnect,
}) {
  final rig = _Rig(absent: absent, block: block, offline: offline);
  rig.api.onStatus = () async =>
      lastfmStatus(state: state, needsReconnect: needsReconnect);
  addTearDown(rig.dispose);
  return rig;
}

void main() {
  group('the view', () {
    test('loading first, then the known status with its offer', () async {
      final rig = _rig(state: 'not_connected');
      final c = rig.container.read(integrationsControllerFactoryProvider)();
      rig.controls = c; // the rig disposes it
      expect(c.view.load, IntegrationsLoad.loading);
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(c.view.status!.state, LastfmAccountState.notConnected);
      expect(c.view.available, isTrue);
      expect(c.view.online, isTrue);
      expect(c.view.offer!.canConnect, isTrue);
      expect(c.busy, isFalse);
      expect(c.message, isNull);
    });

    test('without the block: not offered, nothing asked', () async {
      final rig = _rig(absent: true);
      final c = await rig.start();
      expect(c.view.load, IntegrationsLoad.notOffered);
      expect(c.view.offer, isNull);
      expect(rig.api.calls, isEmpty);
    });

    test('only a cached block: unreachable, nothing asked', () async {
      final rig = _rig(
        block: const AdvertisedFeature(
          IntegrationsFeature(
            version: 1,
            lastfm: LastfmIntegration(available: true),
          ),
          fromCache: true,
        ),
      );
      final c = await rig.start();
      expect(c.view.load, IntegrationsLoad.unreachable);
      expect(c.view.offer, isNull);
      expect(rig.api.calls, isEmpty);
    });

    test('available: false travels into the view and the offer', () async {
      final rig = _rig(
        block: liveIntegrations(available: false),
        state: 'enabled',
        needsReconnect: false,
      );
      final c = await rig.start();
      expect(c.view.available, isFalse);
      expect(c.view.offer!.showTurnedOff, isTrue);
      expect(c.view.offer!.canDisconnect, isTrue);
      expect(c.view.offer!.canConnect, isFalse);
    });

    test('a failed status read shows OSML words; Retry reads again', () async {
      final rig = _rig();
      rig.api.onStatus = () async => throw lastfmApiError(500, 'boom');
      final c = await rig.start();
      expect(c.view.load, IntegrationsLoad.failed);
      expect(c.view.loadError, lastfmProblemText(LastfmProblem.failed));
      expect(c.view.loadError, isNot(contains('server text')));
      rig.api.onStatus = () async => lastfmStatus(state: 'not_connected');
      await c.refresh();
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(rig.api.calls.where((x) => x == 'status'), hasLength(2));
    });

    test('problem rows carry the model reason; the order is kept', () async {
      final rig = _rig();
      rig.api.onStatus = () async => lastfmStatus(
        counts: {'pending': 1, 'sent': 2, 'ignored': 1, 'failed': 0,
            'dropped': 1},
        recentProblems: [
          {'artist': 'Artist B', 'track': 'Track B', 'listened_at': 2000,
              'status': 'dropped', 'code': 'too_old'},
          {'artist': 'Artist A', 'track': 'Track A', 'listened_at': 1000,
              'status': 'ignored', 'code': '1'},
        ],
      );
      final c = await rig.start();
      expect(
        c.view.problems.map((p) => (p.artist, p.track, p.listenedAt, p.reason)),
        [
          ('Artist B', 'Track B', 2000,
              'Not sent: it was more than 14 days old before it could be sent.'),
          ('Artist A', 'Track A', 1000,
              'Last.fm ignored it because of the artist name.'),
        ],
      );
    });

    test('going offline and back updates the offer and notifies', () async {
      final rig = _rig(state: 'not_connected');
      final c = await rig.start();
      final before = rig.notified;
      rig.offline.set(true);
      await settle();
      expect(c.view.online, isFalse);
      expect(c.view.offer!.canConnect, isFalse);
      expect(rig.notified, greaterThan(before));
      rig.offline.set(false);
      await settle();
      expect(c.view.online, isTrue);
      expect(c.view.offer!.canConnect, isTrue);
    });
  });

  group('connect', () {
    test('asks the server, then opens exactly the validated URL', () async {
      final rig = _rig(state: 'not_connected');
      final c = await rig.start();
      rig.api.calls.clear();
      await c.connect();
      expect(rig.api.calls.first, 'connect');
      expect(rig.browser.opened.map((u) => u.toString()), [fakeLastfmUrl]);
      expect(c.message, isNull);
      expect(c.busy, isFalse);
    });

    test('a reconnect is a connect', () async {
      final rig = _rig(state: 'enabled', needsReconnect: true);
      final c = await rig.start();
      await c.connect();
      expect(rig.api.calls, contains('connect'));
      expect(rig.browser.opened, hasLength(1));
    });

    test('the browser not opening is said', () async {
      final rig = _rig(state: 'not_connected');
      rig.browser.answer = false;
      final c = await rig.start();
      await c.connect();
      expect(c.message, "Couldn't open your browser.");
    });

    test('a refusal is shown in OSML words and opens nothing', () async {
      final rig = _rig(state: 'not_connected');
      rig.api.onConnect = () async =>
          throw lastfmApiError(429, 'lastfm_too_soon', retryable: true);
      final c = await rig.start();
      await c.connect();
      expect(c.message, lastfmProblemText(LastfmProblem.tooSoon));
      // Connect keeps its own words (Finish says "Waiting on Last.fm.").
      expect(c.message, 'Wait a moment before connecting again.');
      expect(rig.browser.opened, isEmpty);
    });

    test('an answer the validator refuses opens nothing', () async {
      final rig = _rig(state: 'not_connected');
      rig.api.onConnect = () async => LastfmAuthorization.fromJson({
        'authorization_url': 'https://evil.example/api/auth/?api_key=k&token=t',
      });
      final c = await rig.start();
      await c.connect();
      expect(c.message, lastfmProblemText(LastfmProblem.badAnswer));
      expect(rig.browser.opened, isEmpty);
    });

    test('a healthy connection is never offered Connect: nothing sent',
        () async {
      for (final state in ['connected_disabled', 'enabled']) {
        final rig = _rig(state: state, needsReconnect: false);
        final c = await rig.start();
        rig.api.calls.clear();
        await c.connect();
        expect(rig.api.calls, isEmpty, reason: state);
        expect(rig.browser.opened, isEmpty, reason: state);
      }
    });

    test('offline: nothing sent', () async {
      final rig = _rig(state: 'not_connected', offline: true);
      final c = await rig.start();
      rig.api.calls.clear();
      await c.connect();
      await c.finish();
      expect(rig.api.calls, isEmpty);
    });
  });

  group('finish, enable, disconnect', () {
    test('finish completes; the re-read state offers the opt-in', () async {
      final rig = _rig(state: 'awaiting_authorization');
      final c = await rig.start();
      rig.api.onStatus = () async =>
          lastfmStatus(state: 'connected_disabled', needsReconnect: false);
      await c.finish();
      await settle();
      expect(rig.api.calls, contains('complete'));
      expect(c.view.offer!.canOptIn, isTrue);
      expect(c.message, isNull);
    });

    test('not approved yet is said in OSML words', () async {
      final rig = _rig(state: 'awaiting_authorization');
      rig.api.onComplete = () async => throw lastfmApiError(
          409, 'lastfm_not_authorized_yet', retryable: true);
      final c = await rig.start();
      await c.finish();
      expect(c.message, lastfmProblemText(LastfmProblem.notAuthorizedYet));
    });

    // Sign-off s7-app-texts Phase 9 tail (owner 2026-11-17): Finish and
    // Connect share the server's cooldown answer (OPEN-9-03); each says its
    // own words.
    test('finish refused as too soon (OPEN-9-03) says it is waiting on '
        'Last.fm', () async {
      final rig = _rig(state: 'awaiting_authorization');
      rig.api.onComplete = () async =>
          throw lastfmApiError(429, 'lastfm_too_soon', retryable: true);
      final c = await rig.start();
      await c.finish();
      expect(c.message, 'Waiting on Last.fm.');
      expect(rig.api.calls.where((call) => call == 'complete'), hasLength(1));
    });

    test('an account mismatch names both accounts', () async {
      final rig = _rig(state: 'awaiting_authorization');
      rig.api.onComplete = () async => throw lastfmApiError(
        409,
        'lastfm_account_mismatch',
        extra: {'stored_account': 'old_one', 'approved_account': 'new_one'},
      );
      final c = await rig.start();
      await c.finish();
      expect(
        c.message,
        '${lastfmProblemText(LastfmProblem.accountMismatch)} '
        'Connected account: old_one. Approved account: new_one.',
      );
    });

    test('an account mismatch without names says only the text', () async {
      final rig = _rig(state: 'awaiting_authorization');
      rig.api.onComplete = () async =>
          throw lastfmApiError(409, 'lastfm_account_mismatch');
      final c = await rig.start();
      await c.finish();
      expect(c.message, lastfmProblemText(LastfmProblem.accountMismatch));
    });

    test('enable sends the current connection ID', () async {
      final rig = _rig(state: 'connected_disabled', needsReconnect: false);
      final c = await rig.start();
      await c.enable();
      expect(rig.api.calls, contains('enable $fakeConnectionId'));
    });

    test('enable is not sent when the opt-in is not offered', () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      rig.api.calls.clear();
      await c.enable();
      expect(rig.api.calls, isEmpty);
    });

    test('disconnect is sent and the state re-read', () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      rig.api.onStatus = () async => lastfmStatus(state: 'not_connected');
      await c.disconnect();
      await settle();
      expect(rig.api.calls, contains('disconnect'));
      expect(c.view.status!.state, LastfmAccountState.notConnected);
    });

    // DEV-9-13 (owner 2026-11-14): Disconnect while the server is
    // unreachable also says that nothing was changed.
    test('disconnect while the server is unreachable says nothing was '
        'changed', () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      rig.api.onDisconnect = () async =>
          throw NetworkException('refused', attemptsMade: 1);
      await c.disconnect();
      expect(c.message, "Can't reach your server right now. Nothing was changed.");
    });

    test('a disconnect that timed out may have been applied: no "nothing '
        'was changed"', () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      rig.api.onDisconnect = () async => throw NetworkException(
        'slow',
        cause: TimeoutException('t'),
        attemptsMade: 1,
      );
      await c.disconnect();
      expect(c.message, lastfmProblemText(LastfmProblem.timedOut));
    });

    test('finish while the server is unreachable keeps its own words',
        () async {
      final rig = _rig(state: 'awaiting_authorization');
      rig.api.onComplete = () async =>
          throw NetworkException('refused', attemptsMade: 1);
      final c = await rig.start();
      await c.finish();
      expect(c.message, lastfmProblemText(LastfmProblem.unreachable));
    });

    test('a new action clears the previous message', () async {
      final rig = _rig(state: 'awaiting_authorization');
      rig.api.onComplete = () async => throw lastfmApiError(
          409, 'lastfm_not_authorized_yet', retryable: true);
      final c = await rig.start();
      await c.finish();
      expect(c.message, isNotNull);
      rig.api.onComplete = () async => LastfmCompleted.fromJson({
        'connection_id': fakeConnectionId,
        'account_name': 'listener_01',
        'state': 'connected_disabled',
      });
      await c.finish();
      expect(c.message, isNull);
    });
  });

  group('review r1', () {
    // #2: a status re-read that fails after an action must not leave the
    // old state on screen with its old buttons.
    test('a failed re-read after an action is shown, with Retry', () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      rig.api.onStatus = () async => throw lastfmApiError(500, 'boom');
      await c.disconnect();
      await settle();
      expect(rig.api.calls, contains('disconnect'));
      expect(c.view.load, IntegrationsLoad.failed);
      expect(c.view.loadError, lastfmProblemText(LastfmProblem.failed));
      rig.api.onStatus = () async => lastfmStatus(state: 'not_connected');
      await c.refresh();
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(c.view.status!.state, LastfmAccountState.notConnected);
    });

    // #7: the approval opens only on the tap's own page.
    test('the page closed while connect ran: no browser opens', () async {
      final rig = _Rig();
      rig.api.onStatus = () async => lastfmStatus(state: 'not_connected');
      final gate = Completer<LastfmAuthorization?>();
      rig.api.onConnect = () => gate.future;
      final c = await rig.start();
      final pending = c.connect();
      await settle();
      c.dispose();
      gate.complete(LastfmAuthorization.fromJson(
          {'authorization_url': fakeLastfmUrl}));
      await pending;
      await settle();
      expect(rig.browser.opened, isEmpty);
      rig.container.dispose();
    });

    // #1: finishing a reconnect (the server still says `enabled`).
    test('a reconnect waiting for its approval can be finished', () async {
      final rig = _rig(state: 'enabled', needsReconnect: true);
      rig.api.onStatus = () async => lastfmStatus(
        needsReconnect: true,
        approvalExpiresAt: 1800000600000,
        counts: null,
      );
      final c = await rig.start();
      expect(c.view.offer!.canFinish, isTrue);
      await c.finish();
      expect(rig.api.calls, contains('complete'));
    });
  });

  group('fix r1', () {
    // 9-R1-08: the action's own words survive a failing re-read; both are
    // shown, and Retry clears the action's words.
    test('action error + failing re-read: both texts; Retry clears it',
        () async {
      final rig = _rig(state: 'awaiting_authorization');
      final c = await rig.start();
      rig.api.onComplete = () async => throw lastfmApiError(
            409,
            'lastfm_account_mismatch',
            extra: {
              'stored_account': 'listener_01',
              'approved_account': 'other_02',
            },
          );
      rig.api.onStatus = () async => throw lastfmApiError(500, 'boom');
      await c.finish();
      await settle();
      expect(c.view.load, IntegrationsLoad.failed);
      expect(c.view.loadError, lastfmProblemText(LastfmProblem.failed));
      expect(c.message, contains(lastfmProblemText(LastfmProblem.accountMismatch)));
      expect(c.message, contains('listener_01'));
      expect(c.message, contains('other_02'));

      rig.api.onStatus = () async => lastfmStatus(state: 'enabled');
      await c.refresh();
      expect(c.message, isNull, reason: 'Retry clears the old action words');
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(c.message, isNull);
    });

    // U35-A-05 = U35-B-04: Retry from the failed state shows loading while
    // the new read runs (Riverpod 3 keeps the error while it reloads).
    test('Retry from failed shows loading until the read settles', () async {
      final rig = _rig();
      rig.api.onStatus = () async => throw lastfmApiError(500, 'boom');
      final c = await rig.start();
      expect(c.view.load, IntegrationsLoad.failed);
      final pending = Completer<LastfmStatus>();
      rig.api.onStatus = () => pending.future;
      await c.refresh();
      await settle();
      expect(c.view.load, IntegrationsLoad.loading);
      pending.complete(lastfmStatus(state: 'not_connected'));
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
    });

    // 9-R1-38: the binding not verified is a stable, explained state with
    // Retry, never an endless spinner.
    test('binding not verified: needs a connection, explained, not loading',
        () async {
      final rig = _rig();
      rig.api.onStatus = () async => throw const BindingNotVerified();
      final c = await rig.start();
      expect(c.view.load, IntegrationsLoad.failed);
      expect(c.view.loadError,
          lastfmProblemText(LastfmProblem.needsConnection));
    });

    // 9-R1-38: an action answered by another server ends (busy cleared)
    // with its own words, although the re-read then fails fast.
    test('an action answered by another server ends with its words',
        () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      rig.api.onDisconnect = () async => throw ServerInstanceChangedException(
          boundInstanceId: 'a', servedBy: 'b');
      // The gate now blocks as a different server (9-R2-04: its own words).
      rig.api.onStatus = () async =>
          throw const BindingNotVerified(BindingRefusal.differentServer);
      await c.disconnect();
      await settle();
      expect(c.busy, isFalse);
      expect(c.message, lastfmProblemText(LastfmProblem.serverChanged));
      expect(c.view.load, IntegrationsLoad.failed);
      expect(c.view.loadError,
          lastfmProblemText(LastfmProblem.differentServer));
    });

    // 9-R2-04: the page says what is true for each gate state.
    for (final (why, problem) in [
      (BindingRefusal.differentServer, LastfmProblem.differentServer),
      (BindingRefusal.noSession, LastfmProblem.signedOut),
      (BindingRefusal.notYet, LastfmProblem.needsConnection),
    ]) {
      test('binding refused ($why): the load error says ${problem.name}',
          () async {
        final rig = _rig();
        rig.api.onStatus = () async => throw BindingNotVerified(why);
        final c = await rig.start();
        expect(c.view.load, IntegrationsLoad.failed);
        expect(c.view.loadError, lastfmProblemText(problem));
      });
    }
  });

  group('fix r1 review', () {
    // R2-FE-02, refined by 9-R2-11: an action refused because the binding
    // is not verified says that nothing was changed, in words other than the
    // load error's (never the same text twice), and that survives the page
    // recovering by itself (9-R2-05): otherwise the tap silently did nothing.
    test('refused for no connection: nothing was changed, said once, kept',
        () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      rig.api.onDisconnect = () async => throw const BindingNotVerified();
      rig.api.onStatus = () async => throw const BindingNotVerified();
      await c.disconnect();
      await settle();
      expect(c.busy, isFalse);
      expect(c.view.load, IntegrationsLoad.failed);
      expect(c.view.loadError,
          lastfmProblemText(LastfmProblem.needsConnection));
      expect(c.message, _notSentYet);
      expect(c.message, isNot(c.view.loadError), reason: 'not said twice');

      rig.api.onStatus = () async => lastfmStatus(state: 'enabled');
      rig.api.verifyAgain();
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(c.message, _notSentYet);
    });

    // 9-R2-11: the gate verified between the refused tap and its re-read:
    // the page is known again, and the tap must not have silently done
    // nothing.
    test('refused, then the re-read succeeds: nothing was changed is said',
        () async {
      final rig = _rig(state: 'awaiting_authorization');
      final c = await rig.start();
      rig.api.onComplete = () async => throw const BindingNotVerified();
      await c.finish();
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(c.message, _notSentYet);
    });

    test('refused on a different server: nothing was changed, explained once',
        () async {
      final rig = _rig(state: 'enabled', needsReconnect: false);
      final c = await rig.start();
      const refused = BindingNotVerified(BindingRefusal.differentServer);
      rig.api.onDisconnect = () async => throw refused;
      rig.api.onStatus = () async => throw refused;
      await c.disconnect();
      await settle();
      expect(c.view.loadError,
          lastfmProblemText(LastfmProblem.differentServer));
      expect(c.message, 'Nothing was changed.');
    });

    // 9-R2-05 (coordinator decision): an automatic recovery (a status
    // re-read after reconnecting) never clears an action's result message;
    // it stays until the user acts again (a new action or Retry) or leaves
    // the page.
    test('an action message survives the account recovering by itself',
        () async {
      final rig = _rig(state: 'awaiting_authorization');
      final c = await rig.start();
      rig.api.onComplete = () async => throw lastfmApiError(
          409, 'lastfm_not_authorized_yet', retryable: true);
      rig.api.onStatus = () async => throw lastfmApiError(500, 'boom');
      await c.finish();
      await settle();
      expect(c.message, lastfmProblemText(LastfmProblem.notAuthorizedYet));

      rig.api.onStatus = () async => lastfmStatus(state: 'enabled');
      rig.api.verifyAgain();
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(c.message, lastfmProblemText(LastfmProblem.notAuthorizedYet));
    });

    test('the mismatch names survive a resume re-read', () async {
      final rig = _rig(state: 'awaiting_authorization');
      final c = await rig.start();
      rig.api.onComplete = () async => throw lastfmApiError(
            409,
            'lastfm_account_mismatch',
            extra: {
              'stored_account': 'listener_01',
              'approved_account': 'other_02',
            },
          );
      rig.api.onStatus = () async => throw const BindingNotVerified();
      await c.finish();
      await settle();
      final words = c.message;
      expect(words, contains('other_02'));

      rig.api.onStatus = () async => lastfmStatus(state: 'connected_disabled');
      rig.api.verifyAgain();
      await settle();
      expect(c.view.load, IntegrationsLoad.known);
      expect(c.message, words);

      await c.refresh();
      expect(c.message, isNull, reason: 'Retry is the user acting again');
    });
  });

  group('one action at a time', () {
    test('while one runs, others are ignored; busy is shown', () async {
      final rig = _rig(state: 'awaiting_authorization');
      final gate = Completer<LastfmCompleted?>();
      rig.api.onComplete = () => gate.future;
      final c = await rig.start();
      rig.api.calls.clear();
      final first = c.finish();
      await settle();
      expect(c.busy, isTrue);
      await c.connect();
      await c.disconnect();
      await c.finish();
      expect(rig.api.calls.where((x) => x != 'status'), ['complete']);
      gate.complete(null);
      await first;
      await settle();
      expect(c.busy, isFalse);
    });

    test('disposing while an action runs is harmless', () async {
      final rig = _Rig();
      rig.api.onStatus = () async =>
          lastfmStatus(state: 'awaiting_authorization');
      final gate = Completer<LastfmCompleted?>();
      rig.api.onComplete = () => gate.future;
      final c = await rig.start();
      final pending = c.finish();
      await settle();
      c.dispose();
      gate.complete(null);
      await pending;
      await settle();
      rig.container.dispose();
    });
  });

  group('links', () {
    test('credit, terms and privacy open their fixed links', () async {
      final rig = _rig();
      final c = await rig.start();
      await c.openCredit();
      await c.openTerms();
      await c.openPrivacy();
      expect(rig.browser.opened.map((u) => u.toString()), [
        'https://www.last.fm/',
        'https://www.last.fm/legal/terms',
        'https://www.last.fm/legal/privacy',
      ]);
    });

    test('the profile opens the connected account, percent-encoded', () async {
      final rig = _rig();
      rig.api.onStatus = () async =>
          lastfmStatus(state: 'enabled', account: 'DJ Example');
      final c = await rig.start();
      await c.openProfile();
      expect(rig.browser.opened.single.toString(),
          'https://www.last.fm/user/DJ%20Example');
    });

    test('no account name: the profile opens nothing', () async {
      final rig = _rig();
      rig.api.onStatus = () async =>
          lastfmStatus(state: 'enabled', account: null);
      final c = await rig.start();
      await c.openProfile();
      expect(rig.browser.opened, isEmpty);
    });

    test('links open while offline too (the browser needs no server)',
        () async {
      final rig = _rig(offline: true);
      final c = await rig.start();
      await c.openCredit();
      expect(rig.browser.opened, hasLength(1));
    });
  });
}
