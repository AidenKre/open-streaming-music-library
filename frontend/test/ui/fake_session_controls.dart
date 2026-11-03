import 'package:flutter/foundation.dart';
import 'package:frontend/services/local_reset_service.dart';
import 'package:frontend/ui/session_controller.dart';

/// Scriptable session controller for widget tests.
class FakeSessionControls extends ChangeNotifier implements SessionControls {
  FakeSessionControls({this.phase = SessionPhase.live, this.onDisconnect});

  @override
  SessionPhase phase;
  @override
  String? connectError;
  @override
  LocalResetException? resetFailure;
  final Future<void> Function()? onDisconnect;
  final calls = <String>[];

  void set(SessionPhase next, {LocalResetException? failure, String? error}) {
    phase = next;
    resetFailure = failure;
    connectError = error;
    notifyListeners();
  }

  @override
  Future<void> start() async => calls.add('start');
  @override
  Future<void> connect(String url) async => calls.add('connect $url');
  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    await onDisconnect?.call();
  }

  @override
  void acknowledgeReset() => calls.add('acknowledgeReset');

  @override
  Future<void> onSessionActivated() async => calls.add('activated');

  @override
  Future<void> retryLibrarySync() async => calls.add('retrySync');
}
