import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/browse_filters.dart';

void main() {
  test('defaults to no filters', () {
    expect(const BrowseFilters().downloaded, isFalse);
  });

  test('copyWith changes only the given field', () {
    const base = BrowseFilters();
    expect(base.copyWith(downloaded: true).downloaded, isTrue);
    expect(base.copyWith().downloaded, isFalse);
    expect(const BrowseFilters(downloaded: true).copyWith().downloaded, isTrue);
  });

  test('has value equality', () {
    expect(
      const BrowseFilters(downloaded: true),
      equals(const BrowseFilters().copyWith(downloaded: true)),
    );
    expect(
      const BrowseFilters(downloaded: true).hashCode,
      const BrowseFilters().copyWith(downloaded: true).hashCode,
    );
    expect(
      const BrowseFilters(),
      isNot(equals(const BrowseFilters(downloaded: true))),
    );
  });

  test('the offline-applied flag is part of equality', () {
    expect(
      const BrowseFilters(downloaded: true, downloadedByOffline: true),
      isNot(equals(const BrowseFilters(downloaded: true))),
    );
    expect(
      const BrowseFilters(downloaded: true).copyWith(downloadedByOffline: true),
      const BrowseFilters(downloaded: true, downloadedByOffline: true),
    );
  });

  test('initial: offline at creation starts with Downloaded applied', () {
    expect(BrowseFilters.initial(isOffline: false), const BrowseFilters());
    expect(
      BrowseFilters.initial(isOffline: true),
      const BrowseFilters(downloaded: true, downloadedByOffline: true),
    );
  });

  group('offline transitions', () {
    test('going offline switches Downloaded on and marks it as offline\'s', () {
      expect(
        const BrowseFilters().wentOffline(),
        const BrowseFilters(downloaded: true, downloadedByOffline: true),
      );
    });

    test('going offline keeps an explicit ON as the user\'s', () {
      const filters = BrowseFilters(downloaded: true);
      expect(filters.wentOffline(), filters);
    });

    test('coming back online undoes an untouched offline ON', () {
      expect(
        const BrowseFilters().wentOffline().cameOnline(),
        const BrowseFilters(),
      );
    });

    test('coming back online keeps an explicit ON', () {
      const filters = BrowseFilters(downloaded: true);
      expect(filters.wentOffline().cameOnline(), filters);
    });

    test(
      'a user toggle while offline is the user\'s and survives reconnect',
      () {
        final off = const BrowseFilters().wentOffline().userSetDownloaded(
          false,
        );
        expect(off, const BrowseFilters());
        expect(off.cameOnline(), const BrowseFilters());

        final on = off.userSetDownloaded(true);
        expect(on, const BrowseFilters(downloaded: true));
        expect(on.cameOnline(), const BrowseFilters(downloaded: true));
      },
    );
  });
}
