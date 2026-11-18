// Phase 9 §5 / SC-07 / 9-U05 (hide preference) / 9-R02 (persisted local
// hide preference): `HomeLayoutPreferences` stores the hidden Home section
// ids on the device. A hidden section stays hidden in a new app session (a
// new container over the same stored preferences); showing it again removes
// it from the stored set.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/providers.dart';
import 'package:frontend/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stored preferences whose list write is refused (the platform answers
/// false): a failed save.
class _RefusingPrefs implements SharedPreferences {
  _RefusingPrefs(this.stored);
  final List<String>? stored;
  final writes = <List<String>>[];
  @override
  List<String>? getStringList(String key) => stored;
  @override
  Future<bool> setStringList(String key, List<String> value) async {
    writes.add(value);
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const rediscover = 'home.rediscover';
  const more = 'home.more_from_artists';

  Future<HomeLayoutPreferences> load(ProviderContainer c) async {
    final sub = c.listen(homeLayoutPreferencesProvider, (_, _) {});
    addTearDown(sub.close);
    return c.read(homeLayoutPreferencesProvider.future);
  }

  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nothing is hidden by default', () async {
    final prefs = await load(container());
    expect(prefs.hidden, isEmpty);
    expect(prefs.isHidden(rediscover), isFalse);
    expect(prefs.isHidden(more), isFalse);
  });

  test('hiding a section is visible at once and survives a new session',
      () async {
    final first = container();
    await load(first);
    await first
        .read(homeLayoutPreferencesProvider.notifier)
        .setHidden(rediscover, true);
    final now = first.read(homeLayoutPreferencesProvider).value!;
    expect(now.isHidden(rediscover), isTrue);
    expect(now.isHidden(more), isFalse);

    // A new app session reads the stored preference.
    final second = await load(container());
    expect(second.isHidden(rediscover), isTrue);
    expect(second.isHidden(more), isFalse);
  });

  test('showing a hidden section again removes it from the stored set',
      () async {
    SharedPreferences.setMockInitialValues({
      'settings.homeHiddenSections': [rediscover, more],
    });
    final c = container();
    final before = await load(c);
    expect(before.hidden, {rediscover, more});

    await c.read(homeLayoutPreferencesProvider.notifier).setHidden(more, false);
    expect(c.read(homeLayoutPreferencesProvider).value!.hidden, {rediscover});

    final again = await load(container());
    expect(again.hidden, {rediscover});
  });

  // U28-B-05: a refused save must not look saved. The toggle's error report
  // shows (the call throws) and the published state stays as stored.
  test('a save the platform refuses throws and keeps the stored state',
      () async {
    final refusing = _RefusingPrefs([more]);
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWith((_) async => refusing),
    ]);
    addTearDown(c.dispose);
    await load(c);

    final error = await c
        .read(homeLayoutPreferencesProvider.notifier)
        .setHidden(rediscover, true)
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(refusing.writes, hasLength(1), reason: 'the save was attempted');
    expect(c.read(homeLayoutPreferencesProvider).value!.hidden, {more},
        reason: 'the rail is still shown');
    expect(error, isNotNull, reason: 'the toggle reports the failed save');
  });

  test('setting the same value twice changes nothing', () async {
    final c = container();
    await load(c);
    final notifier = c.read(homeLayoutPreferencesProvider.notifier);
    await notifier.setHidden(more, true);
    await notifier.setHidden(more, true);
    final stored = (await SharedPreferences.getInstance())
        .getStringList('settings.homeHiddenSections');
    expect(stored, [more]);
    await notifier.setHidden(rediscover, false);
    expect(c.read(homeLayoutPreferencesProvider).value!.hidden, {more});
  });

  // Review r1 F7: two toggles inside one platform write both stick.
  test('two changes in flight at once both land', () async {
    final c = container();
    await load(c);
    final notifier = c.read(homeLayoutPreferencesProvider.notifier);
    await Future.wait([
      notifier.setHidden(rediscover, true),
      notifier.setHidden(more, true),
    ]);
    expect(c.read(homeLayoutPreferencesProvider).value!.hidden, {rediscover, more});
    final again = await load(container());
    expect(again.hidden, {rediscover, more});
  });
}
