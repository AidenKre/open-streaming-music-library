// The one error home of the Last.fm model (SC-22): every failure becomes a
// typed [LastfmException]; the user reads OSML's own words for it, never the
// server's text or code.
import 'dart:async';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/authenticated_client.dart';
import 'package:frontend/api/gated_send.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';
import 'package:frontend/repositories/server_binding_repository.dart';

enum LastfmProblem {
  notOffered,
  disabled,
  stopped,
  unavailable,
  tooSoon,
  notAuthorizedYet,
  approvalExpired,
  accountMismatch,
  notConnected,
  connectionChanged,
  reconnectRequired,
  timedOut,
  unreachable,
  serverChanged,
  needsConnection,
  differentServer,
  signedOut,
  badAnswer,
  failed,
}

class LastfmException implements Exception {
  const LastfmException(
    this.problem, {
    this.retryable = false,
    this.storedAccount,
    this.approvedAccount,
  });

  final LastfmProblem problem;
  final bool retryable;
  final String? storedAccount;
  final String? approvedAccount;

  static LastfmException from(Object error) {
    if (error is LastfmException) return error;
    if (error is ApiException) {
      final retryable = error.retryable ?? false;
      final problem = switch (error.errorCode) {
        'lastfm_disabled' => LastfmProblem.disabled,
        'lastfm_stopped' => LastfmProblem.stopped,
        'lastfm_unavailable' => LastfmProblem.unavailable,
        'lastfm_too_soon' => LastfmProblem.tooSoon,
        'lastfm_not_authorized_yet' => LastfmProblem.notAuthorizedYet,
        'lastfm_approval_expired' => LastfmProblem.approvalExpired,
        'lastfm_account_mismatch' => LastfmProblem.accountMismatch,
        'lastfm_not_connected' => LastfmProblem.notConnected,
        'lastfm_connection_changed' => LastfmProblem.connectionChanged,
        'lastfm_reconnect_required' => LastfmProblem.reconnectRequired,
        _ => LastfmProblem.failed,
      };
      if (problem == LastfmProblem.accountMismatch) {
        final details = error.details;
        return LastfmException(
          problem,
          retryable: retryable,
          storedAccount: plausibleLastfmAccountName(details?['stored_account']),
          approvedAccount: plausibleLastfmAccountName(
            details?['approved_account'],
          ),
        );
      }
      return LastfmException(problem, retryable: retryable);
    }
    if (error is NetworkException) {
      return LastfmException(
        error.cause is TimeoutException
            ? LastfmProblem.timedOut
            : LastfmProblem.unreachable,
      );
    }
    if (error is BindingNotVerified) {
      return LastfmException(switch (error.reason) {
        BindingRefusal.differentServer => LastfmProblem.differentServer,
        BindingRefusal.noSession => LastfmProblem.signedOut,
        BindingRefusal.notYet => LastfmProblem.needsConnection,
      });
    }
    if (error is ServerInstanceChangedException) {
      return const LastfmException(LastfmProblem.serverChanged);
    }
    // A request the token client withheld (not verified, or offline) needs a
    // connection (sign-off OPEN-M-11, E9).
    if (error is TokenWithheldException) {
      return const LastfmException(LastfmProblem.needsConnection);
    }
    return const LastfmException(LastfmProblem.failed);
  }

  @override
  String toString() => 'LastfmException(${problem.name})';
}

/// What Finish connecting says when the server answers that it came too
/// soon: its own per-user cooldown of one Last.fm gate gap
/// (`LASTFM_MIN_REQUEST_GAP_S`, default 5 s; sign-off OPEN-9-03), apart from
/// Connect's 30 s one; the two share only the error code
/// (`lastfm_too_soon`). The owner's words (2026-11-17); Connect keeps
/// [lastfmProblemText]'s.
const lastfmFinishTooSoonText = 'Waiting on Last.fm.';

String lastfmProblemText(LastfmProblem problem) => switch (problem) {
  LastfmProblem.notOffered => "This server doesn't offer Last.fm scrobbling.",
  LastfmProblem.disabled => 'Last.fm scrobbling is turned off on this server.',
  LastfmProblem.stopped =>
    'Scrobbling is stopped on this server. Ask whoever runs it.',
  LastfmProblem.unavailable => "Last.fm didn't answer. Try again in a moment.",
  LastfmProblem.tooSoon => 'Wait a moment before connecting again.',
  LastfmProblem.notAuthorizedYet =>
    "Last.fm hasn't seen your approval yet. Approve on last.fm, then tap Finish connecting.",
  LastfmProblem.approvalExpired =>
    'The approval expired or was already used. Start connecting again.',
  LastfmProblem.accountMismatch =>
    'You approved a different Last.fm account than the one connected. To switch accounts, disconnect first, then connect again.',
  LastfmProblem.notConnected => "Last.fm isn't connected.",
  LastfmProblem.connectionChanged =>
    'Your Last.fm connection changed. Check the account and confirm again.',
  LastfmProblem.reconnectRequired =>
    'Last.fm needs you to reconnect your account.',
  LastfmProblem.timedOut => "The server didn't answer in time. Try again.",
  LastfmProblem.unreachable => "Can't reach your server right now.",
  LastfmProblem.serverChanged =>
    'A different server answered. Nothing was changed.',
  LastfmProblem.needsConnection =>
    'Last.fm settings need a connection to your server. '
        'They load again once the app reconnects.',
  LastfmProblem.differentServer =>
    "A different server answers at this address now, so Last.fm settings can't load here.",
  LastfmProblem.signedOut =>
    "You're not signed in to this server, so Last.fm settings can't load. Sign in again.",
  LastfmProblem.badAnswer => "The server sent an answer the app can't use.",
  LastfmProblem.failed => 'Something went wrong. Try again.',
};
