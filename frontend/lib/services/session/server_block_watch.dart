part of '../session_service.dart';

/// What the binding gate says about the live session's connection: ready
/// (the first verdict), blocked by a different server, or signed out by a
/// 401. Every use the session makes of the gate is in this class, and so are
/// the blocked flags: no other part reads or writes them.
class _ServerBlockWatch {
  _ServerBlockWatch(this._ref);

  final Ref _ref;
  final _serverBlocked = ValueNotifier<ServerBlockedReason>(
    ServerBlockedReason.none,
  );
  bool _differentServer = false;
  bool _signedOut = false;

  /// A 401 that did not sign this session out: work it parked resumes at
  /// the next verified contact.
  bool _parkedBy401 = false;
  StreamSubscription<BindingGateState>? _gateWatch;

  /// Why the session is blocked; [ServerBlockedReason.none] when it is not.
  ValueListenable<ServerBlockedReason> get serverBlocked => _serverBlocked;

  /// The scope is being disposed.
  void dispose() {
    _gateWatch?.cancel();
    _serverBlocked.dispose();
  }

  /// A session is live with its offline state decided: playback may now
  /// restore the saved queue (SC-27 session-ready signal).
  void markReady() => _ref.read(sessionReadinessProvider).markReady();

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
  /// server blocks, see [watchServerBlock]; local playback keeps working),
  /// or once the session went offline while waiting (an offline restore
  /// needs no binding). A server that answers but can't be verified keeps
  /// network-backed playback waiting.
  Future<void> verifyThenMarkReady(String url) async {
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
      if (ready) markReady();
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
  void watchServerBlock() {
    if (_gateWatch != null) return;
    _gateWatch = _ref.read(serverBindingGateProvider).states.listen((state) {
      final offline = _ref.read(offlineModeProvider.notifier);
      if (state is BindingDifferentServer) {
        _differentServer = true;
        _publishBlocked();
        offline.enterOffline(poll: false);
      } else if (state is BindingVerified) {
        final wasBlocked = _differentServer;
        final resume = (wasBlocked || _parkedBy401) && !_signedOut;
        _parkedBy401 = false;
        if (wasBlocked) {
          _differentServer = false;
          _publishBlocked();
          if (!_signedOut) offline.exitOffline();
        }
        // Work a 401 parked (another server's, or one whose sender was
        // never known) resumes in this scope with the same sign-in; a real
        // sign-out never verifies again, so never gets here.
        if (resume) {
          unawaited(
            _ref
                .read(recoveryServiceProvider)
                .runFor(RecoveryTrigger.boundServerBack),
          );
        }
      } else if (state is BindingSignedOut && !_signedOut) {
        // Signed out (Phase M 7.7): offline with polling stopped. Memory
        // only (stored credentials stay); cleared only by a scope rebuild.
        _signedOut = true;
        _publishBlocked();
        offline.enterOffline(poll: false);
      }
    });
  }

  /// The authenticated client got a 401 (Phase M 7.7); [servedBy] is the
  /// answer's server stamp. The binding gate withholds the token at once and
  /// decides who sent it ([ServerBindingGate.checkAfterUnauthorized]): the
  /// bound server means signed out, another server the different-server
  /// block, both through [watchServerBlock]. Idempotent.
  /// [SessionService.onUnauthorized] checks first that the scope is not
  /// disposed.
  void onUnauthorized(String? servedBy) {
    if (_signedOut) return;
    watchServerBlock();
    _parkedBy401 = true;
    _ref
        .read(serverBindingGateProvider)
        .checkAfterUnauthorized(
          _ref.read(apiClientProvider).baseUrl,
          servedBy: servedBy,
        );
  }

  /// A different server wins over signed out when both apply.
  void _publishBlocked() {
    _serverBlocked.value = _differentServer
        ? ServerBlockedReason.differentServer
        : _signedOut
        ? ServerBlockedReason.signedOut
        : ServerBlockedReason.none;
  }
}
