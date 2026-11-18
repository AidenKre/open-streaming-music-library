// Phase 9D.2e S2: what the Integrations page offers in each combination of
// block, account state, server state, repair flag and connectivity, and
// OSML's words for each scrobble that did not go through.
//  * Spec §7.12: "When the block says available: false, the row shows only
//    for a user who still has a connection ..., and the page offers the
//    status and Disconnect." "... a reconnect prompt when needed, and
//    'Scrobbling is stopped on this server. Ask whoever runs it.' when
//    service is stopped."
//  * Spec §7.4: connect and complete work while `running`; enable while
//    `running` or `stopped`; disconnect always. §7.3: opt-in and
//    needs_reconnect are separate facts; enable is refused while
//    needs_reconnect is set.
//  * 9D.2d hand-over: offer Connect only when not connected or a reconnect
//    is needed (a healthy connection is never offered Connect), and connect
//    or finish only while online.
//  * Spec §7.4 status body: "The client maps each code to OSML's own
//    wording. Last.fm's free text is never stored or shown." §7.9 codes:
//    ignored 1/2 artist or title, 3/4 timestamp, 5 daily limit; dropped
//    too_many_tries / too_old / no_answer; failed = rejected alone.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/services/lastfm/lastfm_page_policy.dart';

import '../../helpers/fake_lastfm_api.dart' show lastfmStatus;

LastfmPageOffer _offer({
  String service = 'running',
  String state = 'not_connected',
  Object? needsReconnect,
  String? connectionId = 'c-1',
  bool available = true,
  bool online = true,
}) => LastfmPageOffer.of(
  status: lastfmStatus(
    service: service,
    state: state,
    needsReconnect: needsReconnect,
    connectionId: connectionId,
  ),
  available: available,
  online: online,
);

/// canConnect, canFinish, canOptIn, canDisconnect, showStopped,
/// showTurnedOff, showReconnect — as one comparable record.
(bool, bool, bool, bool, bool, bool, bool) _flags(LastfmPageOffer o) => (
  o.canConnect,
  o.canFinish,
  o.canOptIn,
  o.canDisconnect,
  o.showStopped,
  o.showTurnedOff,
  o.showReconnect,
);

const _t = true;
const _f = false;

