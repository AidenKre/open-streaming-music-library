import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';

void main() {
  late List<BrowseFilters> changes;

  setUp(() => changes = []);

  Widget harness({required BrowseFilters filters, required bool isOffline}) {
    return MaterialApp(
      home: Scaffold(
        body: FilterBar(
          filters: filters,
          isOffline: isOffline,
          onChanged: changes.add,
        ),
      ),
    );
  }

  FilterChip downloadedChip(WidgetTester tester) =>
      tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

  testWidgets('renders a capsule "Downloaded" FilterChip', (tester) async {
    await tester.pumpWidget(
      harness(filters: const BrowseFilters(), isOffline: false),
    );

    final chip = downloadedChip(tester);
    expect(find.text('Downloaded'), findsOneWidget);
    expect(chip.shape, isA<StadiumBorder>());
    expect(chip.selected, isFalse);
  });

  testWidgets('is a horizontally scrollable row', (tester) async {
    await tester.pumpWidget(
      harness(filters: const BrowseFilters(), isOffline: false),
    );

    final scroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(FilterBar),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    expect(scroll.scrollDirection, Axis.horizontal);
  });

  testWidgets('online: tapping toggles the user value on and off', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(filters: const BrowseFilters(), isOffline: false),
    );
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    expect(changes, [const BrowseFilters(downloaded: true)]);

    await tester.pumpWidget(
      harness(filters: const BrowseFilters(downloaded: true), isOffline: false),
    );
    expect(downloadedChip(tester).selected, isTrue);
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    expect(changes.last, const BrowseFilters());
  });

  testWidgets('offline: locked selected + disabled, user value untouched', (
    tester,
  ) async {
    // The user's own value is OFF; offline still shows the chip ON.
    await tester.pumpWidget(
      harness(filters: const BrowseFilters(), isOffline: true),
    );

    final chip = downloadedChip(tester);
    expect(chip.selected, isTrue);
    expect(chip.onSelected, isNull, reason: 'disabled while offline');

    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    expect(changes, isEmpty);
    expect(find.byType(Tooltip), findsOneWidget);
  });

  testWidgets('a rebuild with the network back unlocks the chip', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(filters: const BrowseFilters(), isOffline: true),
    );
    expect(downloadedChip(tester).selected, isTrue);

    await tester.pumpWidget(
      harness(filters: const BrowseFilters(), isOffline: false),
    );
    final chip = downloadedChip(tester);
    expect(chip.selected, isFalse, reason: 'restores the user value');
    expect(chip.onSelected, isNotNull);
    expect(find.byType(Tooltip), findsNothing);
  });
}
