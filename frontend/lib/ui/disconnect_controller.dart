import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Transport for the "reset and disconnect" action. Lives in a provider so
/// leaf widgets (SettingsDialog) reach it directly without parameter drilling
/// through every page on the route.
class DisconnectController {
  final Future<void> Function() disconnect;
  const DisconnectController(this.disconnect);
}

/// Defaults to null — i.e. disconnect is unavailable unless the host scope
/// (StartupGate) overrides this with a real controller. Returning null lets
/// SettingsDialog hide its disconnect button outside the live-session scope
/// (and in tests that don't set up an override).
final disconnectControllerProvider = Provider<DisconnectController?>((ref) {
  return null;
});
