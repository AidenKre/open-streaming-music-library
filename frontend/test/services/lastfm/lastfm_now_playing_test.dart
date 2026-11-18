// Phase 9D.2d: the app side of Last.fm Now Playing (spec §7.10, O7, D11,
// 9-U10 client part).
//  * "The app sends it when a track is playing, has been the current track
//    for 5 seconds, the app is online, and the user's state is `enabled`."
//    O7: `PlayerStatus.playing` (actual playback, not desired transport)
//    for 5 s on the same current item. As built: the 5 s must be one
//    uninterrupted stretch of playing; a pause, a load, going offline or
//    losing `enabled` restarts it (DEV-9D2d-03).
//  * One notice per item becoming current; a new item restarts the dwell.
//  * Nothing is queued and a failed notice is never retried; a failure is
//    not shown (no error escapes).
//  * SC-27: playback state is read only through one `select` over the
//    QueuePlayer state; no playback-core change, no history record.
//  * Disposal (session or user switch) cancels a pending dwell.
// Fake time throughout (testWidgets + pump); no network.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/ui/track_ui.dart';
import 'package:frontend/playback/audio_providers.dart';
import 'package:frontend/playback/audio_state.dart';
import 'package:frontend/playback/queue_player.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/lastfm/lastfm_now_playing.dart';
import 'package:frontend/services/lastfm/lastfm_service.dart';

import '../../helpers/fake_lastfm_api.dart';
import '../../helpers/test_offline.dart';

const _a = 'aaaaaaaa-0000-4000-8000-000000000001';
const _b = 'bbbbbbbb-0000-4000-8000-000000000002';

class _Signal extends Notifier<LastfmPlaybackSignal> {
  @override
  LastfmPlaybackSignal build() =>
      (status: PlayerStatus.idle, itemId: null, trackUuid: null, atStart: false);

  void set(
    PlayerStatus status, {
    int? item,
    String? track,
    bool atStart = false,
  }) => state = (
    status: status,
    itemId: item,
    trackUuid: track,
    atStart: atStart,
  );
}

final _signalProvider =
    NotifierProvider<_Signal, LastfmPlaybackSignal>(_Signal.new);

class _Account extends LastfmService {
  _Account(this._initial);
  final LastfmAccount _initial;

  @override
  Future<LastfmAccount> build() async => _initial;

  void set(LastfmAccount account) => state = AsyncData(account);

  /// A failed re-read: Riverpod keeps the previous value on the error.
  void fail() => state = AsyncError(StateError('read failed'), StackTrace.empty);
}

LastfmKnown _known({
  String state = 'enabled',
  String service = 'running',
  bool available = true,
  Object? needsReconnect = false,
}) => LastfmKnown(
  status: lastfmStatus(
    state: state,
    service: service,
    needsReconnect: needsReconnect,
  ),
  available: available,
);

class _Rig {
  _Rig(LastfmAccount account) {
    container = ProviderContainer(overrides: [
      lastfmPlaybackSignalProvider
          .overrideWith((ref) => ref.watch(_signalProvider)),
      offlineModeProvider.overrideWith(() => TestOffline(false)),
      lastfmServiceProvider.overrideWith(() => _Account(account)),
      ...lastfmOverrides(api),
    ]);
    container.listen(lastfmNowPlayingProvider, (_, _) {});
  }

  final api = FakeLastfmApi();
  late final ProviderContainer container;

  void play(String track, {int item = 1}) => container
      .read(_signalProvider.notifier)
      .set(PlayerStatus.playing, item: item, track: track);

  void set(
    PlayerStatus status,
    String? track, {
    int? item = 1,
    bool atStart = false,
  }) => container
      .read(_signalProvider.notifier)
      .set(status, item: item, track: track, atStart: atStart);

  void offline(bool value) =>
      (container.read(offlineModeProvider.notifier) as TestOffline).set(value);

  void failAccount() =>
      (container.read(lastfmServiceProvider.notifier) as _Account).fail();

