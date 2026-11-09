import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api/api_client.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/main.dart';
import 'package:frontend/playback/audio_dependencies.dart';
import 'package:frontend/playback/audio_service_bridge.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/recovery/recoverable.dart';
import 'package:frontend/services/recovery/recovery_service.dart';
import 'package:frontend/ui/player_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_player_controls.dart';

class _NoRecovery extends RecoveryService {
  _NoRecovery(super.ref);
  @override
  Future<void> runFor(RecoveryTrigger trigger) async {}
}

/// The app root keeps playbackWiringProvider alive for the whole provider
/// scope, from before StartupGate has connected (SC-27).
void main() {
  testWidgets('the app root binds OS media input for the scope lifetime',
      (tester) async {
    SharedPreferences.setMockInitialValues({}); // login screen, no session
    ApiClient.init('http://localhost:8000');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final bridge = AudioServiceBridge();
    final controls = FakePlayerControls();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        audioServiceProvider.overrideWithValue(bridge),
        playerControlsProvider.overrideWithValue(controls),
        recoveryServiceProvider.overrideWith(_NoRecovery.new),
      ],
      child: const Frontend(),
    ));
    await tester.pump();
    await bridge.play();
    expect(controls.calls, ['play']);

    // Scope gone (e.g. a reset rebuilt it): the binding goes with it.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(bridge.onPlay, isNull);
  });
}
