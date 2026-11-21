import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/session_service.dart';

/// A scripted [SessionService] for controller and widget tests. It
/// implements the interface and shares no code with the real class: every
/// answer comes from the fields below, and nothing is read, stored or sent.
/// The session rules themselves are tested on the real class
/// (`test/services/session_*_test.dart`).
class FakeSessionService implements SessionService {
  FakeSessionService({
    this.start = const SessionStart(SessionStartKind.serverAddress),
  });

  /// What a user asked for after launch, in order: `login <name>`,
  /// `register <name>`, `confirmPendingSignIn`, `cancelPendingSignIn`,
  /// `resetForNewServer <url>`, `resetLocalData`, `logout`, `logout keep`,
  /// `reloadSession`, `forgetStoredSignIn`. Launch, connect, the
  /// blocked-server reset, a library sync and the reads are counted by their
  /// own fields instead.
  final calls = <String>[];

  // Launch.
  SessionStart start;

  /// When set, launch throws it (a storage fault).
  Object? startError;
  int starts = 0;

  @override
  Future<SessionStart> resumeSavedSession() async {
    starts++;
    if (startError != null) throw startError!;
    return start;
  }

  // Connect.
  String? connectError;
  bool differentServer = false;

  /// When set, connect throws it (a storage fault).
  Object? connectThrows;

  /// When set, [connect] waits for it.
  Completer<void>? connectGate;
  int connects = 0;

  @override
  Future<ConnectOutcome> connect(String url) async {
    connects++;
    await connectGate?.future;
    if (connectThrows != null) throw connectThrows!;
    if (differentServer) return ConnectDifferentServer(url);
    final error = connectError;
    return error == null ? ConnectSucceeded(url) : ConnectFailed(error);
  }

  // Sign-in.
  SignInOutcome outcome = const SignInSucceeded();

  /// When set, [login] waits for it.
  Completer<void>? signInGate;

  /// When set, [login] and [register] throw it (a storage fault after the
  /// server answered).
  Object? signInThrows;

  @override
  Future<SignInOutcome> login(String username, String password) async {
    calls.add('login $username');
    await signInGate?.future;
    if (signInThrows != null) throw signInThrows!;
    return outcome;
  }

  @override
  Future<SignInOutcome> register(String username, String password) async {
    calls.add('register $username');
    if (signInThrows != null) throw signInThrows!;
    return outcome;
  }

  @override
  Future<void> cancelPendingSignIn() async => calls.add('cancelPendingSignIn');

  // Resets. One gate, one result and one fault for all of them.

  /// When set, every reset waits for it.
  Completer<void>? resetGate;
  LocalResetException? resetFailure;

  /// When set, [resetLocalData] throws it (a storage fault).
  Object? resetThrows;
  int resets = 0;
  int blockedResets = 0;
  final switchedTo = <String>[];

  @override
  Future<LocalResetException?> confirmPendingSignIn() async {
    calls.add('confirmPendingSignIn');
    await resetGate?.future;
    return resetFailure;
  }

  @override
  Future<LocalResetException?> resetLocalData() async {
    calls.add('resetLocalData');
    resets++;
    await resetGate?.future;
    if (resetThrows != null) throw resetThrows!;
    return resetFailure;
  }

  @override
  Future<LocalResetException?> resetForNewServer(String url) async {
    calls.add('resetForNewServer $url');
    switchedTo.add(url);
    await resetGate?.future;
    return resetFailure;
  }

  @override
  Future<LocalResetException?> resetForBlockedServer() async {
    blockedResets++;
    await resetGate?.future;
    return resetFailure;
  }

  // Log-out and the stored sign-in.

  /// When set, [logout] waits for it.
  Completer<void>? logoutGate;
  Object? logoutError;
  int reloads = 0;

  @override
  Future<void> logout({bool keepUnsent = false}) async {
    calls.add(keepUnsent ? 'logout keep' : 'logout');
    await logoutGate?.future;
    if (logoutError != null) throw logoutError!;
  }

  @override
  Future<void> reloadSession() async {
    calls.add('reloadSession');
    reloads++;
  }

  @override
  Future<void> forgetStoredSignIn() async => calls.add('forgetStoredSignIn');

  // What a reset or a log-out would lose.
  List<String> losses = const [];
  LogoutLosses logoutLosses = const LogoutLosses(
    unsentUploads: 0,
    reviewDrafts: 0,
    unsentReviews: 0,
    unsentCancels: 0,
    unsentDeletions: 0,
    unconfirmedDeletions: 0,
  );

  @override
  Future<List<String>> pendingLossSummaries() async => losses;

  @override
  Future<LogoutLosses> pendingLogoutLosses() async => logoutLosses;

  // The live session.

  /// The test sets its value to block or unblock the session.
  final blocked = ValueNotifier(ServerBlockedReason.none);
  int syncs = 0;
  int activations = 0;
  int unauthorized = 0;

  @override
  ValueListenable<ServerBlockedReason> get serverBlocked => blocked;

  @override
  Future<void> syncLibrary() async => syncs++;

  @override
  Future<void> onSessionActivated() async => activations++;

  @override
  void onUnauthorized([String? servedBy]) => unauthorized++;
}
