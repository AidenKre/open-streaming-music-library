import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:frontend/api/api_client.dart';
import 'package:frontend/providers/offline_mode_provider.dart';

void main() {
  setUp(() {
    // Poll fast so recovery tests don't wait the production 5s.
    OfflineModeNotifier.pollInterval = const Duration(milliseconds: 10);
  });

  tearDown(() {
    OfflineModeNotifier.pollInterval = const Duration(seconds: 5);
  });

  test('enterOffline flips state to true and is idempotent', () {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => throw const SocketException('down')),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(offlineModeProvider), isFalse);

    container.read(offlineModeProvider.notifier).enterOffline();
    expect(container.read(offlineModeProvider), isTrue);

    // Second call is a no-op — state stays true, no error.
    container.read(offlineModeProvider.notifier).enterOffline();
    expect(container.read(offlineModeProvider), isTrue);
  });

  test('a passing health check exits offline mode', () async {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('{"message": "Healthy"}', 200)),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(offlineModeProvider.notifier).enterOffline();
    expect(container.read(offlineModeProvider), isTrue);

    await _waitFor(() => container.read(offlineModeProvider) == false);
    expect(container.read(offlineModeProvider), isFalse);
  });

  test('an HTTP 500 during polling does NOT exit offline mode', () async {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => http.Response('boom', 500)),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(offlineModeProvider.notifier).enterOffline();

    // Let many poll cycles run — a reachable-but-unhealthy server must not
    // be treated as recovery.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(container.read(offlineModeProvider), isTrue);
  });

  test('exitOffline clears state; safe to call when already online', () {
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async => throw const SocketException('down')),
    );
    final container = ProviderContainer();
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

  test(
    'cancelOfflinePolling stops polling without flipping the public flag',
    () async {
      var requests = 0;
      ApiClient.initForTest(
        'http://localhost:8000',
        MockClient((_) async {
          requests++;
          throw const SocketException('down');
        }),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(offlineModeProvider.notifier);

      notifier.enterOffline();
      expect(container.read(offlineModeProvider), isTrue);

      notifier.cancelOfflinePolling();

      // No `true → false` transition, so app-level recovery listeners stay
      // silent. The poll timer is gone, so no further health checks happen.
      expect(container.read(offlineModeProvider), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        requests,
        0,
        reason: 'no health poll should run after cancelOfflinePolling',
      );
    },
  );

  test('exitOffline cancels the recovery poll timer', () async {
    var requests = 0;
    ApiClient.initForTest(
      'http://localhost:8000',
      MockClient((_) async {
        requests++;
        throw const SocketException('down');
      }),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(offlineModeProvider.notifier);

    // enterOffline schedules the first poll; exitOffline must cancel it
    // before it can fire.
    notifier.enterOffline();
    notifier.exitOffline();

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(requests, 0, reason: 'no health poll should run after exitOffline');
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('condition was not met in time');
}
