// Phase 9D.2d (spec §7.4, 9D.1d/9D.2a hand-overs): the Last.fm wire shapes.
//  * status body `{service, state, needs_reconnect, account_name,
//    connection_id, approval_expires_at, counts, recent_problems,
//    last_success_at}`: nulls stay null; a count that is missing or not a
//    non-negative int is unknown (null), never 0 (unknown is not zero);
//    an unrecognized `service`/`state` is `unknown`, never a guess;
//  * a hostile or broken answer never throws out of parsing and is never
//    shown as given: implausible account names (empty, over 64 characters,
//    control/format/separator characters) are dropped, malformed problem
//    rows are skipped, at most 20 rows are kept;
//  * `connect`'s `{authorization_url, expires_at}` is usable only when the
//    URL passes the §7.4 validator; `complete`'s `{connection_id,
//    account_name, state}` only when complete and plausible.
//
// Every value below is made up.
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';

const _key = '0123456789abcdef0123456789abcdef';
const _token = 'made-up-token';
const _url = 'https://www.last.fm/api/auth/?api_key=$_key&token=$_token';

Map<String, dynamic> _status({
  Object? service = 'running',
  Object? state = 'enabled',
  Object? needsReconnect = false,
  Object? accountName = 'listener_01',
  Object? connectionId = 'c0ffee00-0000-4000-8000-000000000001',
  Object? approvalExpiresAt,
  Object? counts = const {
    'pending': 2,
    'sent': 40,
    'ignored': 1,
    'failed': 0,
    'dropped': 3,
  },
  Object? recentProblems = const [],
  Object? lastSuccessAt = 1800000000000,
}) => {
  'service': service,
  'state': state,
  'needs_reconnect': needsReconnect,
  'account_name': accountName,
  'connection_id': connectionId,
  'approval_expires_at': approvalExpiresAt,
  'counts': counts,
  'recent_problems': recentProblems,
  'last_success_at': lastSuccessAt,
};

Map<String, dynamic> _problem({
  Object? artist = 'Sigur Rós',
  Object? track = 'Hoppípolla',
  Object? listenedAt = 1799990000000,
  Object? status = 'ignored',
  Object? code = '1',
}) => {
  'artist': artist,
  'track': track,
  'listened_at': listenedAt,
  'status': status,
  'code': code,
};

