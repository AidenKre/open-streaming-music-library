// M.3a exit proof (Phase M §7.2, SC-27 invariant 14, M-U19): the API client
// is built inside each keyed provider scope from that scope's session URL,
// over one process-lifetime transport. A request that outlives its scope
// can't flip the new scope offline, and replacing a scope never closes the
// shared transport.
import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/api/api_client_provider.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/main.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_player_controls.dart';
import 'browse_harness.dart' show teardownTree;

class _NoRecovery extends RecoveryService {
  _NoRecovery(super.ref);
  @override
  Future<void> runFor(RecoveryTrigger trigger) async {}
}

/// The process-lifetime transport: every request waits on [gate], then the
/// connection drops. Records whether anyone closed it.
class _SharedTransport extends http.BaseClient {
  Completer<void> gate = Completer<void>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw StateError('shared transport used after close');
    await gate.future;
    throw const SocketException('connection dropped');
  }

  @override
  void close() => closed = true;
}

void main() {
  late AppDatabase db;
  late _SharedTransport transport;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    transport = _SharedTransport();
  });

  tearDown(() => db.close());

  Widget scope(int generation, String url) => ProviderScope(
        key: ValueKey(generation),
        overrides: [
          sessionUrlProvider.overrideWithValue(url),
          httpClientProvider.overrideWithValue(transport),
          databaseProvider.overrideWithValue(db),
          audioServiceProvider.overrideWithValue(AudioServiceBridge()),
          playerControlsProvider.overrideWithValue(FakePlayerControls()),
          recoveryServiceProvider.overrideWith(_NoRecovery.new),
        ],
        child: const Frontend(),
      );

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(Frontend)));

  testWidgets("a request outliving its scope can't flip the new scope "
      'offline', (tester) async {
    await tester.pumpWidget(scope(1, 'http://old:1'));
    await tester.pump();
    final oldScope = containerOf(tester);
    final oldClient = oldScope.read(apiClientProvider);
    expect(oldClient.baseUrl, 'http://old:1');

    final outliving = oldClient.getJson(['tracks'], policy: RetryPolicy.noRetry);
    outliving.ignore();

    // The session changed: a new keyed scope replaces the old one.
    await tester.pumpWidget(scope(2, 'http://new:2'));
    await tester.pump();
    final newScope = containerOf(tester);
    expect(newScope.read(apiClientProvider).baseUrl, 'http://new:2');
    expect(identical(newScope.read(apiClientProvider), oldClient), isFalse);
    expect(transport.closed, isFalse,
        reason: "replacing a scope never closes the shared transport");

    // The old scope's request now fails at the transport level.
    transport.gate.complete();
    await tester.runAsync(() async {
      await expectLater(outliving, throwsA(isA<NetworkException>()));
    });
    await tester.pump();
    expect(newScope.read(offlineModeProvider), isFalse);

    // Control: the new scope's own transport failure still flips it.
    transport.gate = Completer<void>()..complete();
    await tester.runAsync(() async {
      await expectLater(
        newScope
            .read(apiClientProvider)
            .getJson(['tracks'], policy: RetryPolicy.noRetry),
        throwsA(isA<NetworkException>()),
      );
    });
    await tester.pump();
    expect(newScope.read(offlineModeProvider), isTrue);

    await teardownTree(tester);
  });
}