  void account(LastfmAccount a) =>
      (container.read(lastfmServiceProvider.notifier) as _Account).set(a);

  List<String> get sent =>
      [for (final c in api.calls) if (c.startsWith('nowPlaying')) c];

  void dispose() => container.dispose();
}

/// 9-R2-07: a QueuePlayer whose state the test sets, so the production
/// [lastfmPlaybackSignalProvider] (its `select` and its `atStart` rule) is
/// what the notifier sees.
class _Player extends QueuePlayer {
  @override
  AudioState build() => const AudioState();

  void emit(String track, Duration position,
          {PlayerStatus status = PlayerStatus.playing, int item = 1}) =>
      state = AudioState(
        playback: PlaybackSlice(
          currentTrack: TrackUI(
              uuidId: track,
              createdAt: 0,
              lastUpdated: 0,
              duration: 300,
              bitrateKbps: null,
              sampleRateHz: null,
              channels: null,
              hasAlbumArt: false),
          status: status,
          playWhenReady: status == PlayerStatus.playing,
          position: position,
        ),
        queue: QueueSlice(
          currentItemId: item,
          repeatMode: QueueRepeatMode.one,
        ),
      );
}

/// The real signal provider over [_Player] (no signal override).
class _RealSignalRig {
  _RealSignalRig() {
    container = ProviderContainer(overrides: [
      queuePlayerProvider.overrideWith(_Player.new),
      offlineModeProvider.overrideWith(() => TestOffline(false)),
      lastfmServiceProvider.overrideWith(() => _Account(_known())),
      ...lastfmOverrides(api),
    ]);
    container.listen(lastfmNowPlayingProvider, (_, _) {});
  }

  final api = FakeLastfmApi();
  late final ProviderContainer container;

  void at(int ms,
          {PlayerStatus status = PlayerStatus.playing,
          String track = _a,
          int item = 1}) =>
      (container.read(queuePlayerProvider.notifier) as _Player)
          .emit(track, Duration(milliseconds: ms), status: status, item: item);

  List<String> get sent =>
      [for (final c in api.calls) if (c.startsWith('nowPlaying')) c];

  void dispose() => container.dispose();
}

/// Plays from [fromMs] to [toMs] in one-second position updates.
Future<void> _playThrough(
    WidgetTester t, _RealSignalRig rig, int fromMs, int toMs) async {
  for (var ms = fromMs; ms <= toMs; ms += 1000) {
    rig.at(ms);
    await t.pump(const Duration(seconds: 1));
  }
}