void main() {
  // signoff-9-lastfm-app-name (DEV-9-06; spec §7.5): `app_name`, the name the
  // operator registered on last.fm. Missing (an older server), null, not a
  // string, blank, over 100 characters or with a control, format, surrogate or
  // separator character: not provided (null). Otherwise kept, trimmed.
  group('status app_name', () {
    test('missing (an older server) is not provided, and nothing throws', () {
      final s = LastfmStatus.fromJson(_status());
      expect(s.appName, isNull);
      expect(s.accountName, 'listener_01');
      expect(LastfmStatus.fromJson(const {}).appName, isNull);
    });

    test('null or not a string is not provided', () {
      for (final odd in <Object?>[null, 42, true, ['OSML'], {'a': 1}]) {
        expect(
          LastfmStatus.fromJson({..._status(), 'app_name': odd}).appName,
          isNull,
          reason: '$odd',
        );
      }
    });

    test('a plausible name is kept, trimmed', () {
      for (final (raw, kept) in [
        ('OSML at Home', 'OSML at Home'),
        ('  OSML at Home  ', 'OSML at Home'),
        ('Musik für alle – 音楽', 'Musik für alle – 音楽'),
        ('a' * 100, 'a' * 100),
        ('é' * 100, 'é' * 100),
        ('🎵' * 100, '🎵' * 100), // 100 runes, 200 UTF-16 units
        ('<b>bold</b> [link](https://e.example)', '<b>bold</b> [link](https://e.example)'),
      ]) {
        expect(
          LastfmStatus.fromJson({..._status(), 'app_name': raw}).appName,
          kept,
        );
      }
    });

    test('a blank or implausible name is not provided', () {
      for (final odd in <Object?>[
        '',
        '   ',
        'a' * 101,
        'é' * 101,
        '🎵' * 101,
        'lone\uD800', // Cs
        'evil\u202Eeman', // Cf
        'zero\u200Bwidth', // Cf
        'line\u2028sep', // Zl
        'para\u2029sep', // Zp
        'new\nline', // Cc
        'nul\u0000', // Cc
      ]) {
        expect(
          LastfmStatus.fromJson({..._status(), 'app_name': odd}).appName,
          isNull,
          reason: '$odd',
        );
      }
    });
  });

  group('status body', () {
    test('a connected, enabled user parses field by field', () {
      final s = LastfmStatus.fromJson(_status(
        recentProblems: [_problem()],
      ));
      expect(s.service, LastfmServerState.running);
      expect(s.state, LastfmAccountState.enabled);
      expect(s.needsReconnect, isFalse);
      expect(s.accountName, 'listener_01');
      expect(s.connectionId, 'c0ffee00-0000-4000-8000-000000000001');
      expect(s.approvalExpiresAt, isNull);
      expect(s.counts.pending, 2);
      expect(s.counts.sent, 40);
      expect(s.counts.ignored, 1);
      expect(s.counts.failed, 0);
      expect(s.counts.dropped, 3);
      expect(s.lastSuccessAt, 1800000000000);
      expect(s.recentProblems, hasLength(1));
      final p = s.recentProblems.single;
      expect(p.artist, 'Sigur Rós');
      expect(p.track, 'Hoppípolla');
      expect(p.listenedAt, 1799990000000);
      expect(p.status, 'ignored');
      expect(p.code, '1');
      expect(s.isConnected, isTrue);
    });

    test('every service and state value maps; anything else is unknown', () {
      const services = {
        'off': LastfmServerState.off,
        'running': LastfmServerState.running,
        'stopped': LastfmServerState.stopped,
      };
      for (final e in services.entries) {
        expect(LastfmStatus.fromJson(_status(service: e.key)).service, e.value);
      }
      const states = {
        'not_connected': LastfmAccountState.notConnected,
        'awaiting_authorization': LastfmAccountState.awaitingAuthorization,
        'connected_disabled': LastfmAccountState.connectedDisabled,
        'enabled': LastfmAccountState.enabled,
      };
      for (final e in states.entries) {
        expect(LastfmStatus.fromJson(_status(state: e.key)).state, e.value);
      }
      for (final odd in <Object?>[null, 1, 'ENABLED', 'paused', true]) {
        expect(LastfmStatus.fromJson(_status(service: odd)).service,
            LastfmServerState.unknown, reason: '$odd');
        expect(LastfmStatus.fromJson(_status(state: odd)).state,
            LastfmAccountState.unknown, reason: '$odd');
      }
    });

    test('isConnected only for connected_disabled and enabled', () {
      for (final (state, connected) in [
        ('not_connected', false),
        ('awaiting_authorization', false),
        ('connected_disabled', true),
        ('enabled', true),
        ('mystery', false),
      ]) {
        expect(LastfmStatus.fromJson(_status(state: state)).isConnected,
            connected, reason: state);
      }
    });

    test('a user who never connected: nulls stay null, counts 0 as sent', () {
      final s = LastfmStatus.fromJson(_status(
        state: 'not_connected',
        needsReconnect: null,
        accountName: null,
        connectionId: null,
        counts: {'pending': 0, 'sent': 0, 'ignored': 0, 'failed': 0, 'dropped': 0},
        lastSuccessAt: null,
      ));
      expect(s.needsReconnect, isNull);
      expect(s.accountName, isNull);
      expect(s.connectionId, isNull);
      expect(s.lastSuccessAt, isNull);
      expect(s.counts.pending, 0);
      expect(s.counts.dropped, 0);
      expect(s.recentProblems, isEmpty);
    });

    test('awaiting authorization carries the approval expiry', () {
      final s = LastfmStatus.fromJson(_status(
        state: 'awaiting_authorization',
        approvalExpiresAt: 1800000600000,
      ));
      expect(s.approvalExpiresAt, 1800000600000);
    });

    test('a missing or malformed count is unknown (null), never 0', () {
      final s = LastfmStatus.fromJson(_status(counts: {
        'pending': -1,
        'sent': '4',
        'ignored': 1.5,
        'failed': null,
        // dropped missing
      }));
      expect(s.counts.pending, isNull);
      expect(s.counts.sent, isNull);
      expect(s.counts.ignored, isNull);
      expect(s.counts.failed, isNull);
      expect(s.counts.dropped, isNull);
      for (final odd in <Object?>[null, 'x', 3, const []]) {
        final c = LastfmStatus.fromJson(_status(counts: odd)).counts;
        expect([c.pending, c.sent, c.ignored, c.failed, c.dropped],
            everyElement(isNull), reason: '$odd');
      }
    });

    test('wrong-typed scalar fields are unknown, not coerced', () {
      final s = LastfmStatus.fromJson(_status(
        needsReconnect: 'false',
        connectionId: 7,
        approvalExpiresAt: '1800000600000',
        lastSuccessAt: 1.0,
      ));
      expect(s.needsReconnect, isNull);
      expect(s.connectionId, isNull);
      expect(s.approvalExpiresAt, isNull);
      expect(s.lastSuccessAt, isNull);
    });

    test('an implausible account name is dropped, a plausible one kept', () {
      for (final odd in <Object?>[
        '',
        'a' * 65,
        'evil\u202Eeman', // right-to-left override (Cf)
        'zero\u200Bwidth', // zero-width space (Cf)
        'line\u2028sep', // Zl
        'para\u2029sep', // Zp
        'tab\there', // Cc
        'nul\u0000', // Cc
        42,
      ]) {
        expect(LastfmStatus.fromJson(_status(accountName: odd)).accountName,
            isNull, reason: '$odd');
      }
      for (final ok in ['a' * 64, 'RJ', 'Ünïcødé-名前', 'with space']) {
        expect(LastfmStatus.fromJson(_status(accountName: ok)).accountName,
            ok);
      }
    });

    // Owner's decision 2026-11-17 (guide 6.2, R-332-09): `.` and `..` are
    // not account names (a profile link would leave the user path).
    test('"." and ".." are refused as account names; other dotted names '
        'are kept', () {
      for (final odd in ['.', '..']) {
        expect(plausibleLastfmAccountName(odd), isNull, reason: odd);
        expect(LastfmStatus.fromJson(_status(accountName: odd)).accountName,
            isNull, reason: odd);
        expect(
          LastfmCompleted.fromJson({
            'connection_id': 'x',
            'account_name': odd,
            'state': 'enabled',
          }),
          isNull,
          reason: odd,
        );
      }
      for (final ok in ['...', '.a', 'a.', 'a.b']) {
        expect(plausibleLastfmAccountName(ok), ok);
      }
    });

    // The server lists a damaged listen with artist and
    // track null. Unknown is not "none": the row is kept, its names unknown.
    test('a damaged row (artist and track null) is kept, its names unknown',
        () {
      final s = LastfmStatus.fromJson(_status(recentProblems: [
        _problem(artist: null, track: null, status: 'failed', code: null),
      ]));
      expect(s.recentProblems, hasLength(1));
      final p = s.recentProblems.single;
      expect(p.artist, isNull);
      expect(p.track, isNull);
      expect(p.listenedAt, 1799990000000);
      expect(p.status, 'failed');
      expect(p.code, isNull);
    });

    test('malformed problem rows are skipped; at most 20 are kept', () {
      final s = LastfmStatus.fromJson(_status(recentProblems: [
        _problem(artist: 3),
        _problem(track: 3),
        _problem(listenedAt: '1'),
        _problem(status: null),
        'not a row',
        null,
        _problem(code: null), // a row without a code is still a row
        for (var i = 0; i < 25; i++) _problem(track: 'T$i'),
      ]));
      expect(s.recentProblems, hasLength(20));
      expect(s.recentProblems.first.code, isNull);
      expect(s.recentProblems.first.track, 'Hoppípolla');
      expect(s.recentProblems[1].track, 'T0');
      expect(s.recentProblems.last.track, 'T18');
    });

    test('recent_problems that is not a list is empty', () {
      for (final odd in <Object?>[null, 'x', {'a': 1}]) {
        expect(LastfmStatus.fromJson(_status(recentProblems: odd))
            .recentProblems, isEmpty, reason: '$odd');
      }
    });

    test('an empty body parses to unknowns without throwing', () {
      final s = LastfmStatus.fromJson(const {});
      expect(s.service, LastfmServerState.unknown);
      expect(s.state, LastfmAccountState.unknown);
      expect(s.isConnected, isFalse);
      expect(s.counts.sent, isNull);
    });
  });

  group('connect answer', () {
    test('a valid authorization URL and expiry', () {
      final a = LastfmAuthorization.fromJson(
          {'authorization_url': _url, 'expires_at': 1800000600000});
      expect(a, isNotNull);
      expect(a!.url.uri.queryParameters['token'], _token);
      expect(a.expiresAt, 1800000600000);
    });

    test('a missing or malformed expiry is unknown', () {
      final a = LastfmAuthorization.fromJson(
          {'authorization_url': _url, 'expires_at': 'soon'});
      expect(a!.expiresAt, isNull);
    });

    test('an answer whose URL fails the validator is refused', () {
      for (final odd in <Object?>[
        null,
        42,
        'https://evil.example/api/auth/?api_key=$_key&token=$_token',
        '$_url#frag',
      ]) {
        expect(LastfmAuthorization.fromJson(
                {'authorization_url': odd, 'expires_at': 1}),
            isNull, reason: '$odd');
      }
    });

    test('the parsed value never prints the URL or the token', () {
      final a = LastfmAuthorization.fromJson(
          {'authorization_url': _url, 'expires_at': 1})!;
      expect('$a'.contains(_token), isFalse);
      expect('$a'.contains(_key), isFalse);
    });
  });

  group('complete answer', () {
    test('the 9D.1d body parses', () {
      final c = LastfmCompleted.fromJson({
        'connection_id': 'c0ffee00-0000-4000-8000-000000000002',
        'account_name': 'listener_01',
        'state': 'connected_disabled',
      });
      expect(c!.connectionId, 'c0ffee00-0000-4000-8000-000000000002');
      expect(c.accountName, 'listener_01');
      expect(c.state, LastfmAccountState.connectedDisabled);
    });

    test('a same-account repair can answer enabled', () {
      expect(LastfmCompleted.fromJson({
        'connection_id': 'x',
        'account_name': 'listener_01',
        'state': 'enabled',
      })!.state, LastfmAccountState.enabled);
    });

    test('missing, malformed or implausible fields: refused', () {
      for (final body in <Map<String, dynamic>>[
        {},
        {'account_name': 'a', 'state': 'enabled'},
        {'connection_id': '', 'account_name': 'a', 'state': 'enabled'},
        {'connection_id': 'x', 'state': 'enabled'},
        {'connection_id': 'x', 'account_name': 'a\u202Eb', 'state': 'enabled'},
        {'connection_id': 'x', 'account_name': 'a', 'state': 'not_connected'},
        {'connection_id': 'x', 'account_name': 'a', 'state': 'mystery'},
        {'connection_id': 1, 'account_name': 'a', 'state': 'enabled'},
      ]) {
        expect(LastfmCompleted.fromJson(body), isNull, reason: '$body');
      }
    });
  });
}
