import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/providers/offline_mode_provider.dart';

void main() {
  setUp(() {
    final original = OfflineModeNotifier.pollInterval;
    addTearDown(() => OfflineModeNotifier.pollInterval = original);
    // Poll fast so recovery tests don't wait the production 5s.
    OfflineModeNotifier.pollInterval = const Duration(milliseconds: 10);
  });

  test('enterOffline flips state to true and is idempotent', () {
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async => throw const SocketException('down')),
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    expect(container.read(offlineModeProvider), isFalse);

    container.read(offlineModeProvider.notifier).enterOffline();
    expect(container.read(offlineModeProvider), isTrue);

    // Second call is a no-op — state stays true, no error.
    container.read(offlineModeProvider.notifier).enterOffline();
    expect(container.read(offlineModeProvider), isTrue);
  });

  // Phase M §7.7 (M.3d review finding 1): a blocked session (signed out or
  // a different server) cancels polling while a poll may be in flight. That
  // poll's healthy answer must not bring the app back online.
  testWidgets('a poll in flight when polling is cancelled cannot exit offline',
      (tester) async {
    final release = Completer<void>();
    var polls = 0;
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async {
        polls++;
        await release.future;
        return http.Response('{"message": "Healthy"}', 200);
      }),
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(offlineModeProvider.notifier);

    notifier.enterOffline();
    await _waitFor(tester, () => polls == 1);
    notifier.cancelOfflinePolling();
    release.complete();
    await tester.pump(); // flush the released poll's continuation

    expect(container.read(offlineModeProvider), isTrue);
    expect(notifier.isPolling, isFalse);
  });

  // U22-FE-LIFECYCLE-A-02 / SPOT-FE-01: a poll hangs; the session leaves
  // and re-enters offline (a cleared block, then a new network failure); the
  // re-armed poll fires while the old check still hangs. Polling must go on,
  // so the app comes back online once the server answers.
  testWidgets('a poll that fires while an older check hangs keeps polling',
      (tester) async {
    final hung = Completer<http.Response>();
    var polls = 0;
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async {
        polls++;
        if (polls == 1) return hung.future;
        return http.Response('{"message": "Healthy"}', 200);
      }),
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(offlineModeProvider.notifier);

    notifier.enterOffline();
    await _waitFor(tester, () => polls == 1); // the first check hangs
    notifier.cancelOfflinePolling(); // a different-server block
    notifier.exitOffline(); // the block clears
    notifier.enterOffline(); // a new network failure re-arms the poll
    // The re-armed poll fires while the first check still hangs.
    await tester.pump(OfflineModeNotifier.pollInterval * 3);
    hung.complete(http.Response('{"message": "Healthy"}', 200));
    await tester.pump();

    // A few more poll intervals: the next poll finds the server healthy.
    for (var i = 0; i < 5; i++) {
      await tester.pump(OfflineModeNotifier.pollInterval);
    }
    expect(container.read(offlineModeProvider), isFalse,
        reason: 'the offline check must not stop for good');
  });

  testWidgets('a passing health check exits offline mode', (tester) async {
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{"message": "Healthy"}', 200)),
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    container.read(offlineModeProvider.notifier).enterOffline();
    expect(container.read(offlineModeProvider), isTrue);

    await _waitFor(tester, () => container.read(offlineModeProvider) == false);
    expect(container.read(offlineModeProvider), isFalse);
  });

  testWidgets('an HTTP 500 during polling does NOT exit offline mode',
      (tester) async {
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async => http.Response('boom', 500)),
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    container.read(offlineModeProvider.notifier).enterOffline();

    // Let many poll cycles run — a reachable-but-unhealthy server must not
    // be treated as recovery.
    await tester.pump(const Duration(milliseconds: 120));
    expect(container.read(offlineModeProvider), isTrue);
    // The poll re-arms itself forever; the fake binding checks for pending
    // timers before addTearDown runs, so end the scope here.
    container.dispose();
  });

  test('exitOffline clears state; safe to call when already online', () {
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async => throw const SocketException('down')),
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(offlineModeProvider.notifier);

    // No-op when already online.
    notifier.exitOffline();
    expect(container.read(offlineModeProvider), isFalse);

    notifier.enterOffline();
    expect(container.read(offlineModeProvider), isTrue);

    notifier.exitOffline();
    expect(container.read(offlineModeProvider), isFalse);
  });

  testWidgets(
    'cancelOfflinePolling stops polling without flipping the public flag',
    (tester) async {
      var requests = 0;
      final api = testApiClient(
        'http://localhost:8000',
        MockClient((_) async {
          requests++;
          throw const SocketException('down');
        }),
      );
      final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
      addTearDown(container.dispose);
      final notifier = container.read(offlineModeProvider.notifier);

      notifier.enterOffline();
      expect(container.read(offlineModeProvider), isTrue);

      notifier.cancelOfflinePolling();

      // No `true → false` transition, so app-level recovery listeners stay
      // silent. The poll timer is gone, so no further health checks happen.
      expect(container.read(offlineModeProvider), isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        requests,
        0,
        reason: 'no health poll should run after cancelOfflinePolling',
      );
    },
  );

  testWidgets('exitOffline cancels the recovery poll timer', (tester) async {
    var requests = 0;
    final api = testApiClient(
      'http://localhost:8000',
      MockClient((_) async {
        requests++;
        throw const SocketException('down');
      }),
    );
    final container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(offlineModeProvider.notifier);

    // enterOffline schedules the first poll; exitOffline must cancel it
    // before it can fire.
    notifier.enterOffline();
    notifier.exitOffline();

    await tester.pump(const Duration(milliseconds: 100));
    expect(requests, 0, reason: 'no health poll should run after exitOffline');
  });
}

// Virtual time: the poll is a plain Dart Timer, so the fake clock advances it
// without waiting.
Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 10));
  }
  throw StateError('condition was not met in time');
}