void main() {
  group('available, running, online', () {
    test('not connected: Connect only', () {
      expect(_flags(_offer(state: 'not_connected')),
          (_t, _f, _f, _f, _f, _f, _f));
    });

    test('awaiting approval: Finish, Start again (Connect), Disconnect', () {
      expect(_flags(_offer(state: 'awaiting_authorization')),
          (_t, _t, _f, _t, _f, _f, _f));
    });

    test('connected, not opted in: opt-in and Disconnect, never Connect', () {
      expect(_flags(_offer(state: 'connected_disabled', needsReconnect: false)),
          (_f, _f, _t, _t, _f, _f, _f));
    });

    test('enabled and healthy: Disconnect only', () {
      expect(_flags(_offer(state: 'enabled', needsReconnect: false)),
          (_f, _f, _f, _t, _f, _f, _f));
    });

    test('enabled, needs reconnect: prompt and Reconnect', () {
      expect(_flags(_offer(state: 'enabled', needsReconnect: true)),
          (_t, _f, _f, _t, _f, _f, _t));
    });

    test('connected not opted in, needs reconnect: Reconnect, no opt-in', () {
      expect(_flags(_offer(state: 'connected_disabled', needsReconnect: true)),
          (_t, _f, _f, _t, _f, _f, _t));
    });

    test('connected with an unknown repair flag: neither opt-in nor Connect',
        () {
      for (final state in ['connected_disabled', 'enabled']) {
        expect(_flags(_offer(state: state, needsReconnect: null)),
            (_f, _f, _f, _t, _f, _f, _f), reason: state);
      }
    });

    test('connected without a connection ID: no opt-in', () {
      expect(
        _offer(
          state: 'connected_disabled',
          needsReconnect: false,
          connectionId: null,
        ).canOptIn,
        isFalse,
      );
    });

    // §7.5: the confirmation "shows the account name" before anything is
    // sent; with no plausible name known there is nothing to confirm.
    test('connected without an account name: no opt-in', () {
      expect(
        LastfmPageOffer.of(
          status: lastfmStatus(
            state: 'connected_disabled',
            needsReconnect: false,
            account: null,
          ),
          available: true,
          online: true,
        ).canOptIn,
        isFalse,
      );
    });

    test('an unknown account state: Disconnect only', () {
      expect(_flags(_offer(state: 'something_new')),
          (_f, _f, _f, _t, _f, _f, _f));
    });
  });

  // Review r1 #1 (blocker): while a session key exists the server keeps
  // answering `enabled`/`connected_disabled` during a reconnect; a pending
  // approval shows only as `approval_expires_at`. Finish must be offered
  // then, or a reconnect can never complete (§7.11: "approving the same
  // account repairs the connection and keeps the opt-in").
  group('a reconnect waiting for its approval', () {
    LastfmPageOffer pending({
      String service = 'running',
      String state = 'enabled',
      bool needsReconnect = true,
      bool available = true,
      bool online = true,
    }) => LastfmPageOffer.of(
      status: lastfmStatus(
        service: service,
        state: state,
        needsReconnect: needsReconnect,
        connectionId: 'c-1',
        approvalExpiresAt: 1800000600000,
        counts: null,
      ),
      available: available,
      online: online,
    );

    test('Finish, Reconnect and Disconnect are offered', () {
      for (final state in ['enabled', 'connected_disabled']) {
        expect(_flags(pending(state: state)), (_t, _t, _f, _t, _f, _f, _t),
            reason: state);
      }
    });

    test('a healthy connection with a stray token is not offered Finish', () {
      expect(_flags(pending(needsReconnect: false)),
          (_f, _f, _f, _t, _f, _f, _f));
    });

    test('offline, stopped or turned off: no Finish', () {
      expect(pending(online: false).canFinish, isFalse);
      expect(pending(service: 'stopped').canFinish, isFalse);
      expect(pending(available: false).canFinish, isFalse);
    });
  });

  group('server stopped (available)', () {
    test('shows stopped; no Connect or Finish; opt-in still works', () {
      expect(_flags(_offer(service: 'stopped', state: 'not_connected')),
          (_f, _f, _f, _f, _t, _f, _f));
      expect(_flags(_offer(service: 'stopped', state: 'awaiting_authorization')),
          (_f, _f, _f, _t, _t, _f, _f));
      expect(
        _flags(_offer(
          service: 'stopped',
          state: 'connected_disabled',
          needsReconnect: false,
        )),
        (_f, _f, _t, _t, _t, _f, _f),
      );
      expect(
        _flags(_offer(service: 'stopped', state: 'enabled', needsReconnect: true)),
        (_f, _f, _f, _t, _t, _f, _t),
      );
    });

    test('an unknown server state offers nothing that needs Last.fm', () {
      final o = _offer(
        service: 'rebooting',
        state: 'connected_disabled',
        needsReconnect: false,
      );
      expect(_flags(o), (_f, _f, _f, _t, _f, _f, _f));
      expect(_offer(service: 'rebooting').canConnect, isFalse);
    });
  });

  // Review r1 #4: an invalid configuration gives `available: false` with
  // `service: stopped`; the page then says "stopped" (the operator must act),
  // not also "turned off".
  group('block says available: false: status and Disconnect only', () {
    for (final service in ['off', 'stopped', 'running']) {
      test('service $service', () {
        expect(
          _flags(_offer(
            available: false,
            service: service,
            state: 'not_connected',
          )),
          (_f, _f, _f, _f, service == 'stopped', service != 'stopped', _f),
        );
        expect(
          _flags(_offer(
            available: false,
            service: service,
            state: 'awaiting_authorization',
          )),
          (_f, _f, _f, _t, service == 'stopped', service != 'stopped', _f),
        );
        expect(
          _flags(_offer(
            available: false,
            service: service,
            state: 'connected_disabled',
            needsReconnect: false,
          )),
          (_f, _f, _f, _t, service == 'stopped', service != 'stopped', _f),
        );
        expect(
          _flags(_offer(
            available: false,
            service: service,
            state: 'enabled',
            needsReconnect: true,
          )),
          (_f, _f, _f, _t, service == 'stopped', service != 'stopped', _t),
        );
      });
    }

    test('a server answering off while the block said available is turned '
        'off too', () {
      expect(
        _flags(_offer(
          service: 'off',
          state: 'connected_disabled',
          needsReconnect: false,
        )),
        (_f, _f, _f, _t, _f, _t, _f),
      );
    });
  });

  group('offline: nothing that needs the server', () {
    for (final (state, reconnect) in [
      ('not_connected', null),
      ('awaiting_authorization', null),
      ('connected_disabled', false),
      ('enabled', false),
      ('enabled', true),
    ]) {
      test('$state (needs_reconnect $reconnect)', () {
        final o = _offer(state: state, needsReconnect: reconnect, online: false);
        expect(
          (o.canConnect, o.canFinish, o.canOptIn, o.canDisconnect),
          (_f, _f, _f, _f),
        );
        expect(o.showReconnect, reconnect == true);
      });
    }

    test('stopped with the block off still shows stopped offline', () {
      final o = _offer(
        service: 'stopped',
        available: false,
        state: 'enabled',
        needsReconnect: false,
        online: false,
      );
      expect((o.showStopped, o.showTurnedOff), (_t, _f));
    });
  });

  group('reasons for scrobbles that did not go through', () {
    LastfmProblemRow row(String status, String? code) => LastfmProblemRow(
      artist: 'A',
      track: 'T',
      listenedAt: 0,
      status: status,
      code: code,
    );

    const table = <(String, String?), String>{
      ('ignored', '1'): 'Last.fm ignored it because of the artist name.',
      ('ignored', '2'): 'Last.fm ignored it because of the track title.',
      ('ignored', '3'):
          'Last.fm ignored it because the listen was too long ago.',
      ('ignored', '4'):
          'Last.fm ignored it because the listen time was too far ahead.',
      ('ignored', '5'):
          'Last.fm ignored it because the account reached its daily '
          'scrobble limit.',
      ('ignored', '99'): 'Last.fm ignored it.',
      ('ignored', null): 'Last.fm ignored it.',
      ('failed', '13'): 'Last.fm refused it.',
      ('failed', '6'): 'Last.fm refused it.',
      ('failed', null): 'Last.fm refused it.',
      // 9-fix-r1-be review #4: refused by the server itself, never sent.
      ('failed', 'invalid_row'):
          "Not sent: OSML couldn't send this listen to Last.fm.",
      ('dropped', 'too_old'):
          'Not sent: it was more than 14 days old before it could be sent.',
      ('dropped', 'too_many_tries'):
          'Not sent: Last.fm gave no clear answer after 10 tries.',
      ('dropped', 'no_answer'):
          "Last.fm's reply didn't mention it, so it may not have been "
          'recorded.',
      ('dropped', 'whatever'): 'Not sent.',
      ('dropped', null): 'Not sent.',
      ('exploded', '1'): "It didn't go through.",
    };
    for (final MapEntry(key: (status, code), value: text) in table.entries) {
      test('$status / $code', () {
        expect(lastfmProblemReason(row(status, code)), text);
      });
    }

    test('a code carrying server text is never echoed', () {
      const hostile = '<b>Invalid signature: visit evil.example</b>';
      for (final status in ['ignored', 'failed', 'dropped', 'other']) {
        final text = lastfmProblemReason(row(status, hostile));
        expect(text, isNot(contains('evil')));
        expect(text, isNot(contains('<')));
      }
    });
  });
}
