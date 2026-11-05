import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/database/database.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/ui/albums_page.dart';
import 'package:frontend/ui/artist_page.dart';
import 'package:frontend/ui/browse_filter_controller.dart';
import 'package:frontend/ui/search_page.dart';
import 'package:frontend/ui/tracks_page.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';

import 'browse_harness.dart';

/// D28 / SC-26: a browse surface's chip state lives in its own
/// [BrowseFilterControls]. Each surface with chips creates exactly one,
/// forwards chip taps to it, and disposes it (and its offline subscription)
/// with the page; surfaces without chips create none.
void main() {
  late AppDatabase db;
  late BrowseHarness h;
  late List<_RecordingFilterControls> created;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    h = await BrowseHarness.create(db);
    created = [];
  });

  tearDown(() async {
    await db.close();
    await h.dispose();
  });

  Widget wrap(Widget page) => h.wrap(
    Scaffold(body: page),
    overrides: [
      browseFilterControllerFactoryProvider.overrideWith(
        (ref) => ({policy = OfflineFilterPolicy.autoApply}) {
          final controls = _RecordingFilterControls(
            BrowseFilterController(ref, policy: policy),
          );
          created.add(controls);
          return controls;
        },
      ),
    ],
  );

  final surfaces = <String, Widget>{
    'Search': const SearchPage(),
    'Tracks browse': const TracksPage(browseAll: true),
    'Albums browse': const AlbumsPage(browseAll: true),
    'Artists browse': const ArtistsPage(browseAll: true),
  };

  for (final MapEntry(key: name, value: page) in surfaces.entries) {
    testWidgets('$name owns one controller, wires the chip to it, and '
        'disposes it with the page', (tester) async {
      await tester.pumpWidget(wrap(page));
      await tester.pump();

      expect(created, hasLength(1));
      final controls = created.single;
      expect(controls.listeners, 1, reason: 'the page listens');

      await tester.tap(find.byKey(FilterBar.downloadedChipKey));
      await tester.pump();
      expect(controls.taps, [true]);
      expect(
        tester
            .widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey))
            .selected,
        isTrue,
        reason: 'the chip renders the controller\'s selection',
      );

      await teardownTree(tester);
      expect(controls.listeners, 0);
      expect(controls.disposed, isTrue);
    });
  }

  testWidgets('a detail list (no chips) creates no controller', (tester) async {
    await tester.pumpWidget(wrap(const AlbumsPage(artistId: 1)));
    await tester.pump();

    expect(created, isEmpty);
    expect(find.byKey(FilterBar.downloadedChipKey), findsNothing);
    await teardownTree(tester);
  });
}

/// Wraps the real controller, recording what the page does with it.
class _RecordingFilterControls implements BrowseFilterControls {
  _RecordingFilterControls(this._inner);

  final BrowseFilterController _inner;
  final taps = <bool>[];
  int listeners = 0;
  bool disposed = false;

  @override
  BrowseFilters get filters => _inner.filters;

  @override
  void setDownloaded(bool value) {
    taps.add(value);
    _inner.setDownloaded(value);
  }

  @override
  void addListener(VoidCallback listener) {
    listeners++;
    _inner.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners--;
    _inner.removeListener(listener);
  }

  @override
  void dispose() {
    disposed = true;
    _inner.dispose();
  }
}
