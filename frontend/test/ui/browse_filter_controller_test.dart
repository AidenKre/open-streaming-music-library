import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/providers/offline_mode_provider.dart';
import 'package:frontend/ui/browse_filter_controller.dart';

import 'browse_harness.dart';

void main() {
  late TestOffline offline;
  late ProviderContainer container;

  ProviderContainer start({required bool isOffline}) {
    offline = TestOffline(isOffline);
    container = ProviderContainer(
      overrides: [offlineModeProvider.overrideWith(() => offline)],
    );
    addTearDown(container.dispose);
    return container;
  }

  BrowseFilterControls create({
    OfflineFilterPolicy policy = OfflineFilterPolicy.autoApply,
    bool? initial,
  }) {
    final controls = container.read(browseFilterControllerFactoryProvider)(
      policy: policy,
      initial: initial,
    );
    addTearDown(controls.dispose);
    return controls;
  }

  group('starting selection', () {
    test('online: nothing selected', () {
      start(isOffline: false);
      expect(create().filters, const BrowseFilters());
    });

    test('offline: Downloaded on, applied by offline', () {
      start(isOffline: true);
      expect(
        create().filters,
        const BrowseFilters(downloaded: true, downloadedByOffline: true),
      );
    });

    test('manual policy ignores starting offline', () {
      start(isOffline: true);
      expect(
        create(policy: OfflineFilterPolicy.manual).filters,
        const BrowseFilters(policy: OfflineFilterPolicy.manual),
      );
    });
  });

  // Phase 6 §3 / plan D12: See all starts from Home's current selection and
  // then owns it. A given initial value is the user's own choice, never one
  // applied by offline.
  group('initial selection', () {
    test('manual: starts from the given value, online or offline', () {
      start(isOffline: true);
      expect(
        create(policy: OfflineFilterPolicy.manual, initial: true).filters,
        const BrowseFilters(downloaded: true, policy: OfflineFilterPolicy.manual),
      );
      offline.set(false);
      expect(
        create(policy: OfflineFilterPolicy.manual, initial: true).filters,
        const BrowseFilters(downloaded: true, policy: OfflineFilterPolicy.manual),
      );
      expect(
        create(policy: OfflineFilterPolicy.manual, initial: false).filters,
        const BrowseFilters(policy: OfflineFilterPolicy.manual),
      );
    });

    test('manual: a given ON stays through connectivity flips', () {
      start(isOffline: false);
      final controls = create(policy: OfflineFilterPolicy.manual, initial: true);
      var count = 0;
      controls.addListener(() => count++);
      offline.set(true);
      offline.set(false);
      expect(controls.filters.downloaded, isTrue);
      expect(count, 0);
    });

    test('autoApply: a given OFF while offline is the user\'s choice', () {
      start(isOffline: true);
      final controls = create(initial: false);
      expect(controls.filters, const BrowseFilters());
      offline.set(false);
      offline.set(true);
      expect(
        controls.filters,
        const BrowseFilters(downloaded: true, downloadedByOffline: true),
        reason: 'a later offline period still applies its default',
      );
    });

    test('autoApply: a given ON is kept when coming back online', () {
      start(isOffline: true);
      final controls = create(initial: true);
      expect(controls.filters, const BrowseFilters(downloaded: true));
      offline.set(false);
      expect(controls.filters.downloaded, isTrue);
    });

    test('changing one surface never changes the one it was seeded from', () {
      start(isOffline: false);
      final home = create(policy: OfflineFilterPolicy.manual);
      home.setDownloaded(true);
      final seeAll = create(
        policy: OfflineFilterPolicy.manual,
        initial: home.filters.downloaded,
      );
      seeAll.setDownloaded(false);
      expect(home.filters.downloaded, isTrue);
      home.setDownloaded(false);
      home.setDownloaded(true);
      expect(seeAll.filters.downloaded, isFalse);
    });
  });

  group('connectivity (autoApply)', () {
    test('going offline switches Downloaded on and notifies once', () {
      start(isOffline: false);
      final controls = create();
      var count = 0;
      controls.addListener(() => count++);

      offline.set(true);

      expect(controls.filters.downloaded, isTrue);
      expect(controls.filters.downloadedByOffline, isTrue);
      expect(count, 1);
    });

    test('reconnecting undoes only offline\'s own ON', () {
      start(isOffline: false);
      final controls = create();

      offline.set(true);
      offline.set(false);

      expect(controls.filters, const BrowseFilters());
    });

    test('an ON the user chose survives offline and reconnect, silently', () {
      start(isOffline: false);
      final controls = create()..setDownloaded(true);
      var count = 0;
      controls.addListener(() => count++);

      offline.set(true);
      offline.set(false);

      expect(controls.filters, const BrowseFilters(downloaded: true));
      expect(count, 0, reason: 'nothing changed, so no re-query');
    });

    test('switching offline\'s ON off keeps it off after reconnect', () {
      start(isOffline: true);
      final controls = create()..setDownloaded(false);

      offline.set(false);

      expect(controls.filters, const BrowseFilters());
      offline.set(true);
      expect(
        controls.filters,
        const BrowseFilters(downloaded: true, downloadedByOffline: true),
        reason: 'a new offline period applies its default again',
      );
    });
  });

  test('manual policy is never touched by connectivity', () {
    start(isOffline: false);
    final controls = create(policy: OfflineFilterPolicy.manual);
    var count = 0;
    controls.addListener(() => count++);

    offline.set(true);
    expect(controls.filters.downloaded, isFalse);

    controls.setDownloaded(true);
    offline.set(false);
    expect(
      controls.filters,
      const BrowseFilters(downloaded: true, policy: OfflineFilterPolicy.manual),
    );
    expect(count, 1, reason: 'only the tap changed anything');
  });

  test('a tap to the current value does not notify', () {
    start(isOffline: false);
    final controls = create();
    var count = 0;
    controls.addListener(() => count++);

    controls.setDownloaded(false);
    expect(count, 0);
    controls.setDownloaded(true);
    controls.setDownloaded(true);
    expect(count, 1);
  });

  test('two surfaces keep independent selections', () {
    start(isOffline: false);
    final a = create();
    final b = create();

    a.setDownloaded(true);

    expect(a.filters.downloaded, isTrue);
    expect(b.filters.downloaded, isFalse);
  });

  test('after dispose, offline flips neither change nor notify', () {
    start(isOffline: false);
    final controls = container.read(browseFilterControllerFactoryProvider)();
    var count = 0;
    controls.addListener(() => count++);

    controls.dispose();
    offline.set(true);

    expect(count, 0);
    expect(controls.filters, const BrowseFilters());
    expect(controls.dispose, returnsNormally, reason: 'idempotent');
  });
}
