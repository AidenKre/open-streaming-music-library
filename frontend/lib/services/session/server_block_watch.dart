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
      } else if (state is BindingVerified && _differentServer) {
        _differentServer = false;
        _publishBlocked();
        if (!_signedOut) offline.exitOffline();
      }
    });
  }

  /// The authenticated client got a 401 (Phase M 7.7): signed out. Closes
  /// the binding gate and turns offline on with polling stopped. Memory
  /// only (stored credentials stay); cleared only by a scope rebuild.
  /// Idempotent. [SessionService.onUnauthorized] checks first that the scope
  /// is not disposed.
  void onUnauthorized() {
    if (_signedOut) return;
    _signedOut = true;
    _publishBlocked();
    _ref.read(serverBindingGateProvider).closeSignedOut();
    final offline = _ref.read(offlineModeProvider.notifier);
    offline.enterOffline(poll: false);
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
