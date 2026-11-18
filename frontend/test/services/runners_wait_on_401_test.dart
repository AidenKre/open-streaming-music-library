// Phase M §7.7 / SC-13 Phase M (M-U24 "every runner waits on 401"): the
// runners not covered by their own 401 tests (downloads, history, sync,
// edit outbox) against a server that revoked the session, with the scope's
// hook wired as in the app. Each one's first 401 signs the session out; it
// fails no item, keeps local state, and sends nothing more while signed out
// (it waits for the scope rebuild after the next login):
//  * the settings quality reconcile;
//  * `LocalCoverArtStore.download`;
//  * conversion polls;
//  * queue warm.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/conversion/conversion_jobs_provider.dart';
import 'package:frontend/services/download_providers.dart';
import 'package:frontend/services/queue_warm_service.dart';
import 'package:frontend/services/session_service.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/revoked_session.dart';

void main() {
  late RevokedSession s;
  late Directory dir;

  setUp(() async {
    final originalPoll = ConversionJobsNotifier.pollInterval;
    addTearDown(() => ConversionJobsNotifier.pollInterval = originalPoll);
    dir = await Directory.systemTemp.createTemp('runners_wait_on_401_');
    s = await RevokedSession.create(
      overrides: [coverArtDirectoryProvider.overrideWithValue(dir)],
    );
    // Offline mode is read by most runners: keep it alive (Riverpod 3
    // pauses unlistened providers).
    final watch = s.container.listen(offlineModeProvider, (_, _) {});
    addTearDown(watch.close);
    await s.verify();
  });

  tearDown(() async {
    await s.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// One request through the scope's client signs the session out (the
  /// state every runner then sees).
  Future<void> signOutByA401() async {
    await expectLater(
      s.container.read(cover).download(1),
      completion(isFalse),
    );
    expect(s.session.serverBlocked.value, ServerBlockedReason.signedOut);
  }

  test('quality reconcile: the local quality stays, nothing is persisted',
      () async {
    SharedPreferences.setMockInitialValues({
      'serverUrl': 'http://s',
      'settings.streamQuality': '320',
    });
    final sub = s.container.listen(settingsProvider, (_, _) {});
    addTearDown(sub.close);
    final local = await s.container.read(settingsProvider.future);
    await s.container.read(settingsProvider.notifier).debugBackendSyncDone;

    expect(s.server.private, ['GET /settings/quality']);
    expect(s.session.serverBlocked.value, ServerBlockedReason.signedOut);
    expect(s.container.read(settingsProvider).value, local);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.streamQuality'), '320');
  });

  test('cover art download: no file, and no request while signed out',
      () async {
    await signOutByA401();
    expect(s.server.private, ['GET /cover_art/1']);
    expect(File('${dir.path}/1.bin').existsSync(), isFalse);
    // No temporary file either (its name is unique per download).
    expect(dir.listSync().where((e) => e.path.contains('/1.bin')), isEmpty);

    expect(await s.container.read(cover).download(2), isFalse);
    expect(s.server.private, ['GET /cover_art/1'],
        reason: 'signed out: the next art download waits');
  });

  // Review finding 2 said plain offline still tries. Sign-off OPEN-M-11
  // (2026-11-17, offline counts as not verified, confirmed by the
  // coordinator): while offline the token client withholds the request, so
  // the art is not fetched; the same result as a fetch that fails in a real
  // outage. Nothing is sent with the token.
  test('cover art download: while offline the fetch is withheld', () async {
    s.container.read(offlineModeProvider.notifier).enterOffline();
    expect(await s.container.read(cover).download(3), isFalse);
    expect(s.server.private, isEmpty);
  });

  test('conversion polls stop: one 401, then no poll while signed out',
      () async {
    // Review r1 m-R1-34: no wall clock. A zero interval makes every
    // reschedule a zero-delay timer, which pumpEventQueue runs in order, so
    // a reschedule that should not happen deterministically shows up.
    final interval = ConversionJobsNotifier.pollInterval;
    addTearDown(() => ConversionJobsNotifier.pollInterval = interval);
    ConversionJobsNotifier.pollInterval = Duration.zero;
    final sub = s.container.listen(conversionJobsProvider, (_, _) {});
    addTearDown(sub.close);
    await s.container.read(conversionJobsProvider.notifier).refreshAll();
    expect(s.session.serverBlocked.value, ServerBlockedReason.signedOut);
    final polls = s.server.private.length;
    expect(polls, 1);

    // A reschedule would have fired by now; a recovery refresh too.
    await pumpEventQueue();
    await s.container.read(conversionJobsProvider.notifier).refreshAll();
    expect(s.server.private.length, polls);
    expect(s.container.read(conversionJobsProvider), isEmpty,
        reason: 'no job is invented or failed');
  });

  // Review r1 m-R1-33: the helper cleans up its credential-store directory.
  test('a disposed session leaves no temp directory behind', () async {
    final other = await RevokedSession.create();
    final storeDir = other.storeDirectory;
    expect(await storeDir.exists(), isTrue);
    await other.dispose();
    expect(await storeDir.exists(), isFalse);
  });

  testWidgets('queue warm: nothing is sent while signed out', (tester) async {
    // The 401 round trip uses real I/O: keep it on the real clock.
    await tester.runAsync(signOutByA401);
    final before = s.server.private.length;
    s.container
        .read(queueWarmServiceProvider)
        .scheduleWarmUuids(['t-1'], quality: '320');
    // The warm debounce is a 500 ms Dart Timer: advance the fake clock past
    // it (700 ms, as before) instead of waiting in real time.
    await tester.pump(const Duration(milliseconds: 700));
    expect(s.server.private.length, before);
  });
}

final cover = localCoverArtStoreProvider;
