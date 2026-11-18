import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/settings/settings_registry.dart';
import 'package:frontend/ui/settings_controller.dart';

/// Settings as a session destination (SC-08): renders only the SC-21
/// registry — ordered sections, each with its available rows; a section
/// with no available row is hidden. No section is special-cased here. Opening
/// it tells the controller once (what Settings shows from the server is read
/// again).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read(settingsControlsProvider).onSettingsOpened();
    });
  }

  @override
  Widget build(BuildContext context) {
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
