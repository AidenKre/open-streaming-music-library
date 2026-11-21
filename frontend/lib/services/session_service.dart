import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/api/auth_api.dart';
import 'package:frontend/api/server_identity_api.dart';
import 'package:frontend/database/database.dart'
    show DatabaseVersionRefused, databaseVersionRefusalIn;
import 'package:frontend/models/server_blocked_reason.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/repositories/server_binding_repository.dart'
    show ServerBindingRecord;
import 'package:frontend/services/credential_store.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/dead_sign_in_records.dart';
import 'package:frontend/services/download/track_downloader.dart'
    show DownloadsLeftByReset, downloadsLeftByResetMessage;
import 'package:frontend/services/logout_losses.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session/session_outcomes.dart';
import 'package:frontend/services/session_event_log.dart';
import 'package:frontend/services/session_readiness.dart';

export 'package:frontend/models/server_blocked_reason.dart';
export 'package:frontend/services/session/session_outcomes.dart';

part 'session/manual_connect.dart';
part 'session/server_block_watch.dart';
part 'session/session_launch.dart';
part 'session/session_resets.dart';
part 'session/sign_in_flow.dart';

/// Writes the session log line for a refused database ([e] is or wraps a
/// [DatabaseVersionRefused]): the two versions, nothing else. Any other
/// error is left to its caller.
void _logDatabaseRefusal(Ref ref, Object e) {
  final refusal = databaseVersionRefusalIn(e);
  if (refusal == null) return;
  ref.read(sessionEventLogProvider)(
    'Database not opened: reason=version_refused found=${refusal.found} '
    'expected=${refusal.expected}',
  );
}

/// Whether [error] is this device's database refused for being of another
/// schema version (pre-merge review D3-01): the controller then shows the
/// refusal screen, whose Reset… deletes that database.
bool isDatabaseRefusal(Object error) => databaseVersionRefusalIn(error) != null;

/// The session rules (SC-26 model; formerly inside StartupGate): which
/// server we use, what a health result means, and the local reset.
///
/// This class is the entry point. The rules live in the parts it owns, in
/// the files under `session/`. The constructor below shows which part is
/// given which other part; a part keeps its own state to itself:
///
/// - [_PendingResetCheck] (`session_resets.dart`): is an interrupted reset
///   still pending? Asked first by launch, connect and sign-in.
/// - [_ServerBlockWatch] (`server_block_watch.dart`): the binding gate's
///   verdict on the live connection; the blocked flags.
/// - [_SignInFlow] (`sign_in_flow.dart`): login, register, and the sign-in
///   held in memory until a reset is confirmed.
/// - [_SessionResets] (`session_resets.dart`): the resets a user asks for,
///   the held sign-in's confirmed reset, log-out.
/// - [_SessionLaunch] (`session_launch.dart`): the saved-session launch.
/// - [_ManualConnect] (`manual_connect.dart`): the manual connect.
class SessionService {
  SessionService(this._ref) {
    _resetCheck = _PendingResetCheck(_ref);
    _block = _ServerBlockWatch(_ref);
    _signInFlow = _SignInFlow(_ref, _resetCheck);
    _resets = _SessionResets(_ref, _signInFlow);
    _launch = _SessionLaunch(_ref, _resetCheck, _signInFlow, _block);
    _connect = _ManualConnect(_ref, _resetCheck, _signInFlow);
    _ref.onDispose(() {
      _disposed = true;
      // A scope rebuild never drops a held sign-in unrevoked. No `ref` here:
      // the held sign-in carries the client it needs.
      _signInFlow.revokeHeldAtDispose();
      _block.dispose();
    });
  }

  final Ref _ref;
  late final _PendingResetCheck _resetCheck;
  late final _ServerBlockWatch _block;
  late final _SignInFlow _signInFlow;
  late final _SessionResets _resets;
  late final _SessionLaunch _launch;
  late final _ManualConnect _connect;
  bool _disposed = false;
  static const serverUrlKey = 'serverUrl';

  /// Launch: resume the saved server, if any
  /// ([_SessionLaunch.resumeSavedSession]).
  Future<SessionStart> resumeSavedSession() =>
      _namingRefusal(_launch.resumeSavedSession);

  /// Manual connect (spec 7.4): checks an entered address and saves it
  /// ([_ManualConnect.connect]).
  Future<ConnectOutcome> connect(String url) =>
      _namingRefusal(() => _connect.connect(url));

