// What the Integrations page may offer, and OSML's words for a scrobble that
// did not go through (spec §7.4, §7.5, §7.9, §7.12). Pure functions of the
// model's status; no ui/ import.
import 'package:flutter/foundation.dart';

import 'package:frontend/models/dto/lastfm_dtos.dart';

@immutable
class LastfmPageOffer {
  const LastfmPageOffer({
    required this.canConnect,
    required this.canFinish,
    required this.canOptIn,
    required this.canDisconnect,
    required this.showStopped,
    required this.showTurnedOff,
    required this.showReconnect,
  });

  /// Connect (or Reconnect / Start again): only when not connected, waiting
  /// for an approval, or the connection needs repairing; the block says
  /// `available`, the server is `running`, and the app is online.
  final bool canConnect;

  /// Finish connecting: an approval is awaited (the state says so, or a
  /// reconnect is pending: the server keeps answering `enabled` /
  /// `connected_disabled` then, and only `approval_expires_at` shows it),
  /// `available`, `running`, online.
  final bool canFinish;

  /// The opt-in confirmation (`enable`): connected but not opted in, no
  /// repair needed, a connection ID and an account name known, `available`, the server
  /// `running` or `stopped`, online.
  final bool canOptIn;

  /// Disconnect: anything is stored (any state but not connected), online.
  /// Works in every server state, the block's `available` included.
  final bool canDisconnect;

  /// `service` is `stopped`: "Scrobbling is stopped on this server. Ask
  /// whoever runs it."
  final bool showStopped;

  /// The block says `available: false` or the server says `off`; not shown
  /// when the server is `stopped` (only "stopped" is said then).
  final bool showTurnedOff;

  /// A connected account whose connection needs repairing.
  final bool showReconnect;

  static LastfmPageOffer of({
    required LastfmStatus status,
    required bool available,
    required bool online,
  }) {
    final service = status.service;
    final state = status.state;
    final turnedOff = !available || service == LastfmServerState.off;
    final live = online && !turnedOff;
    final running = service == LastfmServerState.running;
    final reconnect = status.isConnected && status.needsReconnect == true;
    return LastfmPageOffer(
      canConnect:
          live &&
          running &&
          (state == LastfmAccountState.notConnected ||
              state == LastfmAccountState.awaitingAuthorization ||
              reconnect),
      canFinish:
          live &&
          running &&
          (state == LastfmAccountState.awaitingAuthorization ||
              (reconnect && status.approvalExpiresAt != null)),
      canOptIn:
          live &&
          (running || service == LastfmServerState.stopped) &&
          state == LastfmAccountState.connectedDisabled &&
          status.needsReconnect == false &&
          status.connectionId != null &&
          status.accountName != null,
      canDisconnect: online && state != LastfmAccountState.notConnected,
      showStopped: service == LastfmServerState.stopped,
      showTurnedOff: turnedOff && service != LastfmServerState.stopped,
      showReconnect: reconnect,
    );
  }
}

/// OSML's plain reason for one row of the "did not go through" list. Never
/// shows the raw code or any text from the server.
String lastfmProblemReason(LastfmProblemRow row) => switch (row.status) {
  'ignored' => switch (row.code) {
    '1' => 'Last.fm ignored it because of the artist name.',
    '2' => 'Last.fm ignored it because of the track title.',
    '3' => 'Last.fm ignored it because the listen was too long ago.',
    '4' => 'Last.fm ignored it because the listen time was too far ahead.',
    '5' =>
      'Last.fm ignored it because the account reached its daily '
          'scrobble limit.',
    _ => 'Last.fm ignored it.',
  },
  // invalid_row: the server refused the row itself; it was never sent.
  'failed' =>
    row.code == 'invalid_row'
        ? "Not sent: OSML couldn't send this listen to Last.fm."
        : 'Last.fm refused it.',
  'dropped' => switch (row.code) {
    'too_old' =>
      'Not sent: it was more than 14 days old before it could be sent.',
    'too_many_tries' => 'Not sent: Last.fm gave no clear answer after 10 tries.',
    'no_answer' =>
      "Last.fm's reply didn't mention it, so it may not have been recorded.",
    _ => 'Not sent.',
  },
  _ => "It didn't go through.",
};
