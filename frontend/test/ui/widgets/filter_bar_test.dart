import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/browse_filters.dart';
import 'package:frontend/ui/widgets/filter_bar.dart';

void main() {
  late List<BrowseFilters> changes;

  setUp(() => changes = []);

  Widget harness({required BrowseFilters filters}) {
    return MaterialApp(
      home: Scaffold(
        body: FilterBar(filters: filters, onChanged: changes.add),
      ),
    );
  }

  FilterChip downloadedChip(WidgetTester tester) =>
      tester.widget<FilterChip>(find.byKey(FilterBar.downloadedChipKey));

  testWidgets('renders a capsule "Downloaded" FilterChip', (tester) async {
    await tester.pumpWidget(harness(filters: const BrowseFilters()));

    final chip = downloadedChip(tester);
    expect(find.text('Downloaded'), findsOneWidget);
    expect(chip.shape, isA<StadiumBorder>());
    expect(chip.selected, isFalse);
  });

  testWidgets('is a horizontally scrollable row', (tester) async {
    await tester.pumpWidget(harness(filters: const BrowseFilters()));

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
    await tester.pumpWidget(harness(filters: const BrowseFilters()));
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    expect(changes, [const BrowseFilters(downloaded: true)]);

    await tester.pumpWidget(
      harness(filters: const BrowseFilters(downloaded: true)),
    );
    expect(downloadedChip(tester).selected, isTrue);
    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    expect(changes.last, const BrowseFilters());
  });

  testWidgets('an offline-applied ON shows selected and stays tappable', (
    tester,
  ) async {
    const applied = BrowseFilters(downloaded: true, downloadedByOffline: true);
    await tester.pumpWidget(harness(filters: applied));

    final chip = downloadedChip(tester);
    expect(chip.selected, isTrue);
    expect(chip.onSelected, isNotNull, reason: 'offline never locks the chip');

    await tester.tap(find.byKey(FilterBar.downloadedChipKey));
    expect(changes, [
      const BrowseFilters(),
    ], reason: 'switching it off is the user\'s choice, not offline\'s');
  });

  testWidgets('screen readers hear a selectable "Downloaded" chip and its '
      'state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      harness(filters: const BrowseFilters(downloaded: true)),
    );
    expect(
      tester.getSemantics(find.byKey(FilterBar.downloadedChipKey)),
      matchesSemantics(
        label: 'Downloaded',
        isButton: true,
        hasSelectedState: true,
        isSelected: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });
}
