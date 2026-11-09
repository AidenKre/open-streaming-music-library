// D29 (folded into 5A.0): the "server quality needs the server" rule is the
// model's; the Settings controller exposes it computed, and follows it.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:frontend/ui/settings_controller.dart';

class _Offline extends OfflineModeNotifier {
  _Offline(this.initial);
  final bool initial;
  @override
  bool build() => initial;
  void set(bool value) => state = value;
}

void main() {
  ({ProviderContainer c, _Offline offline}) scope(bool offline) {
    late _Offline notifier;
    final c = ProviderContainer(
      overrides: [
        offlineModeProvider.overrideWith(() => notifier = _Offline(offline)),
      ],
    );
    addTearDown(c.dispose);
    c.read(offlineModeProvider);
    return (c: c, offline: notifier);
  }

  test('the model rule: server quality changes need the server', () {
    expect(scope(false).c.read(canChangeServerQualityProvider), isTrue);
    expect(scope(true).c.read(canChangeServerQualityProvider), isFalse);
  });

  test('the controller exposes it and follows offline changes', () {
    final s = scope(false);
    var rebuilt = 0;
    s.c.listen(settingsControlsProvider, (_, _) => rebuilt++);
    expect(s.c.read(settingsControlsProvider).canChangeServerQuality, isTrue);
    s.offline.set(true);
    expect(s.c.read(settingsControlsProvider).canChangeServerQuality, isFalse);
    expect(rebuilt, 1, reason: 'watchers of the controller rebuild');
    s.offline.set(false);
    expect(s.c.read(settingsControlsProvider).canChangeServerQuality, isTrue);
  });
}