  /// A database of another schema version fails launch and connect; the
  /// session log names it (pre-merge review D3-01), then it is rethrown.
  Future<T> _namingRefusal<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      _logDatabaseRefusal(_ref, e);
      rethrow;
    }
  }

  /// Log in to the saved server (spec 7.5). See [_SignInFlow].
  Future<SignInOutcome> login(String username, String password) =>
      _signInFlow.login(username, password);

  /// Create an account on the saved server and sign in (spec 7.5).
  Future<SignInOutcome> register(String username, String password) =>
      _signInFlow.register(username, password);

  /// The user confirmed the held sign-in's reset sheet
  /// ([_SessionResets.confirmPendingSignIn]).
  Future<LocalResetException?> confirmPendingSignIn() =>
      _resets.confirmPendingSignIn();

  /// Re-reads the saved URL and the stored credentials and rebuilds the
  /// scope: the retry for unreadable credentials.
  Future<void> reloadSession() async =>
      await _ref.read(onSessionChangedProvider)?.call();

  /// The user's explicit choice to drop an unreadable stored sign-in. Clears
  /// it through logout's credential delete (a signed-out marker when the
  /// secure delete fails; this run then reads signed out), then rebuilds the
  /// scope, which opens at Log in for the kept URL.
  Future<void> forgetStoredSignIn() async {
    try {
      await _ref.read(credentialStoreProvider).delete();
    } catch (e) {
      developer.log(
        'Could not clear the stored sign-in: ${e.runtimeType}',
        name: 'SessionService',
      );
    }
    await reloadSession();
  }

  /// [keepUnsent]: see [LocalResetService.signOut].
  Future<void> logout({bool keepUnsent = false}) =>
      _resets.logout(keepUnsent: keepUnsent);

  /// The user cancelled the sheet: revoke the held session (best effort),
  /// discard it, and change nothing else. A no-op when nothing is held.
  Future<void> cancelPendingSignIn() => _signInFlow.cancelPendingSignIn();

  /// The authenticated client got a 401 (Phase M 7.7); [servedBy] is the
  /// answer's server stamp. Who sent it decides between signed out and a
  /// different server ([_ServerBlockWatch.onUnauthorized]). Idempotent, and
  /// a no-op once this scope is disposed.
  void onUnauthorized([String? servedBy]) {
    if (_disposed) return;
    _block.onUnauthorized(servedBy);
  }

  bool _activated = false;

  /// The live session's UI exists (the session host mounted): run the one
  /// initial catalog sync, on first login and on saved-session startup
  /// alike (Home and Search need the mirror without visiting a browse page;
  /// recovery triggers keep covering resume/reconnect). Once per session:
  /// a reset rebuilds the scope, and with it this service. The sync itself
  /// awaits the SC-01 binding gate before its first request.
  Future<void> onSessionActivated() async {
    if (_activated) return;
    _activated = true;
    await _ref.read(trackSyncProvider.notifier).sync();
  }

  /// A user-requested catalog sync (Retry after a failed one). Unlike
  /// [onSessionActivated], runs every time it is asked.
  Future<void> syncLibrary() => _ref.read(trackSyncProvider.notifier).sync();

  /// Why the session is blocked: the saved server is a different library
  /// (SC-01 rule 1) or a 401 signed us out. Network runners wait on the
  /// binding gate; the app behaves as offline.
  ValueListenable<ServerBlockedReason> get serverBlocked =>
      _block.serverBlocked;

  /// The user chose Reset on the blocked banner: reset local data and keep
  /// the saved URL so the rebuilt session binds to the server there.
  Future<LocalResetException?> resetForBlockedServer() =>
      _resets.resetForBlockedServer();

  /// The Disconnect / reset confirmation's "will be lost" lines (SC-15).
  Future<List<String>> pendingLossSummaries() =>
      _resets.pendingLossSummaries();

  /// Never throws: a counter that cannot be built or read is unknown.
  Future<LogoutLosses> pendingLogoutLosses() => _resets.pendingLogoutLosses();

  /// The user confirmed connecting to the different server at [url]
  /// ([_SessionResets.resetForNewServer]).
  Future<LocalResetException?> resetForNewServer(String url) =>
      _resets.resetForNewServer(url);

  /// Wipes local state. A partial reset is reported, never hidden; every
  /// step still runs (see [LocalResetService]).
  Future<LocalResetException?> resetLocalData() => _resets.resetLocalData();
}

final sessionServiceProvider = Provider<SessionService>(SessionService.new);

/// Where session events are written, one line per event (no secrets): the
/// developer log and, when the app gives one, the session log file (never
/// awaited; it never throws). Tests override it to capture the lines.
final sessionEventLogProvider = Provider<void Function(String message)>((ref) {
  final file = ref.read(sessionEventLogFileProvider);
  return (message) {
    developer.log(message, name: 'SessionService');
    if (file != null) unawaited(file.append(message));
  };
});

/// Rebuilds the provider scope after re-reading the session URL. Overridden
/// by `FrontendApp`; null means no rebuild hook (tests).
final onSessionChangedProvider = Provider<Future<void> Function()?>(
  (ref) => null,
);
