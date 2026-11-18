import 'dart:async';

import 'package:frontend/services/session_service.dart'
    show ServerBlockedReason, SignInNotSavedFailure;
import 'package:flutter/foundation.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/ui/session_controller.dart';

/// Scriptable session controller for widget tests.
class FakeSessionControls extends ChangeNotifier implements SessionControls {
  FakeSessionControls({this.phase = SessionPhase.live, this.onDisconnect});

  @override
  SessionPhase phase;
  @override
  String? connectError;
  @override
  String? serverUrl;
  @override
  LocalResetException? resetFailure;
  @override
  String? get signInNotSavedNotice =>
      SignInNotSavedFailure.noticeFor(resetFailure);
  @override
  bool launchFailed = false;
  @override
  String? pendingServerSwitch;
  List<String> lossSummaries = const [];
  @override
  ServerBlockedReason serverBlocked = ServerBlockedReason.none;
  final Future<void> Function()? onDisconnect;
  final calls = <String>[];

  void set(SessionPhase next, {LocalResetException? failure, String? error}) {
    phase = next;
    resetFailure = failure;
    connectError = error;
    notifyListeners();
  }

  @override
  Future<void> start() async => calls.add('start');
  @override
  Future<void> connect(String url) async => calls.add('connect $url');
  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    await onDisconnect?.call();
  }

  @override
  Future<void> acknowledgeReset() async => calls.add('acknowledgeReset');

  /// A login found a different server at [url] (SC-01 rule 1).
  void askServerSwitch(String? url) {
    pendingServerSwitch = url;
    notifyListeners();
  }

  @override
  Future<void> confirmServerSwitch() async {
    calls.add('confirmServerSwitch');
    pendingServerSwitch = null;
    notifyListeners();
  }

  @override
  void cancelServerSwitch() {
    calls.add('cancelServerSwitch');
    pendingServerSwitch = null;
    notifyListeners();
  }

  @override
  Future<List<String>> pendingLossSummaries() async => lossSummaries;

  /// What a log-out would drop; nothing by default.
  LogoutLosses logoutLosses = const LogoutLosses(
    unsentUploads: 0,
    reviewDrafts: 0,
    unsentReviews: 0,
    unsentCancels: 0,
    unsentDeletions: 0,
    unconfirmedDeletions: 0,
  );

  @override
  Future<LogoutLosses> pendingLogoutLosses() async =>
      logoutLossesGate?.future ?? logoutLosses;

  /// When set, the count answers only once the test completes it.
  Completer<LogoutLosses>? logoutLossesGate;

  void setBlocked(ServerBlockedReason reason) {
    serverBlocked = reason;
    notifyListeners();
  }

  @override
  Future<void> resetBlockedServer() async => calls.add('resetBlockedServer');

  @override
  Future<void> onSessionActivated() async => calls.add('activated');

  @override
  Future<void> retryLibrarySync() async => calls.add('retrySync');

  // ── Phase M sign-in (M.3c) ─────────────────────────────────────────────
  @override
  String? authError;
  @override
  String? pendingUserSwitch;

  void setAuthError(String? error) {
    authError = error;
    notifyListeners();
  }

  /// A login found another user's data on this device.
  void askUserSwitch(String? username) {
    pendingUserSwitch = username;
    notifyListeners();
  }

  @override
  Future<void> login(String username, String password) async =>
      calls.add('login $username $password');
  @override
  Future<void> register(
          String username, String password, String confirmation) async =>
      calls.add('register $username $password $confirmation');
  @override
  Future<void> logout() async => calls.add('logout');
  @override
  Future<void> logOutKeepingUnsent() async => calls.add('logout keep');
  @override
  Future<void> confirmUserSwitch() async {
    calls.add('confirmUserSwitch');
    pendingUserSwitch = null;
    notifyListeners();
  }

  @override
  Future<void> cancelUserSwitch() async {
    calls.add('cancelUserSwitch');
    pendingUserSwitch = null;
    notifyListeners();
  }

  @override
  void showCreateAccount() => calls.add('showCreateAccount');
  @override
  void showLogIn() => calls.add('showLogIn');
  @override
  void changeServer() => calls.add('changeServer');
  @override
  Future<void> retryCredentials() async => calls.add('retryCredentials');
  @override
  Future<void> logInAgain() async => calls.add('logInAgain');
}
