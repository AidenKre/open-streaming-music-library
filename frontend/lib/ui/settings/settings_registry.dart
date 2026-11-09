import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:frontend/ui/settings/phase4_settings.dart';
import 'package:frontend/ui/settings/phase5_settings.dart';

/// A titled Settings section (SC-21). Ordered by [order]; hidden when none
/// of its rows is available.
@immutable
class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.order,
    required this.title,
  });

  final String id;
  final int order;
  final String title;
}

/// One row contributed to a section (SC-21). [isAvailable] (null = always)
/// lets a row react to capabilities (SC-03) or session state. Rows that open
/// a page navigate through `openSession` (SC-08).
@immutable
class SettingsRowContribution {
  const SettingsRowContribution({
    required this.sectionId,
    required this.order,
    required this.build,
    this.isAvailable,
  });

  final String sectionId;
  final int order;
  final WidgetBuilder build;
  final ProviderListenable<bool>? isAvailable;
}

/// The Settings sections. Later phases register theirs here (Phase 5
/// "Sync & storage", Phase 9 Home visibility) instead of editing
/// `SettingsPage`; nothing is pre-registered for features that haven't
/// landed.
final settingsSectionsProvider = Provider<List<SettingsSection>>(
  (ref) => [...phase4SettingsSections, ...phase5SettingsSections],
);

/// The Settings rows (Phase 8 adds Manage library / Possible duplicates and
/// 9D Integrations to Library tools).
final settingsRowsProvider = Provider<List<SettingsRowContribution>>(
  (ref) => [
    ...phase4SettingsRows,
    ...phase5SettingsRows(ref.watch(diagnosticsRowsProvider)),
  ],
);
