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

  group('effectiveDownloaded', () {
    test('online follows the user toggle', () {
      expect(
        const BrowseFilters().effectiveDownloaded(isOffline: false),
        isFalse,
      );
      expect(
        const BrowseFilters(
          downloaded: true,
        ).effectiveDownloaded(isOffline: false),
        isTrue,
      );
    });

    test('offline forces downloaded-only regardless of the toggle', () {
      expect(
        const BrowseFilters().effectiveDownloaded(isOffline: true),
        isTrue,
      );
      expect(
        const BrowseFilters(
          downloaded: true,
        ).effectiveDownloaded(isOffline: true),
        isTrue,
      );
    });

    test('the offline lock never rewrites the user value', () {
      // The page keeps one BrowseFilters across an offline period; the lock is
      // derived, so coming back online restores the explicit choice.
      const filters = BrowseFilters();
      expect(filters.effectiveDownloaded(isOffline: true), isTrue);
      expect(filters.downloaded, isFalse);
      expect(filters.effectiveDownloaded(isOffline: false), isFalse);
    });
  });
}
