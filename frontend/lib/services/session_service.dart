import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/services/server_binding_gate.dart';
import 'package:frontend/services/session_readiness.dart';

enum SessionStartKind {
  signedOut,
  online,
  offline,

  /// Launch finished a reset that had been interrupted (review major 2):
  /// local data is wiped and nothing is signed in. Like any finished reset,
  /// the provider scope is rebuilt next.
  resetFinished,
}

/// How a launch with (or without) a saved server URL starts.
class SessionStart {
  const SessionStart(this.kind, {this.error});
  final SessionStartKind kind;

  /// Shown on the login screen when the saved server rejected us.
  final String? error;
}

/// The result of a manual connect (login).
sealed class ConnectOutcome {
  const ConnectOutcome();
}

/// Verified: the URL is saved and the session is ready.
final class ConnectSucceeded extends ConnectOutcome {
  const ConnectSucceeded();
}

/// Not connected; [message] is shown on the login screen.
final class ConnectFailed extends ConnectOutcome {
  const ConnectFailed(this.message);
  final String message;
}

/// The server at [url] is a different instance from the one this library is
/// bound to (SC-01 rule 1): connecting needs a confirmed local reset first
/// ([SessionService.resetForNewServer]). Nothing was saved or changed.
final class ConnectDifferentServer extends ConnectOutcome {
  const ConnectDifferentServer(this.url);
  final String url;
}

/// The session rules (SC-26 model; formerly inside StartupGate): which
/// server we use, what a health result means, and the local reset.
class SessionService {
  SessionService(this._ref) {
    _ref.onDispose(() {
      _gateWatch?.cancel();
      _serverBlocked.dispose();
    });
  }

  final Ref _ref;
  final _serverBlocked = ValueNotifier<bool>(false);
  StreamSubscription<BindingGateState>? _gateWatch;
  static const serverUrlKey = 'serverUrl';

