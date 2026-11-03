import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/session_readiness.dart';

enum SessionStartKind { signedOut, online, offline }

/// How a launch with (or without) a saved server URL starts.
class SessionStart {
  const SessionStart(this.kind, {this.error});
  final SessionStartKind kind;

  /// Shown on the login screen when the saved server rejected us.
  final String? error;
}

/// The session rules (SC-26 model; formerly inside StartupGate): which
/// server we use, what a health result means, and the local reset.
class SessionService {
  SessionService(this._ref);

  final Ref _ref;
  static const serverUrlKey = 'serverUrl';

  /// Launch: resume the saved server, if any. A single health probe (a
  /// hanging saved URL must not hold the splash for the retry budget):
  /// healthy -> online; unreachable -> offline session (the URL is still
  /// presumed valid, downloads stay usable); rejected -> forget the URL and
  /// return to the login screen with the error.
  Future<SessionStart> resumeSavedSession() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(serverUrlKey);
    if (url == null) return const SessionStart(SessionStartKind.signedOut);
    ApiClient.init(url);
    final result = await ApiClient.instance.healthCheck(retry: false);
    switch (result.status) {
      case HealthStatus.ok:
        _markReady();
        return const SessionStart(SessionStartKind.online);
      case HealthStatus.unreachable:
        _ref.read(offlineModeProvider.notifier).enterOffline();
        _markReady();
        return const SessionStart(SessionStartKind.offline);
      case HealthStatus.serverError:
        await prefs.remove(serverUrlKey);
        return SessionStart(SessionStartKind.signedOut, error: result.message);
    }
  }

  /// First-time / manual connect: an entered host is not trusted yet, so it
  /// is saved (and the app entered) only after a passing health check.
  /// Returns null on success, else the error to show.
  Future<String?> connect(String url) async {
    ApiClient.init(url);
    final result = await ApiClient.instance.healthCheck(retry: false);
    if (result.status != HealthStatus.ok) return result.message;
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(serverUrlKey, url);
    // A prior disconnect-while-offline can leave offline mode armed; clear
    // it so the app doesn't open behind the offline banner.
    _ref.read(offlineModeProvider.notifier).exitOffline();
    _markReady();
    return null;
  }

  /// A session is live with its offline state decided: playback may now
  /// restore the saved queue (SC-27 session-ready signal).
  void _markReady() => _ref.read(sessionReadinessProvider).markReady();

  bool _activated = false;

  /// The live session's UI exists (the session host mounted): run the one
  /// initial catalog sync, on first login and on saved-session startup
  /// alike (Home and Search need the mirror without visiting a browse page;
  /// recovery triggers keep covering resume/reconnect). Once per session:
  /// a reset rebuilds the scope, and with it this service.
  /// 5A.0 makes this await the SC-01 `bindingVerified` gate.
  Future<void> onSessionActivated() async {
    if (_activated) return;
    _activated = true;
    await _ref.read(trackSyncProvider.notifier).sync();
  }

  /// A user-requested catalog sync (Retry after a failed one). Unlike
  /// [onSessionActivated], runs every time it is asked.
  Future<void> syncLibrary() => _ref.read(trackSyncProvider.notifier).sync();

  /// Wipes local state. A partial reset is reported, never hidden; every
  /// step still runs (see [LocalResetService]).
  Future<LocalResetException?> resetLocalData() async {
    try {
      await _ref.read(localResetServiceProvider).reset();
      return null;
    } on LocalResetException catch (e) {
      return e;
    } catch (e, st) {
      return LocalResetException([LocalResetFailure(LocalResetService, e, st)]);
    }
  }
}

final sessionServiceProvider = Provider<SessionService>(SessionService.new);
