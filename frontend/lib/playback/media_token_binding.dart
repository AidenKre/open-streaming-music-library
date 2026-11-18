import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// What the binding gate drives in the playback engine (sign-off OPEN-M-11
/// step D).
abstract interface class MediaTokenSources {
  /// The next verification: stream sources built without the media token get
  /// it. The current item is replaced too, safely: a stream without the token
  /// cannot be playing.
  Future<void> refreshWithheldMediaTokens();

  /// The server is not the verified one: stream sources lose the token. With
  /// [includeCurrent] false the current item's source is left alone. It never
  /// stops playback itself; the queue player does that in its lane.
  Future<void> releaseRemoteSources({required bool includeCurrent});
}

/// Whether stream sources cannot be played now: offline, or the server check
/// failed. A pending verdict is not unavailable (sign-off OPEN-M-11 step D),
/// except that a retry of a failed check ([lastVerdictFailed]) stays
/// unavailable so nothing blinks; a probe after a success (launch, resume,
/// refocus) is not.
bool remoteStreamsUnavailable({
  required bool offline,
  required BindingGateState gate,
  bool lastVerdictFailed = false,
}) =>
    offline ||
    gate is BindingUnverified ||
    (gate is BindingVerifying && lastVerdictFailed);

/// What the playback core does for a gate state (sign-off OPEN-M-11 step D).
enum MediaTokenAction {
  none,

  /// Verified: stream sources built without the token get it.
  refresh,

  /// The check failed or there is no session: sources ahead lose the token;
  /// the current item is left alone.
  releaseAhead,

  /// A different server: every stream source loses the token, a remote
  /// current item is stopped first.
  releaseAll,
}

MediaTokenAction mediaTokenActionFor(BindingGateState state) => switch (state) {
      BindingVerified() => MediaTokenAction.refresh,
      BindingDifferentServer() => MediaTokenAction.releaseAll,
      BindingUnverified() ||
      BindingSignedOut() ||
      BindingNoSession() =>
        MediaTokenAction.releaseAhead,
      BindingIdle() || BindingVerifying() => MediaTokenAction.none,
    };

/// Whether remote streams cannot be played now (offline, or the server check
/// failed), read at call time. The playback core and the engine treat a
/// stream then like a non-downloaded item offline.
final streamsUnavailableProvider = Provider<bool Function()>((ref) => () {
      BindingGateState gate;
      try {
        gate = ref.read(serverBindingGateProvider).state;
      } catch (_) {
        gate = const BindingIdle();
      }
      var lastFailed = false;
      try {
        lastFailed = ref.read(serverBindingGateProvider).lastVerdictFailed;
      } catch (_) {}
      return remoteStreamsUnavailable(
        offline: ref.read(offlineModeProvider),
        gate: gate,
        lastVerdictFailed: lastFailed,
      );
    });

/// The reactive form of [streamsUnavailableProvider], for the screens to
/// watch: it rebuilds on offline changes and on every gate state. A pending
/// verdict is not unavailable, so nothing flickers on launch, resume or
/// refocus (sign-off OPEN-M-11 Part N). Both use [remoteStreamsUnavailable].
final streamsUnavailableNowProvider = Provider<bool>((ref) {
  final offline = ref.watch(offlineModeProvider);
  ServerBindingGate? gate;
  try {
    gate = ref.watch(serverBindingGateProvider);
  } catch (_) {
    gate = null;
  }
  if (gate != null) {
    final sub = gate.states.listen((_) => ref.invalidateSelf());
    ref.onDispose(sub.cancel);
  }
  var lastFailed = false;
  try {
    lastFailed = gate?.lastVerdictFailed ?? false;
  } catch (_) {}
  return remoteStreamsUnavailable(
    offline: offline,
    gate: gate?.state ?? const BindingIdle(),
    lastVerdictFailed: lastFailed,
  );
});