  /// Launch: resume the saved server, if any. A single health probe (a
  /// hanging saved URL must not hold the splash for the retry budget):
  /// healthy -> online; unreachable -> offline session (the URL is still
  /// presumed valid, downloads stay usable); rejected -> forget the URL and
  /// return to the login screen with the error (the binding row is kept, so
  /// the next connection is verified against it, SC-01 rule 3).
  ///
  /// A session URL always has a binding row (provisional until verified).
  /// Online, the connection is verified through the binding gate and the
  /// session becomes ready on its verdict; a different server leaves the app
  /// blocked: offline, with no health polling to flip it back.
  Future<SessionStart> resumeSavedSession() async {
    // A reset that never finished its wipe is finished first, before the
    // saved URL creates a binding row on top of the old store (major 2).
    final pending = await _completePendingReset();
    switch (pending) {
      case null:
        break;
      case _PendingResetDone():
        return const SessionStart(SessionStartKind.resetFinished);
      case _PendingResetFailed(:final message):
        return SessionStart(SessionStartKind.signedOut, error: message);
    }
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(serverUrlKey);
    if (url == null) return const SessionStart(SessionStartKind.signedOut);
    await _ref.read(serverBindingRepositoryProvider).ensureProvisional(url);
    ApiClient.init(url);
    final result = await ApiClient.instance.healthCheck(retry: false);
    switch (result.status) {
      case HealthStatus.ok:
        _watchServerBlock();
        unawaited(_verifyThenMarkReady(url));
        return const SessionStart(SessionStartKind.online);
      case HealthStatus.unreachable:
        _watchServerBlock();
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
  /// The server's identity is verified through the binding gate before the
  /// URL is saved; a failed attempt leaves no binding row it created. A
  /// different server than the bound one changes nothing: the user decides
  /// whether to reset ([ConnectDifferentServer]).
  Future<ConnectOutcome> connect(String url) async {
    // A reset the launch could not finish blocks every login until its
    // wipe succeeds: no server may adopt the old store (major 2).
    if (await _completePendingReset() case _PendingResetFailed(:final message)) {
      return ConnectFailed(message);
    }
    ApiClient.init(url);
    final result = await ApiClient.instance.healthCheck(retry: false);
    if (result.status != HealthStatus.ok) {
      return ConnectFailed(result.message ?? 'Could not reach the server.');
    }
    final bindings = _ref.read(serverBindingRepositoryProvider);
    final createdRow = await bindings.current() == null;
    await bindings.ensureProvisional(url);
    // A login probe never flips the app offline: the URL isn't the
    // session's yet.
    final verdict = await _connectionVerdict(
      url,
      (s) => s is! BindingVerifying,
      reportOffline: false,
    );
    if (verdict != null && verdict is! BindingVerified) {
      // Stop verifying (and retrying) the URL the user typed: it was never
      // saved. A different server is the login dialog's to resolve.
      _ref.read(serverBindingGateProvider).stop();
    }
    switch (verdict) {
      case BindingVerified():
        break;
      case BindingDifferentServer():
        return ConnectDifferentServer(url);
      case BindingUnverified(:final error):
        if (createdRow) await bindings.fence();
        return ConnectFailed("Could not verify the server's identity: $error");
      case _:
        return const ConnectFailed("Could not verify the server's identity.");
    }
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    await prefs.setString(serverUrlKey, url);
    // A prior disconnect-while-offline can leave offline mode armed; clear
    // it so the app doesn't open behind the offline banner.
    _ref.read(offlineModeProvider.notifier).exitOffline();
    _markReady();
    _watchServerBlock();
    return const ConnectSucceeded();
  }

  /// A session is live with its offline state decided: playback may now
  /// restore the saved queue (SC-27 session-ready signal).
  void _markReady() => _ref.read(sessionReadinessProvider).markReady();

  /// Starts verifying a connection to [url] and returns the first state
  /// matching [isVerdict], or null if the gate closes first.
  Future<BindingGateState?> _connectionVerdict(
    String url,
    bool Function(BindingGateState) isVerdict, {
    bool reportOffline = true,
  }) async {
    final gate = _ref.read(serverBindingGateProvider);
    // Subscribe before starting so the verdict can't be missed.
    final verdict = gate.states
        .firstWhere(isVerdict)
        .then<BindingGateState?>((s) => s, onError: (Object _) => null);
    unawaited(gate.startConnection(url, reportOffline: reportOffline));
    return verdict;
  }

  /// Online start: ready once the binding gate has a verdict (a different
  /// server blocks, see [_watchServerBlock]; local playback keeps working),
  /// or once the session went offline while waiting (an offline restore
  /// needs no binding). A server that answers but can't be verified keeps
  /// network-backed playback waiting.
  Future<void> _verifyThenMarkReady(String url) async {
    final wentOffline = Completer<bool>();
    final offlineWatch = _ref.listen<bool>(offlineModeProvider, (_, offline) {
      if (offline && !wentOffline.isCompleted) wentOffline.complete(true);
    });
    try {
      final verdict = _connectionVerdict(
        url,
        (s) => s is BindingVerified || s is BindingDifferentServer,
      );
      final ready = await Future.any<bool>([
        verdict.then((v) => v != null),
        wentOffline.future,
      ]);
      if (ready) _markReady();
    } finally {
      offlineWatch.close();
    }
  }

  /// The one place "blocked: different server" is decided (SC-01 rule 1),
  /// for a live session's every connection (launch, networkRecovered,
  /// appResume). A different server blocks: offline, with health polling
  /// cancelled so the healthy server can't flip it back online. The bound
  /// server answering again clears it (D14). Subscribed once, before the
  /// session's first connection starts.
  void _watchServerBlock() {
    if (_gateWatch != null) return;
    _gateWatch = _ref.read(serverBindingGateProvider).states.listen((state) {
      final offline = _ref.read(offlineModeProvider.notifier);
      if (state is BindingDifferentServer) {
        _serverBlocked.value = true;
        offline.enterOffline();
        offline.cancelOfflinePolling();
      } else if (state is BindingVerified && _serverBlocked.value) {
        _serverBlocked.value = false;
        offline.exitOffline();
      }
    });
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

  /// Blocked: the server at the saved URL is a different library (SC-01
  /// rule 1). Network runners wait on the binding gate; the app behaves as
  /// offline.
  ValueListenable<bool> get serverBlocked => _serverBlocked;

  /// The user chose Reset on the blocked banner: reset local data and keep
  /// the saved URL so the rebuilt session binds to the server there.
  Future<LocalResetException?> resetForBlockedServer() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(serverUrlKey);
    return url == null ? resetLocalData() : resetForNewServer(url);
  }

  /// The Disconnect / reset confirmation's "will be lost" lines (SC-15).
  Future<List<String>> pendingLossSummaries() =>
      _ref.read(localResetServiceProvider).pendingLossSummaries();

  /// The user confirmed connecting to the different server at [url]: reset
  /// local data, then save [url] (after the prefs wipe) so the rebuilt
  /// session binds to it and syncs (SC-15). The URL is kept after a partial
  /// wipe too (the fence held), unless the database wipe failed; an aborted
  /// reset saves nothing.
  Future<LocalResetException?> resetForNewServer(String url) async {
    final (:failure, :aborted) = await _reset();
    // A failed database wipe leaves the old catalog and cursors behind:
    // binding the next server to them would mix libraries, so back to login.
    final databaseKept =
        failure?.failures.any((f) => f.participant is AppDatabase) ?? false;
    if (!aborted && !databaseKept) {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      await prefs.setString(serverUrlKey, url);
    }
    return failure;
  }

  /// Wipes local state. A partial reset is reported, never hidden; every
  /// step still runs (see [LocalResetService]).
  Future<LocalResetException?> resetLocalData() async =>
      (await _reset()).failure;

  /// Finishes an interrupted reset (major 2), if there is one: null when
  /// none was pending.
  Future<_PendingReset?> _completePendingReset() async {
    final resets = _ref.read(localResetServiceProvider);
    try {
      if (!await resets.hasPendingReset()) return null;
      await resets.completePendingReset();
      return const _PendingResetDone();
    } catch (e) {
      return _PendingResetFailed(
          'An earlier reset could not finish clearing local data, so no '
          'server can be connected yet ($e). Connecting tries again.');
    }
  }

  /// Runs the local reset. [aborted]: the fence did not hold (or the reset
  /// failed unexpectedly), so nothing may be assumed wiped.
  Future<({LocalResetException? failure, bool aborted})> _reset() async {
    try {
      await _ref.read(localResetServiceProvider).reset();
      return (failure: null, aborted: false);
    } on LocalResetException catch (e) {
      return (failure: e, aborted: false);
    } catch (e, st) {
      return (
        failure: LocalResetException([
          LocalResetFailure(LocalResetService, e, st),
        ]),
        aborted: true,
      );
    }
  }
}

final sessionServiceProvider = Provider<SessionService>(SessionService.new);

sealed class _PendingReset {
  const _PendingReset();
}

final class _PendingResetDone extends _PendingReset {
  const _PendingResetDone();
}

final class _PendingResetFailed extends _PendingReset {
  const _PendingResetFailed(this.message);
  final String message;
}
