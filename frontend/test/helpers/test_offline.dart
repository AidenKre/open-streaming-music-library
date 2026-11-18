import 'package:frontend/providers/offline_mode_provider.dart';

/// Offline flag the test can flip mid-test via [set], without the real
/// health-poll timer.
class TestOffline extends OfflineModeNotifier {
  TestOffline(this.initial);
  final bool initial;

  @override
  bool build() {
    // Keep the product's dispose wiring (cancels the health-poll timer that
    // the inherited enterOffline starts); the stub's value stays the state.
    super.build();
    return initial;
  }

  void set(bool value) => state = value;
}
