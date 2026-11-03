import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/settings/settings_registry.dart';

/// Settings as a session destination (SC-08): renders only the SC-21
/// registry — ordered sections, each with its available rows; a section
/// with no available row is hidden. No section is special-cased here.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sections = [...ref.watch(settingsSectionsProvider)]
      ..sort((a, b) => a.order.compareTo(b.order));
    final rows = ref.watch(settingsRowsProvider);
    final children = <Widget>[];
    for (final section in sections) {
      final available = [
        for (final row in rows)
          if (row.sectionId == section.id &&
              (row.isAvailable == null || ref.watch(row.isAvailable!)))
            row,
      ]..sort((a, b) => a.order.compareTo(b.order));
      if (available.isEmpty) continue;
      children.add(
        Padding(
          key: ValueKey('settings.section.${section.id}'),
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(
            section.title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      );
      for (final row in available) {
        children.add(row.build(context));
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: children,
      ),
    );
  }
}
