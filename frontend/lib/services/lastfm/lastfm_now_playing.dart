import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:frontend/api/lastfm_api.dart';
import 'package:frontend/models/dto/lastfm_dtos.dart';

import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';

typedef LastfmPlaybackSignal = ({
  PlayerStatus status,
  int? itemId,
  String? trackUuid,

  /// The position is still within the first [lastfmNowPlayingDwell]: a
  /// change from false to true on the same item is a restart (9-R1-06).
  bool atStart,
});

final lastfmPlaybackSignalProvider = Provider<LastfmPlaybackSignal>(
  (ref) => ref.watch(
    queuePlayerProvider.select(
      (s) => (
        status: s.playback.status,
        itemId: s.queue.currentItemId,
        trackUuid: s.playback.currentTrack?.uuidId,
        atStart: s.playback.position < lastfmNowPlayingDwell,
      ),
    ),
  ),
);

/// How long one item must be playing, uninterrupted, before it is sent.
const lastfmNowPlayingDwell = Duration(seconds: 5);

/// Now Playing is sent only for an enabled account that needs no reconnect,
/// on a server whose Last.fm service is neither off nor stopped (both drop
/// the notice). A state this app does not know is not assumed to drop it
/// (9-R2-09).
bool lastfmNowPlayingAllowed(LastfmAccount? account) =>
    account is LastfmKnown &&
    account.status.state == LastfmAccountState.enabled &&
    account.status.needsReconnect == false &&
    account.status.service != LastfmServerState.off &&
    account.status.service != LastfmServerState.stopped;

/// The app side of Last.fm Now Playing (spec §7.10). An SC-27 observer: it
/// never mutates playback and records no history. Kept alive from the
/// session-ready signal by the wiring. It learns the account state at
/// session start (first play) and after every Integrations action through
/// [lastfmServiceProvider], which it starts listening to only when something
/// first plays.
///
/// One notice per item becoming current, after one uninterrupted
/// [lastfmNowPlayingDwell] of playing while online and enabled. Nothing is
/// queued, a failed notice is never retried, and nothing is shown or logged.
class LastfmNowPlaying {
  LastfmNowPlaying(this._ref) {
    _ref.listen(
      lastfmPlaybackSignalProvider,
      (_, _) => _evaluate(),
      fireImmediately: true,
    );
    _ref.listen<bool>(offlineModeProvider, (_, _) => _evaluate());
    _ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _timer = null;
    });
  }

  final Ref _ref;
  Timer? _timer;
  bool _disposed = false;
  bool _listeningToAccount = false;
  (int?, String?)? _key;
  bool _sent = false;
  bool _atStart = false;

  bool _eligible(LastfmPlaybackSignal signal) =>
      signal.status == PlayerStatus.playing &&
      signal.trackUuid != null &&
      !_ref.read(offlineModeProvider) &&
      lastfmNowPlayingAllowed(
        // A failed re-read keeps the previous value; it is not "enabled".
        _ref.read(lastfmServiceProvider).unwrapPrevious().value,
      );

  void _evaluate() {
    if (_disposed) return;
    final signal = _ref.read(lastfmPlaybackSignalProvider);
    if (!_listeningToAccount &&
        signal.status == PlayerStatus.playing &&
        signal.trackUuid != null) {
      _listeningToAccount = true;
      _ref.listen(lastfmServiceProvider, (_, _) => _evaluate());
    }
    final key = (signal.itemId, signal.trackUuid);
    // A new item, or the same item back at its start (repeat-one,
    // Previous): a fresh notice after a fresh dwell. Pause/resume while
    // still at the start is not a restart.
    if (key != _key || (signal.atStart && !_atStart)) {
      _key = key;
      _sent = false;
      _timer?.cancel();
      _timer = null;
    }
    _atStart = signal.atStart;
    if (!_listeningToAccount || !_eligible(signal)) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    if (_sent || _timer != null) return;
    _timer = Timer(lastfmNowPlayingDwell, () => _fire(key));
  }

  void _fire((int?, String?) key) {
    _timer = null;
    if (_disposed) return;
    final signal = _ref.read(lastfmPlaybackSignalProvider);
    if ((signal.itemId, signal.trackUuid) != key || !_eligible(signal)) return;
    _sent = true;
    unawaited(
      _ref
          .read(lastfmApiProvider)
          .nowPlaying(signal.trackUuid!)
          .catchError((Object _) {}),
    );
  }
}

final lastfmNowPlayingProvider = Provider<LastfmNowPlaying>(
  LastfmNowPlaying.new,
);
