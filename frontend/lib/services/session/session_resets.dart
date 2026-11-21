part of '../session_service.dart';

/// The question launch, connect and sign-in each ask before anything binds:
/// is a reset that never finished its wipe still pending? If so it is
/// finished first. The callers switch on all four answers (see
/// [_PendingReset]); none may go on when the answer is failed or unknown.
class _PendingResetCheck {
  _PendingResetCheck(this._ref);

  final Ref _ref;

  /// Shown when an earlier reset could not finish clearing local data.
  static const _pendingResetNotFinished =
      'An earlier reset could not finish clearing local data, so no server '
      'can be connected yet. Connecting tries again.';

  /// Connect or sign-in could not read whether an earlier reset is still
  /// pending.
  static const settingsUnreadable =
      "This device's saved settings could not be read.";

  /// Finishes an interrupted reset (major 2), if there is one: null when
  /// none was pending; [_PendingResetUnknown] when the marker could not be
  /// read (nothing was finished or skipped: the next attempt asks again).
  Future<_PendingReset?> completePendingReset() async {
    final resets = _ref.read(localResetServiceProvider);
    final bool pending;
    try {
      pending = await resets.hasPendingReset();
    } catch (_) {
      _ref.read(sessionEventLogProvider)(
          'Pending reset not checked: reason=marker_unreadable');
      return const _PendingResetUnknown();
    }
    if (!pending) return null;
    try {
      await resets.completePendingReset();
      return const _PendingResetDone();
    } catch (e) {
      _ref.read(sessionEventLogProvider)(
          'Pending reset not finished: reason=${_notFinishedReason(e)}');
      return const _PendingResetFailed(_pendingResetNotFinished);
    }
  }

  static String _notFinishedReason(Object e) => switch (e) {
        // A database of another schema version the fence could not get past.
        LocalResetAbortedException(:final cause)
            when isDatabaseRefusal(cause) =>
          'version_refused',
        LocalResetAbortedException() => 'fence_failed',
        // Every wipe step ran; only the marker could not be cleared.
        LocalResetException(:final failures)
            when failures.every((f) => f.subsystem == LocalResetService) =>
          'marker_not_cleared',
        LocalResetException(databaseKept: true) => 'database_wipe_failed',
        LocalResetException() => 'wipe_failed',
        _ => 'unexpected_error',
      };
}

sealed class _PendingReset {
  const _PendingReset();
}

final class _PendingResetDone extends _PendingReset {
  const _PendingResetDone();
}

final class _PendingResetUnknown extends _PendingReset {
  const _PendingResetUnknown();
}

/// Thrown by [SessionService.resumeSavedSession] when the reset marker could
/// not be read; the controller shows the launch-fault screen.
class _PendingResetUnreadable implements Exception {
  @override
  String toString() => 'the reset marker could not be read';
}

final class _PendingResetFailed extends _PendingReset {
  const _PendingResetFailed(this.message);
  final String message;
}

/// The resets a user asks for, and what each may save afterwards. Every
/// place in this library that judges a reset's result is in this file:
/// [_reset] makes the `aborted` flag; [confirmPendingSignIn] and
/// [resetForNewServer] read it together with the [LocalResetException]
/// getters; [SignInNotSavedFailure.noticeFor] picks the notice. Log-out and
/// the "will be lost" counts shown before a reset or a log-out are here too.
class _SessionResets {
  _SessionResets(this._ref, this._signInFlow);

  final Ref _ref;
  final _SignInFlow _signInFlow;

  /// Runs the local reset. [aborted]: the fence did not hold (or the reset
  /// failed unexpectedly), so nothing may be assumed wiped.
  Future<({LocalResetException? failure, bool aborted})> _reset() async {
    try {
      await _ref.read(localResetServiceProvider).reset();
      return (failure: null, aborted: false);
    } on LocalResetException catch (e) {
      _logFailedSteps(e);
      return (failure: e, aborted: false);
    } catch (e, st) {
      final failure = LocalResetException([
        LocalResetFailure(LocalResetService, e, st),
      ]);
      _logFailedSteps(failure, aborted: true);
      return (failure: failure, aborted: true);
    }
  }

  /// One session-log line per failed step: its name, whether it was the
  /// fence ([aborted]: nothing was stopped or wiped), a stopping or a wipe
  /// step, and the error's type. Never the error's text (it may name a
  /// path); the dialog shows a fixed sentence.
  void _logFailedSteps(LocalResetException failure, {bool aborted = false}) {
    final log = _ref.read(sessionEventLogProvider);
    for (final f in failure.failures) {
      final kind = aborted ? 'fence' : (f.quiesce ? 'stop' : 'wipe');
      log('Reset step failed: step=${f.subsystem} kind=$kind '
          'error=${f.error.runtimeType}');
    }
  }

  /// Wipes local state. A partial reset is reported, never hidden; every
  /// step still runs (see [LocalResetService]).
  Future<LocalResetException?> resetLocalData() async =>
      (await _reset()).failure;

