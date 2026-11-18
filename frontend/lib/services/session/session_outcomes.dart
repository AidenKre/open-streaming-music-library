/// What a launch, a manual connect and a sign-in can answer. Value types
/// only; re-exported by `session_service.dart`.
library;

enum SessionStartKind {
  serverAddress,

  /// A saved URL and no stored credentials (spec 7.1): the Log in screen,
  /// also offline. Nothing is sent.
  logIn,

  /// The stored credentials could not be read (unknown, not absent): a retry
  /// state, never Log in.
  credentialsUnavailable,
  online,
  offline,

  /// Launch finished a reset that had been interrupted (review major 2):
  /// local data is wiped and nothing is signed in. Like any finished reset,
  /// the provider scope is rebuilt next.
  resetFinished,
}

/// How a launch with (or without) a saved server URL starts.
class SessionStart {
  const SessionStart(this.kind, {this.error, this.serverUrl});
  final SessionStartKind kind;

  /// The saved server URL, for the Log in screen.
  final String? serverUrl;

  /// Shown on the login screen when the saved server rejected us.
  final String? error;
}

/// The result of a manual connect (login).
sealed class ConnectOutcome {
  const ConnectOutcome();
}

/// The URL passed the health and identity checks and is saved; the app goes
/// to Log in.
final class ConnectSucceeded extends ConnectOutcome {
  const ConnectSucceeded([this.url]);

  /// The saved server URL (shown on Log in).
  final String? url;
}

/// Not connected; [message] is shown on the login screen.
final class ConnectFailed extends ConnectOutcome {
  const ConnectFailed(this.message);
  final String message;
}

/// The server at [url] is a different instance from the one this library is
/// bound to (SC-01 rule 1): connecting needs a confirmed local reset first
/// (`SessionService.resetForNewServer`). Nothing was saved or changed.
final class ConnectDifferentServer extends ConnectOutcome {
  const ConnectDifferentServer(this.url);
  final String url;
}

/// The result of a login or registration (spec 7.5).
sealed class SignInOutcome {
  const SignInOutcome();
}

/// Stored, bound, and the scope rebuilt for the signed-in user.
final class SignInSucceeded extends SignInOutcome {
  const SignInSucceeded();
}

/// Nothing stored; [message] is shown (the server's SC-22 message when it
/// sent one).
final class SignInFailed extends SignInOutcome {
  const SignInFailed(this.message);
  final String message;
}

/// Same server, another user than the one this device's data belongs to:
/// the sign-in is held in memory until the user confirms the reset.
final class SignInNeedsUserSwitch extends SignInOutcome {
  const SignInNeedsUserSwitch(this.username);
  final String username;
}

/// The server at [url] is a different instance than the bound one: the
/// sign-in is held in memory until the different-server reset is confirmed.
final class SignInDifferentServer extends SignInOutcome {
  const SignInDifferentServer(this.url);
  final String url;
}
