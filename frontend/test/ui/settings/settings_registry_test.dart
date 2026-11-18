// U22-FE-LIFECYCLE-A-10 (SC-21): the Settings page shows a row only under
// the section its `sectionId` names, so a row naming a section that is not
// registered would be dropped without a word. Every default row names a
// registered section.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/ui/settings/settings_registry.dart';

void main() {
  test('every default settings row names a section that exists', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final sections = {for (final s in c.read(settingsSectionsProvider)) s.id};
    final rows = c.read(settingsRowsProvider);
    expect(rows, isNotEmpty);
    expect(
      [
        for (final r in rows)
          if (!sections.contains(r.sectionId)) r.sectionId,
      ],
      isEmpty,
      reason: 'registered sections: $sections',
    );
  });
}
