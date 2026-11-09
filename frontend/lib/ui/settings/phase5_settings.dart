import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:frontend/ui/settings/history_diagnostics_view.dart';
import 'package:frontend/ui/settings/phase4_settings.dart';
import 'package:frontend/ui/settings/settings_registry.dart';

/// Phase 5's Settings section (SC-21), registered like Phase 4's.
const phase5SettingsSections = <SettingsSection>[
  SettingsSection(id: 'sync_storage', order: 800, title: 'Sync & storage'),
];

/// One feature's contribution to "Sync & storage" (SC-21): a summary row in
/// Settings and a detail block on the diagnostics page
/// (`SessionDestination.syncDiagnostics`). Later phases append theirs to
/// [diagnosticsRowsProvider] instead of editing Settings or the page.
@immutable
class DiagnosticsRow {
  const DiagnosticsRow({
    required this.id,
    required this.order,
    required this.buildSummary,
    required this.buildDetail,
  });

  final String id;
  final int order;
  final WidgetBuilder buildSummary;
  final WidgetBuilder buildDetail;
}

/// The contributed diagnostics rows, in display order.
final diagnosticsRowsProvider = Provider<List<DiagnosticsRow>>(
  (ref) => const [historyDiagnosticsRow],
);

/// Each diagnostics row as a Settings row of "Sync & storage", offered only
/// inside a live session.
List<SettingsRowContribution> phase5SettingsRows(List<DiagnosticsRow> rows) => [
  for (final row in rows)
    SettingsRowContribution(
      sectionId: 'sync_storage',
      order: row.order,
      isAvailable: sessionIsLiveProvider,
      build: row.buildSummary,
    ),
];