  /// The user confirmed connecting to the different server at [url]: reset
  /// local data, then save [url] (after the prefs wipe) so the rebuilt
  /// session binds to it and syncs (SC-15). The URL is kept after a partial
  /// wipe too (the fence held), unless the database wipe failed; an aborted
  /// reset saves nothing.
  Future<LocalResetException?> resetForNewServer(String url) async {
    // A sign-in held for this URL is the different-server sheet's confirm.
    if (_signInFlow.heldUrl == url) return confirmPendingSignIn();
    final (:failure, :aborted) = await _reset();
    // A failed database wipe leaves the old catalog and cursors behind:
    // binding the next server to them would mix libraries, so back to login.
    final databaseKept = failure?.databaseKept ?? false;
    if (!aborted && !databaseKept) {
      final prefs = await _ref.read(sharedPreferencesProvider.future);
      await prefs.setString(SessionService.serverUrlKey, url);
    }
    return failure;
  }

  /// The user chose Reset on the blocked banner: reset local data and keep
  /// the saved URL so the rebuilt session binds to the server there.
  Future<LocalResetException?> resetForBlockedServer() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final url = prefs.getString(SessionService.serverUrlKey);
    return url == null ? resetLocalData() : resetForNewServer(url);
  }

  /// The user confirmed the held sign-in's reset sheet: run the SC-15 reset,
  /// then persist the held credentials only if no wipe step failed (quiesce
  /// failures do not count). The rebuild is the finished-reset path's, not
  /// this method's. When nothing is persisted the held session is revoked.
  /// Null failure when nothing was held or the reset was clean.
  Future<LocalResetException?> confirmPendingSignIn() async {
    final held = _signInFlow.takeHeld();
    if (held == null) return null;
    final (:failure, :aborted) = await _reset();
    if (!aborted &&
        (failure == null || failure.quiesceOnly)) {
      try {
        await _signInFlow.persistSignIn(held);
      } catch (e, st) {
        await _signInFlow.revokeSignIn(held);
        return LocalResetException([
          ...?failure?.failures,
          SignInNotSavedFailure(e, st),
        ]);
      }
    } else {
      await _signInFlow.revokeSignIn(held);
    }
    return failure;
  }

  /// [keepUnsent]: see [LocalResetService.signOut].
  Future<void> logout({bool keepUnsent = false}) async {
    try {
      await _ref.read(localResetServiceProvider).signOut(keepUnsent: keepUnsent);
    } finally {
      await _ref.read(onSessionChangedProvider)?.call();
    }
  }

  /// The Disconnect / reset confirmation's "will be lost" lines (SC-15).
  Future<List<String>> pendingLossSummaries() =>
      _ref.read(localResetServiceProvider).pendingLossSummaries();

  /// Never throws: a counter that cannot be built or read is unknown.
  Future<LogoutLosses> pendingLogoutLosses() async {
    try {
      return await _ref.read(logoutLossCounterProvider).count();
    } catch (_) {
      return LogoutLosses.unknown;
    }
  }
}

/// The "Reset incomplete" dialog's sentence (other-issues row 66; APP-DATA
/// review 2, F4): never a failure's own text. The steps that failed are in
/// the session log ([_SessionResets._reset]).
abstract final class ResetIncompleteNotice {
  static const generic = 'Some local data could not be cleared.';

  /// Null when nothing but stopping failed, or when the sign-in notice
  /// applies ([SignInNotSavedFailure.noticeFor]). The downloads sentence
  /// alone when every other failure is downloads the reset left outside the
  /// app's downloads folder; [generic] otherwise.
  static String? messageFor(LocalResetException? failure) {
    if (failure == null || failure.quiesceOnly) return null;
    if (SignInNotSavedFailure.noticeFor(failure) != null) return null;
    final rest = failure.failures.where((f) => !f.quiesce);
    return rest.every((f) => f.error is DownloadsLeftByReset)
        ? downloadsLeftByResetMessage
        : generic;
  }
}

/// A held sign-in that could not be saved after its confirmed reset: its own
/// failure, never a wipe step's.
final class SignInNotSavedFailure extends LocalResetFailure {
  SignInNotSavedFailure(Object error, StackTrace stackTrace)
      : super(SessionService, error, stackTrace);

  /// The one sentence shown when the sign-in could not be saved.
  static const message = 'Could not save the sign-in on this device.';

  /// The sentence shown instead of "Reset incomplete" when the only failure
  /// that is not a quiesce failure is a sign-in that could not be saved; null
  /// otherwise.
  static String? noticeFor(LocalResetException? failure) {
    if (failure == null || failure.quiesceOnly) return null;
    return failure.failures
            .every((f) => f.quiesce || f is SignInNotSavedFailure)
        ? message
        : null;
  }

  @override
  String toString() => message;
}
