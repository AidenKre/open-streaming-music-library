// Sign-off OPEN-M-11 Part N: one predicate, "streams unavailable" (offline,
// or the server check failed), read at call time by the playback core
// (streamsUnavailableProvider) and watched by the screens
// (streamsUnavailableNowProvider). Both come from remoteStreamsUnavailable,
// so they cannot disagree; a pending verdict (launch, resume, refocus) is not
// unavailable, so nothing flickers then.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/library_scope.dart';
import 'package:frontend/models/playback_availability.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/media_token_binding.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/server_binding_gate.dart';

/// A gate whose states the test publishes.
class _StatesGate extends Fake implements ServerBindingGate {
  final _states = StreamController<BindingGateState>.broadcast();
  BindingGateState _state = const BindingIdle();
  bool _lastFailed = false;
  void publish(BindingGateState s) {
    _state = s;
    if (s is! BindingVerifying) _lastFailed = s is BindingUnverified;
    _states.add(s);
  }

  @override
  bool get lastVerdictFailed => _lastFailed;

  Future<void> close() => _states.close();
  @override
  BindingGateState get state => _state;
  @override
  Stream<BindingGateState> get states => _states.stream;
}

const _notDownloaded = TrackUI(
  uuidId: 'u1',
  createdAt: 0,
  lastUpdated: 0,
  title: 't',
  artist: 'a',
  duration: 120,
  bitrateKbps: 320,
  sampleRateHz: 44100,
  channels: 2,
  hasAlbumArt: false,
);

final _allStates = <BindingGateState>[
  const BindingIdle(),
  const BindingVerifying(),
  const BindingVerified(token: 't', instanceId: 'i'),
  BindingUnverified(StateError('x')),
  const BindingDifferentServer(boundInstanceId: 'a', serverInstanceId: 'b'),
  const BindingNoSession(),
  const BindingSignedOut(),
];

void main() {
  late _StatesGate gate;
  late ProviderContainer c;

  setUp(() {
    gate = _StatesGate();
    c = ProviderContainer(overrides: [
      serverBindingGateProvider.overrideWithValue(gate),
    ]);
    c.listen(streamsUnavailableNowProvider, (_, _) {});
  });

  tearDown(() async {
    c.dispose();
    await gate.close();
  });

  void setOffline(bool offline) {
    final n = c.read(offlineModeProvider.notifier);
    if (offline) {
      n
        ..enterOffline()
        ..cancelOfflinePolling();
    } else {
      n.exitOffline();
    }
  }

  test('the screens and the playback core read the same answer, for every '
      'gate state and offline flag', () async {
    for (final offline in [false, true]) {
      setOffline(offline);
      // The retry of a failed check last (Verifying after Unverified).
      for (final s in [..._allStates, const BindingVerifying()]) {
        gate.publish(s);
        await pumpEventQueue();
        final now = c.read(streamsUnavailableNowProvider);
        expect(now, c.read(streamsUnavailableProvider)(),
            reason: 'offline $offline, $s');
        expect(
            now,
            remoteStreamsUnavailable(
                offline: offline,
                gate: s,
                lastVerdictFailed: gate.lastVerdictFailed),
            reason: 'offline $offline, $s');
      }
    }
  });

  test('a pending verdict (launch, resume, refocus) changes nothing: no '
      'flicker', () async {
    final seen = <bool>[];
    c.listen<bool>(streamsUnavailableNowProvider, (_, next) => seen.add(next),
        fireImmediately: true);
    gate.publish(const BindingVerifying()); // launch check running
    await pumpEventQueue();
    gate.publish(const BindingVerified(token: 't', instanceId: 'i'));
    await pumpEventQueue();
    gate.publish(const BindingVerifying()); // resume / refocus re-probe
    await pumpEventQueue();
    gate.publish(const BindingVerified(token: 't', instanceId: 'i'));
    await pumpEventQueue();
    expect(seen, [false], reason: 'available all along');

    gate.publish(BindingUnverified(StateError('x')));
    await pumpEventQueue();
    expect(seen, [false, true]);
  });

  // Part N review F1: the backoff retries of a failed check (every 1-30 s)
  // do not blink the buttons and upload rows to "available".
  test('a failed check being retried stays unavailable: no blink', () async {
    final seen = <bool>[];
    c.listen<bool>(streamsUnavailableNowProvider, (_, next) => seen.add(next),
        fireImmediately: true);
    gate.publish(BindingUnverified(StateError('x')));
    await pumpEventQueue();
    gate.publish(const BindingVerifying()); // the retry
    await pumpEventQueue();
    gate.publish(BindingUnverified(StateError('x')));
    await pumpEventQueue();
    gate.publish(const BindingVerifying()); // the next retry
    await pumpEventQueue();
    gate.publish(const BindingVerified(token: 't', instanceId: 'i'));
    await pumpEventQueue();
    expect(seen, [false, true, false]);
  });

  test('a track that is not downloaded: under a failed check its play state '
      'is exactly the offline one; during a pending verdict the online one',
      () async {
    PlaybackAvailability read() {
      final sub = c.listen(
          playbackAvailabilityProvider(const TrackScope(_notDownloaded)),
          (_, _) {});
      final value = sub.read();
      sub.close();
      return value;
    }

    gate.publish(const BindingVerified(token: 't', instanceId: 'i'));
    await pumpEventQueue();
    final online = read();
    setOffline(true);
    await pumpEventQueue();
    final offline = read();
    expect(offline, isNot(online), reason: 'precondition');

    setOffline(false);
    gate.publish(BindingUnverified(StateError('x')));
    await pumpEventQueue();
    expect(read(), offline);

    // A pending verdict after a success (launch, resume, refocus); a retry
    // after the failed check stays unavailable (review F1, tested above).
    gate.publish(const BindingVerified(token: 't', instanceId: 'i'));
    gate.publish(const BindingVerifying());
    await pumpEventQueue();
    expect(read(), online);
  });
}