void main() {
  testWidgets('playing 5 s on the same item sends one notice', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(milliseconds: 4999));
    expect(rig.sent, isEmpty);
    await t.pump(const Duration(milliseconds: 1));
    expect(rig.sent, ['nowPlaying $_a']);
    await t.pump(const Duration(minutes: 5));
    expect(rig.sent, ['nowPlaying $_a'], reason: 'one notice per item');
  });

  testWidgets('skipped under 5 s: nothing for that track', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a, item: 1);
    await t.pump(const Duration(seconds: 4));
    rig.play(_b, item: 2);
    await t.pump(const Duration(seconds: 4));
    expect(rig.sent, isEmpty);
    await t.pump(const Duration(seconds: 1));
    expect(rig.sent, ['nowPlaying $_b']);
  });

  testWidgets('the same track as a new queue item is a new notice', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a, item: 1);
    await t.pump(const Duration(seconds: 6));
    rig.play(_a, item: 2);
    await t.pump(const Duration(seconds: 6));
    expect(rig.sent, ['nowPlaying $_a', 'nowPlaying $_a']);
  });

  testWidgets('paused or loading: nothing is sent', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    for (final status in [
      PlayerStatus.paused,
      PlayerStatus.loading,
      PlayerStatus.idle,
    ]) {
      rig.set(status, _a);
      await t.pump(const Duration(seconds: 30));
    }
    expect(rig.sent, isEmpty);
  });

  testWidgets('a pause restarts the 5 s', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 3));
    rig.set(PlayerStatus.paused, _a);
    await t.pump(const Duration(seconds: 10));
    rig.play(_a);
    await t.pump(const Duration(seconds: 3));
    expect(rig.sent, isEmpty);
    await t.pump(const Duration(seconds: 2));
    expect(rig.sent, ['nowPlaying $_a']);
  });

  testWidgets('a short pause inside the 5 s also restarts it', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 3));
    rig.set(PlayerStatus.paused, _a);
    await t.pump(const Duration(seconds: 1));
    rig.play(_a);
    await t.pump(const Duration(seconds: 4));
    expect(rig.sent, isEmpty, reason: 'only 4 s of uninterrupted playing');
    await t.pump(const Duration(seconds: 1));
    expect(rig.sent, ['nowPlaying $_a']);
  });

  testWidgets('already sent for this item: pause and resume send nothing',
      (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 5));
    rig.set(PlayerStatus.paused, _a);
    await t.pump(const Duration(seconds: 5));
    rig.play(_a);
    await t.pump(const Duration(seconds: 30));
    expect(rig.sent, ['nowPlaying $_a']);
  });

  // 9-R1-06: the same item playing again from its start (repeat-one, a
  // one-item repeat-all queue, Previous restarting the track) is a new
  // notice after another 5 s; a resume at the same place is not.
  testWidgets('the same item restarting from its start sends again',
      (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.set(PlayerStatus.playing, _a, atStart: true);
    await t.pump(const Duration(seconds: 5));
    rig.set(PlayerStatus.playing, _a);
    await t.pump(const Duration(seconds: 200));
    expect(rig.sent, ['nowPlaying $_a']);

    rig.set(PlayerStatus.playing, _a, atStart: true); // looped
    await t.pump(const Duration(milliseconds: 4999));
    expect(rig.sent, hasLength(1));
    await t.pump(const Duration(milliseconds: 1));
    expect(rig.sent, ['nowPlaying $_a', 'nowPlaying $_a']);
    rig.set(PlayerStatus.playing, _a);
    await t.pump(const Duration(seconds: 60));
    expect(rig.sent, hasLength(2), reason: 'one notice per playthrough');
  });

  testWidgets('still at the start after a pause: no second notice',
      (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.set(PlayerStatus.playing, _a, atStart: true);
    await t.pump(const Duration(seconds: 5));
    expect(rig.sent, hasLength(1));
    rig.set(PlayerStatus.paused, _a, atStart: true);
    await t.pump(const Duration(seconds: 5));
    rig.set(PlayerStatus.playing, _a, atStart: true);
    await t.pump(const Duration(seconds: 30));
    expect(rig.sent, hasLength(1));
  });

  testWidgets('offline: nothing is sent and nothing is queued', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.offline(true);
    rig.play(_a);
    await t.pump(const Duration(seconds: 30));
    expect(rig.sent, isEmpty);

    // Going offline during the dwell cancels it.
    rig.offline(false);
    rig.play(_b, item: 2);
    await t.pump(const Duration(seconds: 3));
    rig.offline(true);
    await t.pump(const Duration(seconds: 30));
    expect(rig.sent, isEmpty, reason: 'nothing queued for later');
  });

  for (final (label, account) in [
    ('connected, not opted in', _known(state: 'connected_disabled')),
    ('not connected', _known(state: 'not_connected')),
    ('awaiting authorization', _known(state: 'awaiting_authorization')),
    ('server off', _known(service: 'off')),
    // 9-R1-26: the server would drop these notices.
    ('server stopped', _known(service: 'stopped')),
    ('needs reconnect', _known(needsReconnect: true)),
    ('reconnect unknown', _known(needsReconnect: null)),
    ('unknown state', _known(state: 'mystery')),
    ('only a cached block', const LastfmUnreachable(available: true)),
    ('not offered', const LastfmNotOffered()),
  ]) {
    testWidgets('$label: nothing is sent', (t) async {
      final rig = _Rig(account);
      addTearDown(rig.dispose);
      await t.pump();
      rig.play(_a);
      await t.pump(const Duration(seconds: 30));
      expect(rig.sent, isEmpty);
    });
  }

  // 9-R2-09: a server state this app does not know is unknown, not
  // stopped: the route answers 202 in every state except off (spec §7.4),
  // so only the states known to drop the notice (off, stopped) block it.
  testWidgets('an unknown server state: the notice is sent', (t) async {
    final rig = _Rig(_known(service: 'a_newer_state'));
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 5));
    expect(rig.sent, ['nowPlaying $_a']);
  });

  testWidgets('opting in on the Integrations page starts the dwell then',
      (t) async {
    final rig = _Rig(_known(state: 'connected_disabled'));
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 10));
    expect(rig.sent, isEmpty);
    rig.account(_known());
    await t.pump(const Duration(seconds: 4));
    expect(rig.sent, isEmpty);
    await t.pump(const Duration(seconds: 1));
    expect(rig.sent, ['nowPlaying $_a']);
  });

  testWidgets('disconnecting during the dwell sends nothing', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 3));
    rig.account(_known(state: 'not_connected'));
    await t.pump(const Duration(seconds: 30));
    expect(rig.sent, isEmpty);
  });

  // Review r1 #1: a failed status re-read (e.g. after Disconnect) is not
  // "still enabled".
  testWidgets('a failed status re-read stops Now Playing', (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 3));
    rig.failAccount();
    await t.pump(const Duration(seconds: 30));
    expect(rig.sent, isEmpty);
  });

  testWidgets('a failed notice is never retried and shows nothing',
      (t) async {
    final rig = _Rig(_known());
    addTearDown(rig.dispose);
    rig.api.onNowPlaying =
        (_) async => throw lastfmApiError(503, 'lastfm_unavailable');
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 5));
    await t.pump(const Duration(minutes: 5));
    expect(rig.sent, ['nowPlaying $_a']);
    expect(t.takeException(), isNull);
  });

  testWidgets('a scope disposed during the dwell sends nothing', (t) async {
    final rig = _Rig(_known());
    await t.pump();
    rig.play(_a);
    await t.pump(const Duration(seconds: 3));
    rig.dispose(); // the scope itself is under test, so no addTearDown
    await t.pump(const Duration(seconds: 10));
    expect(rig.sent, isEmpty);
  });

  // 9-R2-07: the restart rule through the production signal: the position
  // wrapping to 0 on the same item (repeat-one) or a seek back to 0 from
  // mid-track starts a fresh notice; a pause and resume inside the first
  // 5 s does not.
  group('through the real playback signal (9-R2-07)', () {
    testWidgets('repeat-one: the position wraps to 0, a second notice',
        (t) async {
      final rig = _RealSignalRig();
      addTearDown(rig.dispose);
      await t.pump();
      await _playThrough(t, rig, 0, 200000);
      expect(rig.sent, ['nowPlaying $_a']);

      await _playThrough(t, rig, 0, 3000); // wrapped: 0 s .. 3 s
      expect(rig.sent, hasLength(1), reason: 'a fresh 5 s dwell first');
      await _playThrough(t, rig, 4000, 8000);
      expect(rig.sent, ['nowPlaying $_a', 'nowPlaying $_a']);
      await _playThrough(t, rig, 9000, 60000);
      expect(rig.sent, hasLength(2), reason: 'one notice per playthrough');
    });

    testWidgets('a seek to 0 from mid-track: one new notice after 5 s',
        (t) async {
      final rig = _RealSignalRig();
      addTearDown(rig.dispose);
      await t.pump();
      await _playThrough(t, rig, 0, 90000);
      expect(rig.sent, hasLength(1));
      rig.at(0); // seek back to the start
      await t.pump(const Duration(milliseconds: 4999));
      expect(rig.sent, hasLength(1));
      await t.pump(const Duration(milliseconds: 1));
      expect(rig.sent, hasLength(2));
    });

    testWidgets('a position just under 5 s still counts as the start; '
        'reaching 5 s does not', (t) async {
      final rig = _RealSignalRig();
      addTearDown(rig.dispose);
      await t.pump();
      await _playThrough(t, rig, 5000, 120000);
      expect(rig.sent, hasLength(1));
      rig.at(4999); // back inside the first 5 s
      await t.pump(const Duration(seconds: 5));
      expect(rig.sent, hasLength(2), reason: 'under 5 s is the start');

      await _playThrough(t, rig, 30000, 60000);
      rig.at(5000); // a seek to exactly 5 s is not the start
      await t.pump(const Duration(seconds: 6));
      expect(rig.sent, hasLength(2));
    });

    // O-332-05, F903-O-16: the item and track the notice names come from
    // the real signal, not an overridden one.
    testWidgets('track A on one item, then track B on another: two notices, '
        'A then B', (t) async {
      final rig = _RealSignalRig();
      addTearDown(rig.dispose);
      await t.pump();
      rig.at(0);
      await t.pump(const Duration(seconds: 6));
      expect(rig.sent, ['nowPlaying $_a']);
      rig.at(0, track: _b, item: 2);
      await t.pump(const Duration(seconds: 4));
      expect(rig.sent, hasLength(1), reason: 'B has not played 5 s yet');
      await t.pump(const Duration(seconds: 2));
      expect(rig.sent, ['nowPlaying $_a', 'nowPlaying $_b']);
    });

    testWidgets('the same track moved to another item inside the first 5 s: '
        'a fresh 5 s dwell', (t) async {
      final rig = _RealSignalRig();
      addTearDown(rig.dispose);
      await t.pump();
      rig.at(0);
      await t.pump(const Duration(seconds: 3));
      rig.at(0, item: 2);
      await t.pump(const Duration(seconds: 3));
      expect(rig.sent, isEmpty, reason: '3 s on the new item');
      await t.pump(const Duration(seconds: 2));
      expect(rig.sent, ['nowPlaying $_a']);
    });

    testWidgets('pause and resume inside the first 5 s: no second notice',
        (t) async {
      final rig = _RealSignalRig();
      addTearDown(rig.dispose);
      await t.pump();
      rig.at(0); // playing, the position stalled at the start (buffering)
      await t.pump(const Duration(seconds: 5));
      expect(rig.sent, hasLength(1));
      rig.at(1500, status: PlayerStatus.paused);
      await t.pump(const Duration(seconds: 10));
      rig.at(1500); // resumed, still inside the first 5 s
      await t.pump(const Duration(seconds: 1));
      await _playThrough(t, rig, 2500, 30000);
      expect(rig.sent, hasLength(1), reason: 'no restart edge: still the start');
    });
  });

  test('SC-27/SC-26: only the select over QueuePlayer state; no ui import',
      () {
    final source =
        File('lib/services/lastfm/lastfm_now_playing.dart').readAsStringSync();
    final imports = RegExp(r"^import '([^']+)';", multiLine: true)
        .allMatches(source)
        .map((m) => m.group(1)!)
        .toList();
    final playback =
        imports.where((i) => i.startsWith('package:frontend/playback/'));
    expect(playback.toSet(), {
      'package:frontend/playback/audio_providers.dart',
      'package:frontend/playback/audio_state.dart',
    });
    expect(imports.where((i) => i.startsWith('package:frontend/ui/')),
        isEmpty);
    expect(imports.where((i) => i.contains('history')), isEmpty,
        reason: 'no history record');
    expect(RegExp(r'queuePlayerProvider\.select\(').allMatches(source),
        hasLength(1));
    expect(source.contains('queuePlayerProvider.notifier'), isFalse);
  });
}
